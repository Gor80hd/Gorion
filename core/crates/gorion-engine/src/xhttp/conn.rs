//! Соединения HTTP/2 и HTTP/3 для XHTTP и их переиспользование (xmux).
//! Эталон: Xray `mux.go` (`GetXmuxClient`), `dialer.go` (`createHTTPClient`).

use std::sync::Arc;
use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};
use std::time::Duration;

use bytes::Bytes;
use h2::SendStream;
use h2::client::{ResponseFuture, SendRequest};
use quinn::crypto::rustls::QuicClientConfig;
use quinn::{Runtime as _, TokioRuntime, VarInt};
use tokio::time::Instant;

use super::{HttpVersion, XhttpConfig, Xmux};
use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::stream::{self, Security};
use crate::tls::hello::random_bytes;

/// Окна HTTP/2 и QUIC — как у Chrome: иначе скачивание упирается в окно на RTT.
const STREAM_WINDOW: u32 = 6 * 1024 * 1024;
const CONNECTION_WINDOW: u32 = 15 * 1024 * 1024;
/// QUIC: как в Xray (`ConnIdleTimeout`, `QuicgoH3KeepAlivePeriod`).
const QUIC_IDLE: Duration = Duration::from_secs(300);
const QUIC_KEEP_ALIVE: Duration = Duration::from_secs(10);
const QUIC_HANDSHAKE: Duration = Duration::from_secs(10);

pub type H3Send = h3::client::RequestStream<h3_quinn::SendStream<Bytes>, Bytes>;
pub type H3Recv = h3::client::RequestStream<h3_quinn::RecvStream, Bytes>;

pub fn h2_error(error: h2::Error) -> EngineError {
    EngineError::Transport(format!("xhttp: {error}"))
}

pub fn h3_error(error: impl std::fmt::Display) -> EngineError {
    EngineError::Transport(format!("xhttp h3: {error}"))
}

pub struct H3Http {
    send: h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>,
    connection: quinn::Connection,
    _endpoint: quinn::Endpoint,
}

impl Drop for H3Http {
    fn drop(&mut self) {
        self.connection.close(VarInt::from_u32(0), b"");
    }
}

pub enum Http {
    H2(SendRequest<Bytes>),
    H3(H3Http),
}

pub struct MuxConn {
    http: Http,
    /// Открытые сессии на соединении.
    pub open: AtomicUsize,
    /// Сколько ещё сессий можно начать (−1 — без предела).
    left_usage: AtomicI64,
    left_requests: AtomicI64,
    unreusable_at: Option<Instant>,
}

impl MuxConn {
    pub fn reusable(&self) -> bool {
        self.left_usage.load(Ordering::Relaxed) != 0
            && self.left_requests.load(Ordering::Relaxed) > 0
            && self.unreusable_at.is_none_or(|at| Instant::now() < at)
    }

    async fn alive(&self) -> bool {
        match &self.http {
            Http::H2(send) => send.clone().ready().await.is_ok(),
            Http::H3(h3) => h3.connection.close_reason().is_none(),
        }
    }

    /// Запрос HTTP/2 с учётом счётчика запросов соединения.
    pub async fn h2(
        &self,
        request: http::Request<()>,
        end: bool,
    ) -> Result<(ResponseFuture, SendStream<Bytes>)> {
        let Http::H2(send) = &self.http else {
            return Err(EngineError::Protocol("xhttp: not an http/2 connection"));
        };
        self.left_requests.fetch_sub(1, Ordering::Relaxed);
        let mut send = send.clone().ready().await.map_err(h2_error)?;
        send.send_request(request, end).map_err(h2_error)
    }

    /// Запрос HTTP/3: половины отправки и приёма.
    pub async fn h3(&self, request: http::Request<()>) -> Result<(H3Send, H3Recv)> {
        let Http::H3(h3) = &self.http else {
            return Err(EngineError::Protocol("xhttp: not an http/3 connection"));
        };
        self.left_requests.fetch_sub(1, Ordering::Relaxed);
        let stream = h3
            .send
            .clone()
            .send_request(request)
            .await
            .map_err(h3_error)?;
        Ok(stream.split())
    }
}

#[derive(Default)]
pub struct Pool {
    conns: Vec<Arc<MuxConn>>,
    /// Предел одновременных сессий и число соединений: выбираются один раз.
    limits: Option<(usize, usize)>,
}

/// Сессия держит соединение: счётчик открытых падает при её закрытии.
pub struct Usage(pub Arc<MuxConn>);

impl Drop for Usage {
    fn drop(&mut self) {
        self.0.open.fetch_sub(1, Ordering::Relaxed);
    }
}

async fn connect(
    server: &TargetAddr,
    security: &Security,
    alpn: &[String],
    version: HttpVersion,
    xmux: &Xmux,
) -> Result<Arc<MuxConn>> {
    let http = match version {
        HttpVersion::H3 => Http::H3(
            tokio::time::timeout(QUIC_HANDSHAKE, h3_connect(server, security))
                .await
                .map_err(|_| EngineError::Transport("xhttp h3: handshake timed out".into()))??,
        ),
        _ => Http::H2(h2_connect(server, security, alpn).await?),
    };
    let reuse = xmux.c_max_reuse_times.pick();
    let requests = xmux.h_max_request_times.pick();
    let secs = xmux.h_max_reusable_secs.pick();
    Ok(Arc::new(MuxConn {
        http,
        open: AtomicUsize::new(0),
        left_usage: AtomicI64::new(if reuse > 0 {
            i64::try_from(reuse - 1).unwrap_or(i64::MAX)
        } else {
            -1
        }),
        left_requests: AtomicI64::new(if requests > 0 {
            i64::try_from(requests).unwrap_or(i64::MAX)
        } else {
            i64::MAX
        }),
        unreusable_at: (secs > 0).then(|| Instant::now() + Duration::from_secs(secs)),
    }))
}

