//! Hysteria2 поверх QUIC. Эталон: hysteria `core/internal/protocol`,
//! клиент sing-box (`sing-quic/hysteria2`).
//!
//! Одно соединение QUIC на сервер, общее для всех подключений. После
//! рукопожатия клиент проходит авторизацию запросом HTTP/3
//! `POST https://hysteria/auth` с заголовком `Hysteria-Auth`; сервер
//! отвечает статусом 233. Дальше каждое TCP-подключение — свой
//! двунаправленный поток QUIC:
//!
//! - запрос: `[varint 0x401][varint длина][адрес host:port][varint длина][паддинг]`;
//! - ответ: `[u8 статус: 0 — ок][varint длина][текст][varint длина][паддинг]`;
//! - дальше — сырые данные.
//!
//! Запрос уходит вместе с первыми данными клиента, ответ читается при
//! первом чтении — как у sing-box.
//!
//! UDP — датаграммы QUIC (если сервер ответил `Hysteria-UDP: true`):
//! `[u32 сессия][u16 пакет][u8 номер куска][u8 кусков][varint длина][адрес][данные]`.
//! Датаграмма больше допустимой режется на куски с общим номером пакета.
//!
//! С `server_ports` порт меняется раз в `hop_interval` (`udphop`).
//! Управление перегрузкой — BBR: скорость канала серверу не сообщается
//! (`Hysteria-CC-RX: 0`), Brutal не используется.

use std::collections::HashMap;
use std::fmt;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Weak};
use std::time::Duration;

use bytes::Bytes;
use quinn::crypto::rustls::QuicClientConfig;
use quinn::{AsyncUdpSocket, Runtime as _, TokioRuntime, VarInt};
use tokio::sync::{Mutex, mpsc};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::relay::{ChunkRead, PayloadWrite};
use crate::salamander::Salamander;
use crate::tls::TlsConfig;
use crate::tls::hello::random_bytes;
use crate::udphop::{self, Hopper};

const FRAME_TCP_REQUEST: u64 = 0x401;
const STATUS_AUTH_OK: u16 = 233;
const MAX_MESSAGE: u64 = 2048;
const MAX_PADDING: u64 = 4096;
const READ_SIZE: usize = 32 * 1024;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// Окна приёма и таймауты — как у клиента hysteria.
const STREAM_WINDOW: u32 = 8 * 1024 * 1024;
const CONNECTION_WINDOW: u32 = 20 * 1024 * 1024;
const IDLE_TIMEOUT: Duration = Duration::from_secs(30);
const KEEP_ALIVE: Duration = Duration::from_secs(10);
/// Очередь принятых датаграмм одной UDP-сессии; дальше — отбрасываем.
const UDP_QUEUE: usize = 1024;
/// Наибольшее UDP-сообщение у hysteria.
const MAX_UDP: usize = 4096;

const PADDING_CHARS: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

#[derive(Clone)]
pub struct Hysteria2Config {
    pub server: TargetAddr,
    /// Диапазоны портов (`server_ports`): порт нового соединения
    /// выбирается из них случайно. Пусто — порт `server`.
    pub ports: Vec<(u16, u16)>,
    /// Как часто менять порт, если задан `ports`.
    pub hop_interval: Duration,
    /// Какие подключения разрешены (`network` sing-box): TCP и UDP.
    pub tcp: bool,
    pub udp: bool,
    password: String,
    pub tls: TlsConfig,
    /// Пароль обфускации salamander.
    obfs: Option<String>,
    session: Arc<Mutex<Option<Session>>>,
}

impl fmt::Debug for Hysteria2Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Пароли — пропуск к серверу: в журнал не попадают.
        f.debug_struct("Hysteria2Config")
            .field("server", &self.server)
            .field("ports", &self.ports)
            .field("hop_interval", &self.hop_interval)
            .field("tls", &self.tls)
            .field("obfs", &self.obfs.is_some())
            .finish_non_exhaustive()
    }
}

