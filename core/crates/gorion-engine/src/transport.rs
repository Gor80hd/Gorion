//! Транспорты V2Ray поверх TCP или TLS: WebSocket, HTTPUpgrade, gRPC.
//! Эталон: sing-box `transport/v2raywebsocket`, `v2rayhttpupgrade`,
//! `v2raygrpclite`.
//!
//! WebSocket и HTTPUpgrade начинаются с запроса HTTP/1.1 Upgrade. Запрос
//! уходит при первой записи — так в него попадают ранние данные, — и
//! дальше запись ждёт ответа 101, как клиент sing-box: серверы на gorilla
//! (Xray) рвут подключение, если данные пришли раньше ответа. Поэтому до
//! первой записи обе половины потока у пишущей стороны, а читающая
//! получает свою после рукопожатия.

use std::fmt;

use base64::Engine as _;
use sha1::{Digest, Sha1};
use tokio::sync::oneshot;

use crate::error::{EngineError, Result};
use crate::stream::{Down, Up};
use crate::tls::hello::random_bytes;

pub use crate::grpc::GrpcConfig;

/// Предел заголовков ответа на Upgrade.
const MAX_RESPONSE_HEAD: usize = 16 * 1024;
/// Предел кадра WebSocket от сервера.
const MAX_FRAME: u64 = 16 * 1024 * 1024;
const WS_GUID: &str = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
/// User-Agent по умолчанию у клиентов sing-box (Go).
const GO_USER_AGENT: &str = "Go-http-client/1.1";

const OPCODE_CONTINUATION: u8 = 0;
const OPCODE_TEXT: u8 = 1;
const OPCODE_BINARY: u8 = 2;
const OPCODE_CLOSE: u8 = 8;

#[derive(Debug, Clone)]
pub enum Transport {
    /// Поток как есть.
    None,
    WebSocket(WsConfig),
    HttpUpgrade(UpgradeConfig),
    Grpc(GrpcConfig),
}

impl Transport {
    pub fn is_none(&self) -> bool {
        matches!(self, Self::None)
    }

    /// ALPN для TLS под транспорт. WebSocket и HTTPUpgrade — запросы
    /// HTTP/1.1: если сервер (CDN) выберет h2, Upgrade не сработает.
    /// gRPC — только HTTP/2.
    pub fn alpn(&self, configured: &[String]) -> Vec<String> {
        match self {
            Self::None => configured.to_vec(),
            Self::WebSocket(_) | Self::HttpUpgrade(_) => {
                let without_h2: Vec<String> = configured
                    .iter()
                    .filter(|p| p.as_str() != "h2")
                    .cloned()
                    .collect();
                if without_h2.is_empty() {
                    vec!["http/1.1".into()]
                } else {
                    without_h2
                }
            }
            Self::Grpc(_) => {
                if configured.iter().any(|p| p == "h2") {
                    configured.to_vec()
                } else {
                    vec!["h2".into()]
                }
            }
        }
    }
}

/// Путь запроса: всегда с `/` в начале, как у sing-box.
fn request_path(path: &str) -> String {
    if path.starts_with('/') {
        path.to_owned()
    } else {
        format!("/{path}")
    }
}

#[derive(Clone)]
pub struct WsConfig {
    pub path: String,
    /// Заголовки запроса; `Host` — имя для сервера (по умолчанию адрес).
    pub headers: Vec<(String, String)>,
    /// Сколько первых байт отправить в самом запросе (0 — не отправлять).
    pub max_early_data: usize,
    /// Заголовок для ранних данных; пусто — они дописываются к пути.
    pub early_data_header: String,
}

impl fmt::Debug for WsConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Путь и заголовки бывают секретом сервера: в журнал не попадают.
        f.debug_struct("WsConfig")
            .field("max_early_data", &self.max_early_data)
            .finish_non_exhaustive()
    }
}

#[derive(Clone)]
pub struct UpgradeConfig {
    pub path: String,
    /// Имя для сервера; пусто — имя TLS или адрес сервера.
    pub host: String,
    pub headers: Vec<(String, String)>,
}

impl fmt::Debug for UpgradeConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("UpgradeConfig").finish_non_exhaustive()
    }
}

fn header<'a>(headers: &'a [(String, String)], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(name))
        .map(|(_, value)| value.as_str())
}

/// Запрос Upgrade без завершающей пустой строки и ключ WebSocket (если он).
struct Request {
    head: String,
    ws_key: Option<String>,
}