async fn h2_connect(
    server: &TargetAddr,
    security: &Security,
    alpn: &[String],
) -> Result<SendRequest<Bytes>> {
    let tcp = crate::outbound::dial(server).await?;
    let (down, up) = stream::secure(tcp, security, alpn).await?;
    let (send, connection) = h2::client::Builder::new()
        .initial_window_size(STREAM_WINDOW)
        .initial_connection_window_size(CONNECTION_WINDOW)
        .handshake(crate::grpc::bridge(down, up))
        .await
        .map_err(h2_error)?;
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            tracing::debug!(%error, "xhttp: connection closed");
        }
    });
    Ok(send)
}

async fn h3_connect(server: &TargetAddr, security: &Security) -> Result<H3Http> {
    // REALITY и голый HTTP Xray по HTTP/3 не ведёт: только TLS с ALPN h3.
    let Security::Tls(tls) = security else {
        return Err(EngineError::Unsupported("xhttp h3 without tls".into()));
    };
    let mut last = None;
    for addr in crate::netbind::resolve(server).await? {
        let runtime = Arc::new(TokioRuntime);
        let attempt = async {
            let socket = runtime.wrap_udp_socket(crate::netbind::udp_socket(addr)?)?;
            let mut endpoint = quinn::Endpoint::new_with_abstract_socket(
                quinn::EndpointConfig::default(),
                None,
                socket,
                runtime.clone(),
            )?;
            let crypto =
                QuicClientConfig::try_from(tls.rustls_client(&[b"h3"])?).map_err(h3_error)?;
            let mut client = quinn::ClientConfig::new(Arc::new(crypto));
            let mut transport = quinn::TransportConfig::default();
            transport
                .stream_receive_window(VarInt::from_u32(STREAM_WINDOW))
                .receive_window(VarInt::from_u32(CONNECTION_WINDOW))
                .max_idle_timeout(Some(
                    quinn::IdleTimeout::try_from(QUIC_IDLE).map_err(h3_error)?,
                ))
                .keep_alive_interval(Some(QUIC_KEEP_ALIVE))
                .congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
            client.transport_config(Arc::new(transport));
            endpoint.set_default_client_config(client);
            let connection = endpoint
                .connect(addr, &tls.server_name)
                .map_err(h3_error)?
                .await
                .map_err(h3_error)?;
            let (mut driver, send) = h3::client::new(h3_quinn::Connection::new(connection.clone()))
                .await
                .map_err(h3_error)?;
            tokio::spawn(async move {
                let error = std::future::poll_fn(|cx| driver.poll_close(cx)).await;
                tracing::debug!(%error, "xhttp h3: connection closed");
            });
            Ok::<_, EngineError>(H3Http {
                send,
                connection,
                _endpoint: endpoint,
            })
        };
        match attempt.await {
            Ok(http) => return Ok(http),
            Err(error) => last = Some(error),
        }
    }
    Err(last.unwrap_or_else(|| EngineError::Transport("xhttp h3: no addresses".into())))
}

impl XhttpConfig {
    /// Соединение для новой сессии по правилам xmux (`GetXmuxClient`).
    pub(super) async fn mux_conn(
        &self,
        server: &TargetAddr,
        security: &Security,
        alpn: &[String],
        version: HttpVersion,
    ) -> Result<Usage> {
        let mut pool = self.pool.lock().await;
        let (concurrency, connections) = *pool.limits.get_or_insert_with(|| {
            (
                usize::try_from(self.xmux.max_concurrency.pick()).unwrap_or(usize::MAX),
                usize::try_from(self.xmux.max_connections.pick()).unwrap_or(usize::MAX),
            )
        });
        let mut alive = Vec::with_capacity(pool.conns.len());
        for conn in pool.conns.drain(..) {
            if conn.reusable() && conn.alive().await {
                alive.push(conn);
            }
        }
        pool.conns = alive;
        let candidates: Vec<&Arc<MuxConn>> = pool
            .conns
            .iter()
            .filter(|c| concurrency == 0 || c.open.load(Ordering::Relaxed) < concurrency)
            .collect();
        let need_new = pool.conns.is_empty()
            || (connections > 0 && pool.conns.len() < connections)
            || candidates.is_empty();
        if !need_new {
            let index =
                random_bytes::<8>().map(u64::from_le_bytes).unwrap_or(0) % candidates.len() as u64;
            let conn = Arc::clone(candidates[index as usize]);
            if conn.left_usage.load(Ordering::Relaxed) > 0 {
                conn.left_usage.fetch_sub(1, Ordering::Relaxed);
            }
            conn.open.fetch_add(1, Ordering::Relaxed);
            return Ok(Usage(conn));
        }
        // Рукопожатие — без замка: при одной сессии на соединение (так по
        // умолчанию в Xray) иначе подключения браузера открывались бы по
        // одному.
        drop(pool);
        let conn = connect(server, security, alpn, version, &self.xmux).await?;
        conn.open.fetch_add(1, Ordering::Relaxed);
        self.pool.lock().await.conns.push(Arc::clone(&conn));
        Ok(Usage(conn))
    }
}