/// Соединение QUIC после авторизации.
struct Session {
    connection: quinn::Connection,
    /// UDP-сессии; `None` — сервер UDP не разрешил.
    udp: Option<Arc<UdpMux>>,
    _endpoint: quinn::Endpoint,
    /// Пока жив, HTTP/3 не закрывает соединение (управляющий поток).
    _h3: h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>,
}

fn quic_error(error: impl fmt::Display) -> EngineError {
    EngineError::Transport(format!("hysteria2: {error}"))
}

impl Hysteria2Config {
    pub fn new(server: TargetAddr, password: &str, tls: TlsConfig, obfs: Option<&str>) -> Self {
        Self {
            server,
            ports: Vec::new(),
            hop_interval: udphop::DEFAULT_INTERVAL,
            tcp: true,
            udp: true,
            password: password.to_owned(),
            tls,
            obfs: obfs.map(str::to_owned),
            session: Arc::new(Mutex::new(None)),
        }
    }

    /// Живое соединение: общее или новое, если общего нет или оно закрыто.
    async fn connection(&self, fresh: bool) -> Result<quinn::Connection> {
        Ok(self.live(fresh).await?.0)
    }

    async fn live(&self, fresh: bool) -> Result<(quinn::Connection, Option<Arc<UdpMux>>)> {
        let mut slot = self.session.lock().await;
        if !fresh
            && let Some(session) = slot.as_ref()
            && session.connection.close_reason().is_none()
        {
            return Ok((session.connection.clone(), session.udp.clone()));
        }
        if let Some(old) = slot.take() {
            old.connection.close(VarInt::from_u32(0), b"");
        }
        let session = tokio::time::timeout(HANDSHAKE_TIMEOUT, self.handshake())
            .await
            .map_err(|_| EngineError::Transport("hysteria2: handshake timed out".into()))??;
        let live = (session.connection.clone(), session.udp.clone());
        *slot = Some(session);
        Ok(live)
    }

    fn pick_port(&self) -> Result<u16> {
        Ok(udphop::random_port(&self.ports)?.unwrap_or(self.server.port()))
    }

    async fn handshake(&self) -> Result<Session> {
        let port = self.pick_port()?;
        let target = match &self.server {
            TargetAddr::Ip(addr) => TargetAddr::Ip(SocketAddr::new(addr.ip(), port)),
            TargetAddr::Domain(host, _) => TargetAddr::Domain(host.clone(), port),
        };
        let mut last = None;
        for addr in crate::netbind::resolve(&target).await? {
            match self.dial(addr).await {
                Ok(session) => return Ok(session),
                Err(error) => last = Some(error),
            }
        }
        Err(last.unwrap_or_else(|| EngineError::Transport("hysteria2: no addresses".into())))
    }

    async fn dial(&self, addr: SocketAddr) -> Result<Session> {
        let runtime = Arc::new(TokioRuntime);
        let socket: Arc<dyn AsyncUdpSocket> = if self.ports.is_empty() {
            runtime.wrap_udp_socket(crate::netbind::udp_socket(addr)?)?
        } else {
            Hopper::start(
                addr,
                self.ports.clone(),
                self.hop_interval,
                Arc::clone(&runtime),
            )?
        };
        let socket: Arc<dyn AsyncUdpSocket> = match &self.obfs {
            Some(password) => Arc::new(Salamander::new(socket, password)),
            None => socket,
        };
        let mut endpoint = quinn::Endpoint::new_with_abstract_socket(
            quinn::EndpointConfig::default(),
            None,
            socket,
            runtime,
        )?;
        let crypto =
            QuicClientConfig::try_from(self.tls.rustls_client(&[b"h3"])?).map_err(quic_error)?;
        let mut client = quinn::ClientConfig::new(Arc::new(crypto));
        client.transport_config(Arc::new(transport_config()?));
        endpoint.set_default_client_config(client);

        let connection = endpoint
            .connect(addr, &self.tls.server_name)
            .map_err(quic_error)?
            .await
            .map_err(quic_error)?;
        match self.authenticate(&connection).await {
            Ok((h3, udp)) => Ok(Session {
                udp: udp.then(|| UdpMux::start(connection.clone())),
                connection,
                _endpoint: endpoint,
                _h3: h3,
            }),
            Err(error) => {
                connection.close(VarInt::from_u32(0), b"");
                Err(error)
            }
        }
    }

