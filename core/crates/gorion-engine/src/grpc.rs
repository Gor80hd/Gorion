//! Транспорт gRPC («gun»), как `v2raygrpclite` в sing-box: поток — это
//! вызов POST `/{сервис}/Tun` поверх HTTP/2, данные — сообщения gRPC
//! `[0][длина u32][protobuf: поле 1 — байты]`. Все подключения к серверу
//! идут потоками одного соединения HTTP/2, как у sing-box.
//!
//! HTTP/2 (кадры, HPACK, окна) — крейт `h2`: это общий транспорт, как QUIC
//! у quinn, а не формат протокола (ADR-0005). Формат gun — свой.

use std::fmt;
use std::sync::Arc;

use bytes::Bytes;
use h2::client::{ResponseFuture, SendRequest};
use h2::{RecvStream, SendStream};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::stream::{self, Security};

/// Предел сообщения gRPC от сервера.
const MAX_MESSAGE: usize = 16 * 1024 * 1024;
/// Буфер между потоком TLS и HTTP/2.
const BRIDGE_BUFFER: usize = 256 * 1024;
const USER_AGENT: &str = "grpc-go/1.48.0";

#[derive(Clone)]
pub struct GrpcConfig {
    pub service_name: String,
    /// Соединение HTTP/2, общее для всех потоков к этому серверу.
    pool: Arc<Mutex<Option<SendRequest<Bytes>>>>,
}

impl fmt::Debug for GrpcConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Имя сервиса бывает секретом сервера: в журнал не попадает.
        f.debug_struct("GrpcConfig").finish_non_exhaustive()
    }
}

impl GrpcConfig {
    pub fn new(service_name: impl Into<String>) -> Self {
        Self {
            service_name: service_name.into(),
            pool: Arc::new(Mutex::new(None)),
        }
    }
}

fn h2_error(error: h2::Error) -> EngineError {
    EngineError::Transport(format!("grpc: {error}"))
}