fn ws_request(config: &WsConfig, server: &str, early: &[u8]) -> Result<Request> {
    let key = base64::engine::general_purpose::STANDARD.encode(random_bytes::<16>()?);
    let mut path = request_path(&config.path);
    let early =
        (!early.is_empty()).then(|| base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(early));
    if let Some(early) = &early
        && config.early_data_header.is_empty()
    {
        path.push_str(early);
    }
    let host = header(&config.headers, "Host").unwrap_or(server);
    // Порядок — как у gobwas/ws, которым пользуется sing-box.
    let mut head = format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n"
    );
    if let Some(early) = &early
        && !config.early_data_header.is_empty()
    {
        head.push_str(&format!("{}: {early}\r\n", config.early_data_header));
    }
    if header(&config.headers, "User-Agent").is_none() {
        head.push_str(&format!("User-Agent: {GO_USER_AGENT}\r\n"));
    }
    for (name, value) in &config.headers {
        if !name.eq_ignore_ascii_case("Host") {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
    }
    Ok(Request {
        head,
        ws_key: Some(key),
    })
}

fn upgrade_request(config: &UpgradeConfig, host: &str) -> Request {
    let path = request_path(&config.path);
    // Как `http.Request.Write` в Go: Host, User-Agent, затем заголовки.
    let mut head = format!("GET {path} HTTP/1.1\r\nHost: {host}\r\n");
    if header(&config.headers, "User-Agent").is_none() {
        head.push_str(&format!("User-Agent: {GO_USER_AGENT}\r\n"));
    }
    head.push_str("Connection: Upgrade\r\nUpgrade: websocket\r\n");
    for (name, value) in &config.headers {
        let reserved = ["Host", "Connection", "Upgrade"]
            .iter()
            .any(|r| name.eq_ignore_ascii_case(r));
        if !reserved {
            head.push_str(&format!("{name}: {value}\r\n"));
        }
    }
    Request { head, ws_key: None }
}

/// Проверяет ответ 101; возвращает байты после заголовков.
fn check_response(head: &str, ws_key: Option<&str>) -> Result<()> {
    let bad = || EngineError::Protocol("transport: upgrade refused");
    let mut lines = head.split("\r\n");
    let status = lines.next().unwrap_or_default();
    let mut parts = status.split(' ');
    if !parts.next().unwrap_or_default().starts_with("HTTP/1.") || parts.next() != Some("101") {
        return Err(bad());
    }
    let headers: Vec<(String, String)> = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(k, v)| (k.trim().to_owned(), v.trim().to_owned()))
        .collect();
    let upgrade = header(&headers, "Upgrade").unwrap_or_default();
    let connection = header(&headers, "Connection").unwrap_or_default();
    if !upgrade.eq_ignore_ascii_case("websocket")
        || !connection
            .split(',')
            .any(|token| token.trim().eq_ignore_ascii_case("upgrade"))
    {
        return Err(bad());
    }
    if let Some(key) = ws_key {
        let accept = base64::engine::general_purpose::STANDARD.encode(
            Sha1::new()
                .chain_update(key.as_bytes())
                .chain_update(WS_GUID.as_bytes())
                .finalize(),
        );
        if header(&headers, "Sec-WebSocket-Accept") != Some(accept.as_str()) {
            return Err(EngineError::Protocol("transport: bad websocket accept"));
        }
    }
    Ok(())
}

/// Кадр WebSocket от клиента: двоичный, с маской.
fn ws_frame(data: &[u8]) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(data.len() + 14);
    out.push(0x80 | OPCODE_BINARY);
    match data.len() {
        len @ 0..=125 => out.push(0x80 | len as u8),
        len @ 126..=0xFFFF => {
            out.push(0x80 | 126);
            out.extend_from_slice(&(len as u16).to_be_bytes());
        }
        len => {
            out.push(0x80 | 127);
            out.extend_from_slice(&(len as u64).to_be_bytes());
        }
    }
    let mask = random_bytes::<4>()?;
    out.extend_from_slice(&mask);
    out.extend(data.iter().enumerate().map(|(i, b)| b ^ mask[i % 4]));
    Ok(out)
}

/// Разбор кадров WebSocket от сервера.
#[derive(Default)]
struct WsDecoder {
    buf: Vec<u8>,
    closed: bool,
}