    /// Авторизация; `true` — сервер разрешил UDP.
    async fn authenticate(
        &self,
        connection: &quinn::Connection,
    ) -> Result<(h3::client::SendRequest<h3_quinn::OpenStreams, Bytes>, bool)> {
        let (mut driver, mut send) = h3::client::new(h3_quinn::Connection::new(connection.clone()))
            .await
            .map_err(quic_error)?;
        tokio::spawn(async move {
            let error = std::future::poll_fn(|cx| driver.poll_close(cx)).await;
            tracing::debug!(%error, "hysteria2: connection closed");
        });
        let request = http::Request::post("https://hysteria/auth")
            .header("Hysteria-Auth", self.password.as_str())
            .header("Hysteria-CC-RX", "0")
            .header("Hysteria-Padding", padding(256, 2048)?)
            .body(())
            .map_err(|_| EngineError::Protocol("hysteria2: bad auth request"))?;
        let mut stream = send.send_request(request).await.map_err(quic_error)?;
        stream.finish().await.map_err(quic_error)?;
        let response = stream.recv_response().await.map_err(quic_error)?;
        if response.status().as_u16() != STATUS_AUTH_OK {
            return Err(EngineError::Protocol("hysteria2: authentication failed"));
        }
        let udp = response
            .headers()
            .get("Hysteria-UDP")
            .and_then(|v| v.to_str().ok())
            .is_some_and(|v| v.eq_ignore_ascii_case("true") || v == "1");
        Ok((send, udp))
    }
}

fn transport_config() -> Result<quinn::TransportConfig> {
    let mut config = quinn::TransportConfig::default();
    config
        .stream_receive_window(VarInt::from_u32(STREAM_WINDOW))
        .receive_window(VarInt::from_u32(CONNECTION_WINDOW))
        .max_idle_timeout(Some(
            quinn::IdleTimeout::try_from(IDLE_TIMEOUT).map_err(quic_error)?,
        ))
        .keep_alive_interval(Some(KEEP_ALIVE))
        .congestion_controller_factory(Arc::new(quinn::congestion::BbrConfig::default()));
    Ok(config)
}

/// Случайная строка из букв и цифр длиной от `min` до `max - 1`.
fn padding(min: usize, max: usize) -> Result<String> {
    let len = min + usize::from(u16::from_le_bytes(random_bytes()?)) % (max - min);
    let mut out = String::with_capacity(len);
    let mut pool = Vec::new();
    while out.len() < len {
        if pool.is_empty() {
            pool = random_bytes::<64>()?.to_vec();
        }
        if let Some(byte) = pool.pop() {
            out.push(char::from(
                PADDING_CHARS[usize::from(byte) % PADDING_CHARS.len()],
            ));
        }
    }
    Ok(out)
}

/// Целое переменной длины QUIC (RFC 9000, 16).
fn put_varint(out: &mut Vec<u8>, value: u64) -> Result<()> {
    match value {
        0..=0x3F => out.push(value as u8),
        0x40..=0x3FFF => out.extend_from_slice(&(value as u16 | 0x4000).to_be_bytes()),
        0x4000..=0x3FFF_FFFF => out.extend_from_slice(&(value as u32 | 0x8000_0000).to_be_bytes()),
        0x4000_0000..=0x3FFF_FFFF_FFFF_FFFF => {
            out.extend_from_slice(&(value | 0xC000_0000_0000_0000).to_be_bytes());
        }
        _ => return Err(EngineError::Protocol("hysteria2: varint too large")),
    }
    Ok(())
}

/// Читает целое с позиции `at`; `None` — данных пока не хватает.
fn get_varint(buf: &[u8], at: &mut usize) -> Option<u64> {
    let first = *buf.get(*at)?;
    let len = 1usize << (first >> 6);
    let bytes = buf.get(*at..*at + len)?;
    let mut value = u64::from(first & 0x3F);
    for byte in &bytes[1..] {
        value = (value << 8) | u64::from(*byte);
    }
    *at += len;
    Some(value)
}

