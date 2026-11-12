//! Сторона помощника: принимает команды и держит одно ядро в режиме TUN.
//!
//! Договор:
//! - запускать можно только TUN (`allow_non_tun` — только для тестов без root);
//! - соединение, на котором прошёл `start`, — аренда: закрылось — ядро
//!   останавливается, даже если приложение упало и `stop` не прислало;
//! - новый `start` заменяет прежнюю аренду; закрытие старого соединения
//!   новую сессию уже не трогает;
//! - команды, меняющие состояние, идут строго по одной.

use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Mutex, broadcast};
use tokio::task::JoinSet;

use super::frame::{FrameReader, write_frame};
use super::{HelperStart, PROTOCOL_VERSION, Request, Response};
use crate::error::{CoreError, CoreResult};
use crate::runtime::service::{RuntimeEvent, RuntimeService, StartRequest};

#[derive(Debug, Clone, Copy)]
struct Exit {
    lease: u64,
    code: i32,
}

pub struct HelperServer {
    runtime: Arc<RuntimeService>,
    allow_non_tun: bool,
    /// Номер действующей аренды. Общий с обработчиком выхода ядра.
    current: Arc<StdMutex<Option<u64>>>,
    next_lease: AtomicU64,
    exits: broadcast::Sender<Exit>,
    ops: Mutex<()>,
}

impl HelperServer {
    pub fn new(runtime_dir: PathBuf, singbox_path: PathBuf, allow_non_tun: bool) -> Arc<Self> {
        let current = Arc::new(StdMutex::new(None::<u64>));
        let (exits, _) = broadcast::channel(4);
        let sink_current = current.clone();
        let sink_exits = exits.clone();
        let runtime = RuntimeService::new(
            runtime_dir,
            singbox_path,
            Arc::new(move |event| {
                let RuntimeEvent::UnexpectedExit { code } = event;
                let lease = sink_current.lock().ok().and_then(|mut c| c.take());
                if let Some(lease) = lease {
                    let _ = sink_exits.send(Exit { lease, code });
                }
            }),
        );
        Arc::new(Self {
            runtime,
            allow_non_tun,
            current,
            next_lease: AtomicU64::new(0),
            exits,
            ops: Mutex::new(()),
        })
    }

    /// Убирает остатки прошлой сессии: после сбоя или перезагрузки сеть не
    /// должна остаться завёрнутой в мёртвый туннель.
    pub async fn recover(&self) {
        self.runtime.recover_previous_session().await;
    }

    /// Остановка службы (SIGTERM от launchd).
    pub async fn shutdown(&self) {
        let _ops = self.ops.lock().await;
        self.set_current(None);
        self.runtime.stop_for_app_exit().await;
    }

    pub async fn serve(self: Arc<Self>, listener: UnixListener) {
        let mut connections = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => match accepted {
                    Ok((stream, _)) => {
                        let server = Arc::clone(&self);
                        connections.spawn(async move { server.connection(stream).await });
                    }
                    Err(error) => {
                        tracing::warn!(%error, "helper accept failed");
                        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    }
                },
                Some(_) = connections.join_next(), if !connections.is_empty() => {}
            }
        }
    }

    async fn connection(&self, stream: UnixStream) {
        let peer = stream
            .peer_cred()
            .ok()
            .and_then(|c| c.pid())
            .unwrap_or_default();
        let (read, mut write) = stream.into_split();
        let mut frames = FrameReader::<Request>::spawn(read);
        let mut exits = self.exits.subscribe();
        let mut lease: Option<u64> = None;
        loop {
            tokio::select! {
                frame = frames.next() => {
                    let response = match frame {
                        Some(Ok(request)) => self.handle(request, &mut lease, peer).await,
                        Some(Err(error)) => {
                            let _ = write_frame(&mut write, &Response::error(
                                &CoreError::Internal(format!("bad request: {error}")),
                            )).await;
                            break;
                        }
                        None => break,
                    };
                    if write_frame(&mut write, &response).await.is_err() {
                        break;
                    }
                }
                exit = exits.recv(), if lease.is_some() => match exit {
                    Ok(exit) if Some(exit.lease) == lease => {
                        lease = None;
                        if write_frame(&mut write, &Response::Exited { code: exit.code }).await.is_err() {
                            break;
                        }
                    }
                    Ok(_) | Err(broadcast::error::RecvError::Lagged(_)) => {}
                    Err(broadcast::error::RecvError::Closed) => break,
                },
            }
        }
        if let Some(lease) = lease {
            self.release(lease, peer).await;
        }
    }

    async fn handle(&self, request: Request, lease: &mut Option<u64>, peer: i32) -> Response {
        match request {
            Request::Hello => Response::Hello {
                version: PROTOCOL_VERSION,
                build: env!("CARGO_PKG_VERSION").to_owned(),
            },
            Request::Start(start) => match self.start(start, peer).await {
                Ok((id, session)) => {
                    *lease = Some(id);
                    Response::Started { session }
                }
                Err(error) => Response::error(&error),
            },
            Request::Stop => {
                let _ops = self.ops.lock().await;
                let mine = lease.take();
                let current = self.current_lease();
                // Чужую (заменённую) аренду не трогаем: её сессии уже нет.
                if mine.is_some() && mine != current {
                    return Response::Stopped;
                }
                self.set_current(None);
                tracing::info!(peer, "helper stop");
                match self.runtime.stop().await {
                    Ok(()) => Response::Stopped,
                    Err(error) => Response::error(&error),
                }
            }
            Request::State => Response::State {
                running: self.runtime.session().await.is_some(),
            },
            Request::Logs => Response::Logs {
                lines: self.runtime.logs(),
            },
        }
    }

    async fn start(
        &self,
        start: HelperStart,
        peer: i32,
    ) -> CoreResult<(u64, crate::runtime::service::RuntimeSession)> {
        if !start.mode.uses_tun() && !self.allow_non_tun {
            return Err(CoreError::Unsupported(
                "helper runs only the TUN mode".into(),
            ));
        }
        let _ops = self.ops.lock().await;
        // Прежняя аренда больше не владеет ядром: `start` его заменит.
        self.set_current(None);
        tracing::info!(peer, profile = %start.profile_id, "helper start");
        let allow_engine = !start.sing_box_only;
        let session = self
            .runtime
            .start_with(
                StartRequest {
                    profile_id: start.profile_id,
                    template_config: start.template_config,
                    mode: start.mode,
                    selected_server_tag: start.selected_server_tag,
                    url_test_url: start.url_test_url,
                    bypass_steam: false,
                    // Правила раздельного туннелирования пока не передаются:
                    // их rule-set'ы могли бы указать ядру от root на файлы.
                    split_tunnel: None,
                },
                allow_engine,
            )
            .await?;
        let id = self.next_lease.fetch_add(1, Ordering::SeqCst) + 1;
        self.set_current(Some(id));
        Ok((id, session))
    }

    /// Аренда закрылась без `stop`: приложение вышло или упало.
    async fn release(&self, lease: u64, peer: i32) {
        let _ops = self.ops.lock().await;
        if self.current_lease() != Some(lease) {
            return;
        }
        self.set_current(None);
        tracing::info!(peer, "helper lease closed, stopping runtime");
        if let Err(error) = self.runtime.stop().await {
            tracing::warn!(%error, "helper stop after lease close failed");
        }
    }

    fn current_lease(&self) -> Option<u64> {
        self.current.lock().ok().and_then(|c| *c)
    }

    fn set_current(&self, lease: Option<u64>) {
        if let Ok(mut current) = self.current.lock() {
            *current = lease;
        }
    }
}