impl WsDecoder {
    /// Данные из всех целых кадров в буфере.
    fn decode(&mut self) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        loop {
            if self.closed || self.buf.len() < 2 {
                return Ok(out);
            }
            let opcode = self.buf[0] & 0x0F;
            let masked = self.buf[1] & 0x80 != 0;
            let (len, mut offset) = match self.buf[1] & 0x7F {
                126 if self.buf.len() >= 4 => {
                    (u64::from(u16::from_be_bytes([self.buf[2], self.buf[3]])), 4)
                }
                127 if self.buf.len() >= 10 => {
                    let mut b = [0u8; 8];
                    b.copy_from_slice(&self.buf[2..10]);
                    (u64::from_be_bytes(b), 10)
                }
                126 | 127 => return Ok(out),
                len => (u64::from(len), 2),
            };
            if len > MAX_FRAME {
                return Err(EngineError::Protocol("websocket: frame too large"));
            }
            let mask = if masked {
                if self.buf.len() < offset + 4 {
                    return Ok(out);
                }
                let mut m = [0u8; 4];
                m.copy_from_slice(&self.buf[offset..offset + 4]);
                offset += 4;
                Some(m)
            } else {
                None
            };
            let end = offset + len as usize;
            if self.buf.len() < end {
                return Ok(out);
            }
            let payload: Vec<u8> = self.buf.drain(..end).skip(offset).collect();
            match opcode {
                OPCODE_CONTINUATION | OPCODE_TEXT | OPCODE_BINARY => match mask {
                    Some(m) => out.extend(payload.iter().enumerate().map(|(i, b)| b ^ m[i % 4])),
                    None => out.extend_from_slice(&payload),
                },
                OPCODE_CLOSE => self.closed = true,
                // Ping и pong: серверы V2Ray их не шлют, ответ не нужен.
                _ => tracing::debug!(opcode, "websocket: control frame ignored"),
            }
        }
    }
}

/// Читающая половина после рукопожатия.
struct Upgraded {
    down: Down,
    leftover: Vec<u8>,
}

pub struct UpgradeReader {
    pending: Option<oneshot::Receiver<Result<Upgraded>>>,
    down: Option<Down>,
    ws: Option<WsDecoder>,
    leftover: Vec<u8>,
}

enum Handshake {
    WebSocket(WsConfig),
    Upgrade(UpgradeConfig),
}

pub struct UpgradeWriter {
    up: Up,
    /// До первой записи: читающая половина и то, что нужно для запроса.
    pending: Option<(Down, Handshake, oneshot::Sender<Result<Upgraded>>)>,
    websocket: bool,
    /// Адрес сервера и имя TLS — для заголовка Host по умолчанию.
    server: String,
    tls_name: Option<String>,
}

/// WebSocket поверх установленного потока.
pub fn websocket(
    down: Down,
    up: Up,
    config: &WsConfig,
    server: String,
) -> (UpgradeReader, UpgradeWriter) {
    pair(down, up, Handshake::WebSocket(config.clone()), server, None)
}

/// HTTPUpgrade поверх установленного потока.
pub fn http_upgrade(
    down: Down,
    up: Up,
    config: &UpgradeConfig,
    server: String,
    tls_name: Option<String>,
) -> (UpgradeReader, UpgradeWriter) {
    pair(
        down,
        up,
        Handshake::Upgrade(config.clone()),
        server,
        tls_name,
    )
}

fn pair(
    down: Down,
    up: Up,
    handshake: Handshake,
    server: String,
    tls_name: Option<String>,
) -> (UpgradeReader, UpgradeWriter) {
    let (tx, rx) = oneshot::channel();
    let websocket = matches!(handshake, Handshake::WebSocket(_));
    (
        UpgradeReader {
            pending: Some(rx),
            down: None,
            ws: websocket.then(WsDecoder::default),
            leftover: Vec::new(),
        },
        UpgradeWriter {
            up,
            pending: Some((down, handshake, tx)),
            websocket,
            server,
            tls_name,
        },
    )
}

impl UpgradeWriter {
    async fn handshake(
        &mut self,
        mut down: Down,
        handshake: Handshake,
        data: &[u8],
    ) -> Result<(Upgraded, usize)> {
        let (request, early) = match &handshake {
            Handshake::WebSocket(config) => {
                let early = data.len().min(config.max_early_data);
                (ws_request(config, &self.server, &data[..early])?, early)
            }
            Handshake::Upgrade(config) => {
                let host = if !config.host.is_empty() {
                    config.host.as_str()
                } else {
                    self.tls_name.as_deref().unwrap_or(&self.server)
                };
                (upgrade_request(config, host), 0)
            }
        };
        let mut head = request.head.into_bytes();
        head.extend_from_slice(b"\r\n");
        Box::pin(self.up.write_all(&head)).await?;
        let mut response = Vec::new();
        let end = loop {
            if let Some(end) = response.windows(4).position(|w| w == b"\r\n\r\n") {
                break end;
            }
            if response.len() > MAX_RESPONSE_HEAD {
                return Err(EngineError::Protocol("transport: response too long"));
            }
            // Box: `Down` сам может быть этим транспортом — рекурсия типов.
            let chunk = Box::pin(down.read_chunk())
                .await?
                .ok_or(EngineError::Protocol("transport: closed during upgrade"))?;
            response.extend_from_slice(&chunk);
        };
        let head = String::from_utf8_lossy(&response[..end]).into_owned();
        check_response(&head, request.ws_key.as_deref())?;
        Ok((
            Upgraded {
                down,
                leftover: response.split_off(end + 4),
            },
            early,
        ))
    }