/// Как `url.PathEscape` в Go: всё, кроме безопасных знаков сегмента пути.
fn path_escape(segment: &str) -> String {
    let mut out = String::with_capacity(segment.len());
    for byte in segment.bytes() {
        let safe = byte.is_ascii_alphanumeric() || b"-._~$&+=:@".contains(&byte);
        if safe {
            out.push(char::from(byte));
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// Имя сервера для `:authority`: имя TLS с портом сервера или адрес.
fn authority(server: &TargetAddr, security: &Security) -> String {
    let name = match security {
        Security::Tls(config) => Some(config.server_name.as_str()),
        Security::Reality(config) => Some(config.server_name.as_str()),
        Security::None => None,
    };
    match name.filter(|n| !n.is_empty()) {
        Some(name) if name.contains(':') => format!("[{name}]:{}", server.port()),
        Some(name) => format!("{name}:{}", server.port()),
        None => server.to_string(),
    }
}

/// Поток TLS (свои половины) как один `AsyncRead + AsyncWrite` для h2.
fn bridge(mut down: stream::Down, mut up: stream::Up) -> tokio::io::DuplexStream {
    let (ours, theirs) = tokio::io::duplex(BRIDGE_BUFFER);
    let (mut read, mut write) = tokio::io::split(theirs);
    tokio::spawn(async move {
        while let Ok(Some(chunk)) = down.read_chunk().await {
            if write.write_all(&chunk).await.is_err() {
                return;
            }
        }
        let _ = write.shutdown().await;
    });
    tokio::spawn(async move {
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match read.read(&mut buf).await {
                Ok(0) | Err(_) => return,
                Ok(n) => {
                    if up.write_all(&buf[..n]).await.is_err() {
                        return;
                    }
                }
            }
        }
    });
    ours
}

async fn connect(
    server: &TargetAddr,
    security: &Security,
    alpn: &[String],
) -> Result<SendRequest<Bytes>> {
    let tcp = crate::outbound::dial(server).await?;
    let (down, up) = stream::secure(tcp, security, alpn).await?;
    let (client, connection) = h2::client::handshake(bridge(down, up))
        .await
        .map_err(h2_error)?;
    tokio::spawn(async move {
        if let Err(error) = connection.await {
            tracing::debug!(%error, "grpc: connection closed");
        }
    });
    Ok(client)
}

impl GrpcConfig {
    /// Готовое к новому потоку соединение: общее или новое, если общее умерло.
    async fn client(
        &self,
        server: &TargetAddr,
        security: &Security,
        alpn: &[String],
    ) -> Result<SendRequest<Bytes>> {
        let mut slot = self.pool.lock().await;
        if let Some(client) = slot.clone()
            && let Ok(ready) = client.ready().await
        {
            return Ok(ready);
        }
        let fresh = connect(server, security, alpn).await?;
        *slot = Some(fresh.clone());
        fresh.ready().await.map_err(h2_error)
    }
}

/// Открывает поток gRPC к серверу.
pub async fn open(
    config: &GrpcConfig,
    server: &TargetAddr,
    security: &Security,
    alpn: &[String],
) -> Result<(GrpcReader, GrpcWriter)> {
    let mut client = config.client(server, security, alpn).await?;
    // Схема https и без TLS — так делает sing-box (h2c с той же схемой).
    let uri = format!(
        "https://{}/{}/Tun",
        authority(server, security),
        path_escape(&config.service_name)
    );
    let request = http::Request::builder()
        .method(http::Method::POST)
        .uri(uri)
        .header("content-type", "application/grpc")
        .header("user-agent", USER_AGENT)
        .header("te", "trailers")
        .body(())
        .map_err(|_| EngineError::Protocol("grpc: bad request"))?;
    let (response, send) = client.send_request(request, false).map_err(h2_error)?;
    Ok((
        GrpcReader {
            response: Some(response),
            body: None,
            buf: Vec::new(),
        },
        GrpcWriter { send },
    ))
}

/// Сообщение gun с данными.
fn encode(data: &[u8]) -> Vec<u8> {
    let mut varint = Vec::with_capacity(10);
    let mut len = data.len() as u64;
    loop {
        let byte = (len & 0x7F) as u8;
        len >>= 7;
        if len == 0 {
            varint.push(byte);
            break;
        }
        varint.push(byte | 0x80);
    }
    let message_len = 1 + varint.len() + data.len();
    let mut out = Vec::with_capacity(5 + message_len);
    out.push(0);
    out.extend_from_slice(&(message_len as u32).to_be_bytes());
    out.push(0x0A);
    out.extend_from_slice(&varint);
    out.extend_from_slice(data);
    out
}

/// Данные первого целого сообщения из буфера; `None` — сообщение не целое.
fn decode(buf: &mut Vec<u8>) -> Result<Option<Vec<u8>>> {
    if buf.len() < 5 {
        return Ok(None);
    }
    let len = u32::from_be_bytes([buf[1], buf[2], buf[3], buf[4]]) as usize;
    if len > MAX_MESSAGE {
        return Err(EngineError::Protocol("grpc: message too large"));
    }
    if buf.len() < 5 + len {
        return Ok(None);
    }
    let message: Vec<u8> = buf.drain(..5 + len).skip(5).collect();
    let bad = || EngineError::Protocol("grpc: bad message");
    if message.first() != Some(&0x0A) {
        return Err(bad());
    }
    let mut size = 0u64;
    let mut offset = 1;
    loop {
        let byte = *message.get(offset).ok_or_else(bad)?;
        size |= u64::from(byte & 0x7F) << (7 * (offset - 1));
        offset += 1;
        if byte & 0x80 == 0 {
            break;
        }
        if offset > 10 {
            return Err(bad());
        }
    }
    let end = offset.checked_add(size as usize).ok_or_else(bad)?;
    Ok(Some(message.get(offset..end).ok_or_else(bad)?.to_vec()))
}

pub struct GrpcReader {
    response: Option<ResponseFuture>,
    body: Option<RecvStream>,
    buf: Vec<u8>,
}

impl GrpcReader {
    pub async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if let Some(response) = self.response.take() {
            let response = response.await.map_err(h2_error)?;
            if response.status() != http::StatusCode::OK {
                return Err(EngineError::Transport(format!(
                    "grpc: unexpected status {}",
                    response.status()
                )));
            }
            self.body = Some(response.into_body());
        }
        loop {
            if let Some(data) = decode(&mut self.buf)? {
                if data.is_empty() {
                    continue;
                }
                return Ok(Some(data));
            }
            let Some(body) = self.body.as_mut() else {
                return Err(EngineError::Protocol("grpc: reader is gone"));
            };
            match body.data().await {
                None => return Ok(None),
                Some(Ok(bytes)) => {
                    let _ = body.flow_control().release_capacity(bytes.len());
                    self.buf.extend_from_slice(&bytes);
                }
                Some(Err(error)) => return Err(h2_error(error)),
            }
        }
    }
}

pub struct GrpcWriter {
    send: SendStream<Bytes>,
}

impl GrpcWriter {
    pub async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        let mut frame = Bytes::from(encode(data));
        while !frame.is_empty() {
            self.send.reserve_capacity(frame.len());
            let capacity = std::future::poll_fn(|cx| self.send.poll_capacity(cx))
                .await
                .ok_or(EngineError::Protocol("grpc: stream closed"))?
                .map_err(h2_error)?;
            if capacity == 0 {
                continue;
            }
            let chunk = frame.split_to(capacity.min(frame.len()));
            self.send.send_data(chunk, false).map_err(h2_error)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn messages_round_trip() {
        for len in [0usize, 1, 127, 128, 300, 70_000] {
            let data: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
            let mut buf = encode(&data);
            buf.extend_from_slice(&encode(b"next"));
            let first = buf.len() - encode(b"next").len();
            let mut partial = buf[..first - 1].to_vec();
            assert!(decode(&mut partial).unwrap().is_none());
            assert_eq!(decode(&mut buf).unwrap().unwrap(), data, "{len}");
            assert_eq!(decode(&mut buf).unwrap().unwrap(), b"next");
            assert!(buf.is_empty());
        }
        // Заголовок как в sing-box: длина сообщения, тег 0x0A, varint.
        assert_eq!(encode(b"ab"), [0, 0, 0, 0, 4, 0x0A, 2, b'a', b'b']);
    }

    #[test]
    fn escapes_service_name_and_builds_authority() {
        assert_eq!(path_escape("GunService"), "GunService");
        assert_eq!(path_escape("a/b c"), "a%2Fb%20c");
        let server = TargetAddr::Ip("10.0.0.1:443".parse().unwrap());
        assert_eq!(authority(&server, &Security::None), "10.0.0.1:443");
        let tls = Security::Tls(crate::tls::TlsConfig::new("example.com", false, None).unwrap());
        assert_eq!(authority(&server, &tls), "example.com:443");
    }
}
