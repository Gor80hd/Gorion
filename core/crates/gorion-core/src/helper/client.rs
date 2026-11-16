//! Сторона приложения: проверка помощника и запуск TUN через него.

use std::io;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::net::UnixStream;
use tokio::net::unix::OwnedWriteHalf;
use tokio::sync::{Mutex, mpsc, oneshot};

use super::frame::{FrameReader, write_frame};
use super::{HelperStart, HelperStatus, PROTOCOL_VERSION, Request, Response};
use crate::error::{CoreError, CoreResult};
use crate::runtime::service::{EventSink, RuntimeEvent, RuntimeSession, StartRequest};

const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// Запуск включает `gorion-engine check` и ожидание контроллера.
const START_TIMEOUT: Duration = Duration::from_secs(90);
const STOP_TIMEOUT: Duration = Duration::from_secs(20);
/// Код «соединение с помощником потеряно» для `UnexpectedExit`.
pub const LOST_HELPER_EXIT_CODE: i32 = -1;

struct Connection {
    write: OwnedWriteHalf,
    frames: FrameReader<Response>,
}

impl Connection {
    async fn open(socket: &Path) -> CoreResult<Self> {
        let stream = tokio::time::timeout(CONNECT_TIMEOUT, UnixStream::connect(socket))
            .await
            .map_err(|_| CoreError::TunHelperRequired)?
            .map_err(|error| {
                tracing::debug!(%error, "helper is not reachable");
                CoreError::TunHelperRequired
            })?;
        let (read, write) = stream.into_split();
        Ok(Self {
            write,
            frames: FrameReader::spawn(read),
        })
    }

    async fn call(&mut self, request: &Request, timeout: Duration) -> CoreResult<Response> {
        write_frame(&mut self.write, request)
            .await
            .map_err(lost_helper)?;
        match tokio::time::timeout(timeout, self.frames.next()).await {
            Err(_) => Err(CoreError::Internal("helper did not answer in time".into())),
            Ok(None) => Err(lost_helper(io::ErrorKind::UnexpectedEof.into())),
            Ok(Some(Err(error))) => Err(lost_helper(error)),
            Ok(Some(Ok(Response::Error { code, detail }))) => {
                Err(CoreError::Remote { code, detail })
            }
            Ok(Some(Ok(response))) => Ok(response),
        }
    }

    /// Рукопожатие: помощник той же версии протокола.
    async fn hello(&mut self) -> CoreResult<()> {
        match self.call(&Request::Hello, REQUEST_TIMEOUT).await? {
            Response::Hello { version, .. } if version == PROTOCOL_VERSION => Ok(()),
            Response::Hello { version, .. } => Err(CoreError::HelperOutdated(version)),
            _ => Err(unexpected()),
        }
    }
}

fn lost_helper(error: io::Error) -> CoreError {
    CoreError::CoreStartFailed(format!("connection to helper lost: {error}"))
}

fn unexpected() -> CoreError {
    CoreError::Internal("unexpected helper response".into())
}

/// Разовые запросы к помощнику.
#[derive(Debug, Clone)]
pub struct HelperClient {
    socket: PathBuf,
}

impl HelperClient {
    pub fn new(socket: impl Into<PathBuf>) -> Self {
        Self {
            socket: socket.into(),
        }
    }

    pub fn socket(&self) -> &Path {
        &self.socket
    }

    pub async fn status(&self) -> HelperStatus {
        let Ok(mut connection) = Connection::open(&self.socket).await else {
            return HelperStatus::NotInstalled;
        };
        match connection.hello().await {
            Ok(()) => HelperStatus::Ready,
            Err(CoreError::HelperOutdated(_)) => HelperStatus::Outdated,
            // Служба есть, но не отвечает как надо — переустановка поможет.
            Err(_) => HelperStatus::Outdated,
        }
    }