/// Кадр запроса TCP-подключения к `target`.
pub fn tcp_request(target: &TargetAddr) -> Result<Vec<u8>> {
    let address = target.to_string();
    let padding = padding(64, 512)?;
    let mut out = Vec::with_capacity(16 + address.len() + padding.len());
    put_varint(&mut out, FRAME_TCP_REQUEST)?;
    put_varint(&mut out, address.len() as u64)?;
    out.extend_from_slice(address.as_bytes());
    put_varint(&mut out, padding.len() as u64)?;
    out.extend_from_slice(padding.as_bytes());
    Ok(out)
}

/// Разбирает ответ сервера из начала `buf`: длина ответа, если он целый.
fn parse_response(buf: &[u8]) -> Result<Option<usize>> {
    let Some(&status) = buf.first() else {
        return Ok(None);
    };
    let mut at = 1;
    let Some(message_len) = get_varint(buf, &mut at) else {
        return Ok(None);
    };
    if message_len > MAX_MESSAGE {
        return Err(EngineError::Protocol(
            "hysteria2: response message too long",
        ));
    }
    let message = at..at + message_len as usize;
    at = message.end;
    if buf.len() < at {
        return Ok(None);
    }
    let Some(padding_len) = get_varint(buf, &mut at) else {
        return Ok(None);
    };
    if padding_len > MAX_PADDING {
        return Err(EngineError::Protocol(
            "hysteria2: response padding too long",
        ));
    }
    at += padding_len as usize;
    if buf.len() < at {
        return Ok(None);
    }
    if status != 0 {
        // Текст сервера («connect failed…») — в журнал, не человеку.
        let text = String::from_utf8_lossy(buf.get(message).unwrap_or_default());
        tracing::debug!(%text, "hysteria2: server refused the connection");
        return Err(EngineError::Protocol(
            "hysteria2: server refused the connection",
        ));
    }
    Ok(Some(at))
}

pub struct Hysteria2Reader {
    recv: quinn::RecvStream,
    /// Ответ сервера ещё не прочитан.
    awaiting_response: bool,
    buf: Vec<u8>,
}

pub struct Hysteria2Writer {
    send: quinn::SendStream,
    header: Option<Vec<u8>>,
}

/// Открывает поток к `target`. Если общее соединение умерло, пробует
/// один раз на новом.
pub async fn connect(
    config: &Hysteria2Config,
    target: &TargetAddr,
    initial: &[u8],
) -> Result<(Hysteria2Reader, Hysteria2Writer)> {
    if !config.tcp {
        return Err(EngineError::Unsupported("hysteria2 tcp disabled".into()));
    }
    let connection = config.connection(false).await?;
    let (send, recv) = match connection.open_bi().await {
        Ok(streams) => streams,
        Err(error) => {
            tracing::debug!(%error, "hysteria2: reconnecting");
            config
                .connection(true)
                .await?
                .open_bi()
                .await
                .map_err(quic_error)?
        }
    };
    let mut writer = Hysteria2Writer {
        send,
        header: Some(tcp_request(target)?),
    };
    if !initial.is_empty() {
        writer.write_payload(initial).await?;
    }
    Ok((
        Hysteria2Reader {
            recv,
            awaiting_response: true,
            buf: Vec::new(),
        },
        writer,
    ))
}

impl Hysteria2Reader {
    async fn read_raw(&mut self) -> Result<Option<Vec<u8>>> {
        match self.recv.read_chunk(READ_SIZE, true).await {
            Ok(Some(chunk)) => Ok(Some(chunk.bytes.to_vec())),
            Ok(None) => Ok(None),
            Err(error) => Err(quic_error(error)),
        }
    }
}

impl ChunkRead for Hysteria2Reader {
    async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        while self.awaiting_response {
            if let Some(end) = parse_response(&self.buf)? {
                self.awaiting_response = false;
                self.buf.drain(..end);
                break;
            }
            let chunk = self
                .read_raw()
                .await?
                .ok_or(EngineError::Protocol("hysteria2: closed before response"))?;
            self.buf.extend_from_slice(&chunk);
        }
        if !self.buf.is_empty() {
            return Ok(Some(std::mem::take(&mut self.buf)));
        }
        self.read_raw().await
    }
}