    pub async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        let mut data = data;
        if let Some((down, handshake, tx)) = self.pending.take() {
            match self.handshake(down, handshake, data).await {
                Ok((upgraded, early)) => {
                    let _ = tx.send(Ok(upgraded));
                    data = &data[early..];
                }
                Err(error) => {
                    let _ = tx.send(Err(EngineError::Protocol("transport: upgrade failed")));
                    return Err(error);
                }
            }
        }
        if data.is_empty() {
            return Ok(());
        }
        if self.websocket {
            let frame = ws_frame(data)?;
            Box::pin(self.up.write_all(&frame)).await
        } else {
            Box::pin(self.up.write_all(data)).await
        }
    }
}

impl UpgradeReader {
    pub async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        if let Some(pending) = self.pending.take() {
            let upgraded = pending
                .await
                .map_err(|_| EngineError::Protocol("transport: closed before upgrade"))??;
            self.down = Some(upgraded.down);
            self.leftover = upgraded.leftover;
        }
        loop {
            let chunk = if self.leftover.is_empty() {
                let Some(down) = self.down.as_mut() else {
                    return Err(EngineError::Protocol("transport: reader is gone"));
                };
                match Box::pin(down.read_chunk()).await? {
                    Some(chunk) => chunk,
                    None => return Ok(None),
                }
            } else {
                std::mem::take(&mut self.leftover)
            };
            let Some(ws) = &mut self.ws else {
                return Ok(Some(chunk));
            };
            ws.buf.extend_from_slice(&chunk);
            let data = ws.decode()?;
            if !data.is_empty() {
                return Ok(Some(data));
            }
            if ws.closed {
                return Ok(None);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn frames_round_trip() {
        for len in [0usize, 5, 125, 126, 70_000] {
            let data: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
            let mut decoder = WsDecoder::default();
            let frame = ws_frame(&data).unwrap();
            // Пришло по кусочку — данные появляются, только когда кадр целый.
            decoder.buf.extend_from_slice(&frame[..frame.len() / 2]);
            if len > 0 {
                assert!(decoder.decode().unwrap().is_empty());
            }
            decoder.buf.extend_from_slice(&frame[frame.len() / 2..]);
            assert_eq!(decoder.decode().unwrap(), data, "{len}");
        }
        let mut decoder = WsDecoder::default();
        decoder.buf.extend_from_slice(&[0x88, 0x00]);
        assert!(decoder.decode().unwrap().is_empty());
        assert!(decoder.closed);
    }

    #[test]
    fn websocket_request_and_accept() {
        let config = WsConfig {
            path: "ws".into(),
            headers: vec![("Host".into(), "cdn.example.com".into())],
            max_early_data: 2048,
            early_data_header: "Sec-WebSocket-Protocol".into(),
        };
        let request = ws_request(&config, "1.2.3.4:443", b"hi").unwrap();
        assert!(
            request
                .head
                .starts_with("GET /ws HTTP/1.1\r\nHost: cdn.example.com\r\n")
        );
        assert!(request.head.contains("Sec-WebSocket-Protocol: aGk\r\n"));
        assert!(request.head.contains("User-Agent: Go-http-client/1.1\r\n"));
        let key = request.ws_key.unwrap();
        // RFC 6455, 1.3: пример ключа и ответа.
        let accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=";
        let response = format!(
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}"
        );
        assert!(check_response(&response, Some("dGhlIHNhbXBsZSBub25jZQ==")).is_ok());
        assert!(check_response(&response, Some(&key)).is_err());
        assert!(check_response("HTTP/1.1 404 Not Found", None).is_err());

        // Без заголовка — ранние данные в пути; Host по умолчанию — адрес.
        let config = WsConfig {
            early_data_header: String::new(),
            headers: Vec::new(),
            path: "/ws".into(),
            ..config
        };
        let request = ws_request(&config, "1.2.3.4:443", b"hi").unwrap();
        assert!(
            request
                .head
                .starts_with("GET /wsaGk HTTP/1.1\r\nHost: 1.2.3.4:443\r\n")
        );
    }

    #[test]
    fn alpn_follows_transport() {
        let default = vec!["h2".to_owned(), "http/1.1".to_owned()];
        let ws = Transport::WebSocket(WsConfig {
            path: String::new(),
            headers: Vec::new(),
            max_early_data: 0,
            early_data_header: String::new(),
        });
        assert_eq!(ws.alpn(&default), ["http/1.1"]);
        assert_eq!(ws.alpn(&["h2".to_owned()]), ["http/1.1"]);
        assert_eq!(Transport::None.alpn(&default), default);
    }
}