    pub async fn logs(&self) -> CoreResult<Vec<String>> {
        let mut connection = Connection::open(&self.socket).await?;
        connection.hello().await?;
        match connection.call(&Request::Logs, REQUEST_TIMEOUT).await? {
            Response::Logs { lines } => Ok(lines),
            _ => Err(unexpected()),
        }
    }
}

struct Lease {
    stop: mpsc::Sender<oneshot::Sender<CoreResult<()>>>,
}

/// Ядро в режиме TUN, которое держит помощник. Повторяет договор
/// `RuntimeService`: `start` заменяет прежнюю сессию, `stop` идемпотентен,
/// неожиданный выход приходит событием `UnexpectedExit`.
pub struct TunRuntime {
    client: HelperClient,
    events: EventSink,
    lease: Mutex<Option<Lease>>,
}

impl TunRuntime {
    pub fn new(client: HelperClient, events: EventSink) -> Arc<Self> {
        Arc::new(Self {
            client,
            events,
            lease: Mutex::new(None),
        })
    }

    pub fn client(&self) -> &HelperClient {
        &self.client
    }

    pub async fn start(&self, request: &StartRequest) -> CoreResult<RuntimeSession> {
        let mut slot = self.lease.lock().await;
        if let Some(old) = slot.take() {
            let _ = stop_lease(old).await;
        }
        let mut connection = Connection::open(&self.client.socket).await?;
        connection.hello().await?;
        let start = Request::Start(HelperStart {
            profile_id: request.profile_id.clone(),
            template_config: request.template_config.clone(),
            mode: request.mode,
            selected_server_tag: request.selected_server_tag.clone(),
            url_test_url: request.url_test_url.clone(),
        });
        let session = match connection.call(&start, START_TIMEOUT).await? {
            Response::Started { session } => session,
            _ => return Err(unexpected()),
        };
        let (stop, stop_rx) = mpsc::channel(1);
        tokio::spawn(run_lease(connection, stop_rx, self.events.clone()));
        *slot = Some(Lease { stop });
        Ok(session)
    }

    pub async fn stop(&self) -> CoreResult<()> {
        let lease = self.lease.lock().await.take();
        match lease {
            Some(lease) => stop_lease(lease).await,
            None => Ok(()),
        }
    }

    pub async fn is_active(&self) -> bool {
        self.lease
            .lock()
            .await
            .as_ref()
            .is_some_and(|l| !l.stop.is_closed())
    }
}

async fn stop_lease(lease: Lease) -> CoreResult<()> {
    let (reply, result) = oneshot::channel();
    if lease.stop.send(reply).await.is_err() {
        // Аренда уже закончилась (ядро вышло или помощник пропал).
        return Ok(());
    }
    result.await.unwrap_or(Ok(()))
}

/// Держит соединение-аренду: ждёт команды остановки или вестей от помощника.
async fn run_lease(
    mut connection: Connection,
    mut stop: mpsc::Receiver<oneshot::Sender<CoreResult<()>>>,
    events: EventSink,
) {
    let stopping = AtomicBool::new(false);
    loop {
        tokio::select! {
            request = stop.recv() => {
                // Отправитель пропал — закрытие соединения само остановит ядро.
                let Some(reply) = request else { return };
                stopping.store(true, Ordering::SeqCst);
                let result = match connection.call(&Request::Stop, STOP_TIMEOUT).await {
                    Ok(Response::Stopped) => Ok(()),
                    // Ядро успело выйти само — остановка всё равно состоялась.
                    Ok(Response::Exited { .. }) => Ok(()),
                    Ok(_) => Err(unexpected()),
                    Err(error) => Err(error),
                };
                let _ = reply.send(result);
                return;
            }
            frame = connection.frames.next() => {
                let code = match frame {
                    Some(Ok(Response::Exited { code })) => code,
                    Some(Ok(_)) => continue,
                    Some(Err(_)) | None => LOST_HELPER_EXIT_CODE,
                };
                if !stopping.load(Ordering::SeqCst) {
                    (events)(RuntimeEvent::UnexpectedExit { code });
                }
                return;
            }
        }
    }
}