impl Hysteria2Writer {
    async fn send(&mut self, data: &[u8]) -> Result<()> {
        self.send.write_all(data).await.map_err(quic_error)
    }
}

impl PayloadWrite for Hysteria2Writer {
    async fn write_payload(&mut self, data: &[u8]) -> Result<()> {
        match self.header.take() {
            Some(mut first) => {
                first.extend_from_slice(data);
                self.send(&first).await
            }
            None => self.send(data).await,
        }
    }

    async fn flush_header(&mut self) -> Result<()> {
        match self.header.take() {
            Some(header) => self.send(&header).await,
            None => Ok(()),
        }
    }
}

/// Кусок UDP-сообщения с сервера.
#[derive(Debug, Clone, PartialEq, Eq)]
struct UdpMessage {
    session: u32,
    packet: u16,
    fragment: u8,
    fragments: u8,
    addr: String,
    data: Bytes,
}

fn udp_header(
    session: u32,
    packet: u16,
    fragment: u8,
    fragments: u8,
    addr: &str,
) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(12 + addr.len());
    out.extend_from_slice(&session.to_be_bytes());
    out.extend_from_slice(&packet.to_be_bytes());
    out.push(fragment);
    out.push(fragments);
    put_varint(&mut out, addr.len() as u64)?;
    out.extend_from_slice(addr.as_bytes());
    Ok(out)
}

/// Разбор датаграммы; `None` — испорченная (как `ParseUDPMessage`).
fn parse_udp(datagram: &Bytes) -> Option<UdpMessage> {
    let head = datagram.get(..8)?;
    let mut at = 8;
    let addr_len = usize::try_from(get_varint(datagram, &mut at)?).ok()?;
    if addr_len == 0 || addr_len > MAX_MESSAGE as usize || datagram.len() <= at + addr_len {
        return None;
    }
    let addr = std::str::from_utf8(&datagram[at..at + addr_len]).ok()?;
    Some(UdpMessage {
        session: u32::from_be_bytes([head[0], head[1], head[2], head[3]]),
        packet: u16::from_be_bytes([head[4], head[5]]),
        fragment: head[6],
        fragments: head[7],
        addr: addr.to_owned(),
        data: datagram.slice(at + addr_len..),
    })
}

/// Сборка кусков одного пакета; как в hysteria, помнится только последний.
#[derive(Default)]
struct Defragger {
    packet: u16,
    parts: Vec<Option<UdpMessage>>,
    received: usize,
}

impl Defragger {
    fn feed(&mut self, message: UdpMessage) -> Option<(Vec<u8>, String)> {
        if message.fragments <= 1 {
            return Some((message.data.to_vec(), message.addr));
        }
        if message.fragment >= message.fragments {
            return None;
        }
        let index = usize::from(message.fragment);
        if message.packet != self.packet || self.parts.len() != usize::from(message.fragments) {
            self.packet = message.packet;
            self.parts = vec![None; usize::from(message.fragments)];
            self.received = 0;
        }
        if self.parts[index].is_some() {
            return None;
        }
        self.parts[index] = Some(message);
        self.received += 1;
        if self.received < self.parts.len() {
            return None;
        }
        let parts = std::mem::take(&mut self.parts);
        self.received = 0;
        let mut data = Vec::new();
        let mut addr = String::new();
        for part in parts.into_iter().flatten() {
            data.extend_from_slice(&part.data);
            addr = part.addr;
        }
        Some((data, addr))
    }
}

/// UDP-сессии одного соединения: датаграммы раздаются по номеру сессии.
struct UdpMux {
    connection: quinn::Connection,
    sessions: std::sync::Mutex<HashMap<u32, mpsc::Sender<UdpMessage>>>,
    next: AtomicU32,
}

impl UdpMux {
    fn start(connection: quinn::Connection) -> Arc<Self> {
        let mux = Arc::new(Self {
            connection: connection.clone(),
            sessions: std::sync::Mutex::new(HashMap::new()),
            next: AtomicU32::new(1),
        });
        tokio::spawn(read_datagrams(connection, Arc::downgrade(&mux)));
        mux
    }

    fn sessions(&self) -> std::sync::MutexGuard<'_, HashMap<u32, mpsc::Sender<UdpMessage>>> {
        self.sessions.lock().unwrap_or_else(|p| p.into_inner())
    }
}

async fn read_datagrams(connection: quinn::Connection, mux: Weak<UdpMux>) {
    while let Ok(datagram) = connection.read_datagram().await {
        let Some(mux) = mux.upgrade() else {
            return;
        };
        let Some(message) = parse_udp(&datagram) else {
            continue;
        };
        if let Some(session) = mux.sessions().get(&message.session) {
            // Очередь полна — пакет теряется, как у hysteria.
            let _ = session.try_send(message);
        }
    }
    // Соединение закрылось: сессии получат конец.
    if let Some(mux) = mux.upgrade() {
        mux.sessions().clear();
    }
}

/// UDP-сессия Hysteria2: пакеты к любым адресам и ответы от них.
pub struct Hysteria2Udp {
    id: u32,
    mux: Arc<UdpMux>,
    incoming: mpsc::Receiver<UdpMessage>,
    defragger: Defragger,
}

impl Drop for Hysteria2Udp {
    fn drop(&mut self) {
        self.mux.sessions().remove(&self.id);
    }
}

/// Новая UDP-сессия на общем соединении.
pub async fn udp(config: &Hysteria2Config) -> Result<Hysteria2Udp> {
    if !config.udp {
        return Err(EngineError::Unsupported("hysteria2 udp disabled".into()));
    }
    let (_, mut mux) = config.live(false).await?;
    if mux.is_none() {
        // Сервер UDP не разрешил — или соединение умерло между делом.
        mux = config.live(true).await?.1;
    }
    let mux = mux.ok_or(EngineError::Protocol("hysteria2: udp disabled by server"))?;
    let id = mux.next.fetch_add(1, Ordering::Relaxed);
    let (sender, incoming) = mpsc::channel(UDP_QUEUE);
    mux.sessions().insert(id, sender);
    Ok(Hysteria2Udp {
        id,
        mux,
        incoming,
        defragger: Defragger::default(),
    })
}

impl Hysteria2Udp {
    pub async fn send(&self, target: &TargetAddr, data: &[u8]) -> Result<()> {
        if data.len() > MAX_UDP {
            return Err(EngineError::Protocol("hysteria2: udp packet too large"));
        }
        let connection = &self.mux.connection;
        let max = connection
            .max_datagram_size()
            .ok_or(EngineError::Protocol("hysteria2: datagrams unsupported"))?;
        let addr = target.to_string();
        let mut whole = udp_header(self.id, 0, 0, 1, &addr)?;
        if whole.len() + data.len() <= max {
            whole.extend_from_slice(data);
            return connection
                .send_datagram(Bytes::from(whole))
                .map_err(quic_error);
        }
        // Не влезает в датаграмму — куски с общим номером пакета.
        let room = max.saturating_sub(whole.len());
        let count = data.len().div_ceil(room.max(1));
        let count = u8::try_from(count)
            .ok()
            .filter(|_| room > 0)
            .ok_or(EngineError::Protocol("hysteria2: udp packet too large"))?;
        let packet = u16::from_le_bytes(random_bytes()?).max(1);
        for (index, chunk) in data.chunks(room).enumerate() {
            let mut fragment = udp_header(self.id, packet, index as u8, count, &addr)?;
            fragment.extend_from_slice(chunk);
            connection
                .send_datagram(Bytes::from(fragment))
                .map_err(quic_error)?;
        }
        Ok(())
    }

    /// Следующий пакет и адрес отправителя (`host:port`); `None` — соединение закрыто.
    pub async fn recv(&mut self) -> Option<(Vec<u8>, String)> {
        loop {
            let message = self.incoming.recv().await?;
            if let Some(packet) = self.defragger.feed(message) {
                return Some(packet);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn varints_round_trip() {
        for value in [0u64, 63, 64, 0x401, 16383, 16384, 1 << 30, (1 << 62) - 1] {
            let mut out = Vec::new();
            put_varint(&mut out, value).unwrap();
            let mut at = 0;
            assert_eq!(get_varint(&out, &mut at), Some(value));
            assert_eq!(at, out.len());
        }
        let mut out = Vec::new();
        put_varint(&mut out, 0x401).unwrap();
        assert_eq!(out, [0x44, 0x01]);
        assert!(put_varint(&mut out, 1 << 62).is_err());
        assert_eq!(get_varint(&[0x44], &mut 0), None);
    }

    #[test]
    fn request_frame() {
        let frame = tcp_request(&TargetAddr::Domain("example.com".into(), 443)).unwrap();
        assert_eq!(&frame[..2], &[0x44, 0x01]);
        assert_eq!(frame[2], 15);
        assert_eq!(&frame[3..18], b"example.com:443");
        let mut at = 18;
        let padding = get_varint(&frame, &mut at).unwrap() as usize;
        assert!((64..512).contains(&padding));
        assert_eq!(frame.len(), at + padding);
        let v6 = tcp_request(&TargetAddr::Ip("[::1]:80".parse().unwrap())).unwrap();
        assert_eq!(&v6[3..3 + usize::from(v6[2])], b"[::1]:80");
    }

    #[test]
    fn response_parsing() {
        // Ок без текста и с паддингом, следом — данные.
        let mut ok = vec![0, 0, 3, b'x', b'x', b'x'];
        assert_eq!(parse_response(&ok[..4]).unwrap(), None);
        ok.extend_from_slice(b"data");
        assert_eq!(parse_response(&ok).unwrap(), Some(6));
        // Отказ с текстом.
        let refused = [1, 2, b'n', b'o', 0];
        assert!(parse_response(&refused).is_err());
        assert_eq!(parse_response(&[]).unwrap(), None);
    }

    #[test]
    fn udp_messages_and_fragments() {
        let mut datagram = udp_header(7, 0, 0, 1, "1.2.3.4:53").unwrap();
        datagram.extend_from_slice(b"query");
        let message = parse_udp(&Bytes::from(datagram)).unwrap();
        assert_eq!((message.session, message.fragments), (7, 1));
        assert_eq!(message.addr, "1.2.3.4:53");
        assert_eq!(&message.data[..], b"query");
        // Адрес без данных и пустой адрес — испорченные.
        assert!(parse_udp(&Bytes::from(udp_header(7, 0, 0, 1, "a:1").unwrap())).is_none());
        let mut empty = udp_header(7, 0, 0, 1, "").unwrap();
        empty.push(1);
        assert!(parse_udp(&Bytes::from(empty)).is_none());

        let part = |packet, fragment, data: &'static [u8]| UdpMessage {
            session: 7,
            packet,
            fragment,
            fragments: 2,
            addr: "a:1".into(),
            data: Bytes::from_static(data),
        };
        let mut defragger = Defragger::default();
        assert_eq!(defragger.feed(part(5, 1, b"world")), None);
        // Кусок другого пакета сбрасывает недособранный.
        assert_eq!(defragger.feed(part(6, 0, b"x")), None);
        assert_eq!(defragger.feed(part(6, 0, b"x")), None);
        assert_eq!(
            defragger.feed(part(6, 1, b"y")),
            Some((b"xy".to_vec(), "a:1".into()))
        );
    }

    #[test]
    fn ports_come_from_ranges() {
        let tls = TlsConfig::new("h", true, None).unwrap();
        let mut config = Hysteria2Config::new(TargetAddr::Domain("h".into(), 443), "p", tls, None);
        assert_eq!(config.pick_port().unwrap(), 443);
        config.ports = vec![(20000, 20002), (30000, 30000)];
        for _ in 0..50 {
            let port = config.pick_port().unwrap();
            assert!((20000..=20002).contains(&port) || port == 30000, "{port}");
        }
        assert!(!format!("{config:?}").contains("\"p\""));
    }
}
