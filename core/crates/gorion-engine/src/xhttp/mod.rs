//! Транспорт XHTTP (SplitHTTP) из Xray: поток идёт обычными запросами
//! HTTP, которые проходят через CDN. Эталон: Xray-core 26.3
//! `transport/internet/splithttp` (`dialer.go`, `client.go`, `config.go`).
//!
//! Режимы:
//! - **packet-up** — скачивание одним `GET {путь}{сессия}`, отправка —
//!   запросами `POST {путь}{сессия}/{номер}` с куском данных;
//!   сервер собирает куски по номерам;
//! - **stream-up** — тот же `GET` и один `POST {путь}{сессия}` с потоковым
//!   телом;
//! - **stream-one** — один `POST {путь}`: тело запроса — отправка, тело
//!   ответа — приём;
//! - **auto** — поверх REALITY stream-one (stream-up, если скачивание идёт
//!   отдельно), иначе packet-up.
//!
//! Версия HTTP — как решает Xray: REALITY — HTTP/2; без TLS — HTTP/1.1;
//! TLS с ALPN ровно `http/1.1` — HTTP/1.1, ровно `h3` — HTTP/3 (QUIC),
//! иначе HTTP/2. Соединения HTTP/2 и HTTP/3 переиспользуются по правилам
//! xmux (`conn.rs`).
//!
//! Как выглядит запрос (метод, где сессия, номер, данные куска и паддинг)
//! — в `request.rs`. `downloadSettings` — скачивание (`GET`) идёт к другому
//! серверу со своей защитой и настройками, отправка — к основному.

mod conn;
mod h1;
mod request;

use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use bytes::{Buf, Bytes};
use h2::client::ResponseFuture;
use h2::{RecvStream, SendStream};
use tokio::sync::{Mutex, mpsc};
use tokio::time::Instant;

use self::conn::{H3Recv, H3Send, MuxConn, Pool, Usage, h2_error, h3_error};
use self::h1::{H1Download, H1Uploader};
use self::request::Kind;
use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::stream::{Security, Up};
use crate::tls::hello::random_bytes;

/// Сколько кусков отправки ждут своей очереди (обратное давление).
const UPLOAD_QUEUE: usize = 64;
/// Сколько запросов с кусками одновременно в пути: сервер держит до 30
/// неупорядоченных кусков (`scMaxBufferedPosts`).
const POSTS_IN_FLIGHT: usize = 16;

/// Диапазон чисел Xray (`"100-1000"` или одно число); значение берётся
/// случайно из него.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Range {
    pub from: u64,
    pub to: u64,
}

impl Range {
    pub const fn new(from: u64, to: u64) -> Self {
        Self { from, to }
    }

    pub fn is_zero(&self) -> bool {
        self.to == 0
    }

    fn pick(&self) -> u64 {
        if self.to <= self.from {
            return self.from;
        }
        let spread = self.to - self.from + 1;
        let random = random_bytes::<8>().map(u64::from_le_bytes).unwrap_or(0);
        self.from + random % spread
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Auto,
    PacketUp,
    StreamUp,
    StreamOne,
}

impl Mode {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "" | "auto" => Self::Auto,
            "packet-up" => Self::PacketUp,
            "stream-up" => Self::StreamUp,
            "stream-one" => Self::StreamOne,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HttpVersion {
    H1,
    H2,
    H3,
}

/// Где в запросе сессия или номер куска.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Placement {
    Path,
    Query,
    Header,
    Cookie,
}

impl Placement {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "" | "path" => Self::Path,
            "query" => Self::Query,
            "header" => Self::Header,
            "cookie" => Self::Cookie,
            _ => return None,
        })
    }
}

/// Где данные куска packet-up: в теле (`auto` — тоже), в заголовках
/// `{ключ}-{n}` или в cookie `{ключ}_{n}` (base64url).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DataPlacement {
    Body,
    Header,
    Cookie,
}

impl DataPlacement {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "" | "auto" | "body" => Self::Body,
            "header" => Self::Header,
            "cookie" => Self::Cookie,
            _ => return None,
        })
    }
}

/// Где паддинг при `xPaddingObfsMode`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaddingPlacement {
    /// Адрес с `?{ключ}=паддинг` в заголовке (по умолчанию — `Referer`).
    QueryInHeader,
    Header,
    Cookie,
    Query,
}

impl PaddingPlacement {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "" | "queryInHeader" => Self::QueryInHeader,
            "header" => Self::Header,
            "cookie" => Self::Cookie,
            "query" => Self::Query,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaddingMethod {
    /// `XXXX…`.
    RepeatX,
    /// Случайный base62, длина — после сжатия HPACK.
    Tokenish,
}

impl PaddingMethod {
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "" | "repeat-x" => Self::RepeatX,
            "tokenish" => Self::Tokenish,
            _ => return None,
        })
    }
}

/// Паддинг на своём месте (`xPaddingObfsMode: true`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaddingObfs {
    pub placement: PaddingPlacement,
    /// Имя параметра или cookie (`x_padding`).
    pub key: String,
    /// Имя заголовка (`X-Padding`).
    pub header: String,
    pub method: PaddingMethod,
}

/// Правила переиспользования соединений HTTP/2 и HTTP/3 (xmux).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Xmux {
    /// Сколько сессий одновременно на одном соединении (0 — без предела).
    pub max_concurrency: Range,
    /// Сколько соединений держать (вместо `max_concurrency`).
    pub max_connections: Range,
    /// Сколько сессий всего проводит одно соединение.
    pub c_max_reuse_times: Range,
    /// Сколько запросов всего проводит одно соединение.
    pub h_max_request_times: Range,
    /// Сколько секунд соединение можно брать для новых запросов.
    pub h_max_reusable_secs: Range,
}

impl Xmux {
    /// Что Xray ставит, если `xmux` не задан.
    pub const XRAY_DEFAULT: Self = Self {
        max_concurrency: Range::new(1, 1),
        max_connections: Range::new(0, 0),
        c_max_reuse_times: Range::new(0, 0),
        h_max_request_times: Range::new(600, 900),
        h_max_reusable_secs: Range::new(1800, 3000),
    };
}

/// Скачивание с другого сервера (`downloadSettings`).
pub struct DownloadSettings {
    pub server: TargetAddr,
    pub security: Security,
    /// ALPN из его настроек TLS.
    pub alpn: Vec<String>,
    pub xhttp: XhttpConfig,
}

impl fmt::Debug for DownloadSettings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Адрес сервера скачивания — не для журнала.
        f.debug_struct("DownloadSettings").finish_non_exhaustive()
    }
}

#[derive(Clone)]
pub struct XhttpConfig {
    /// Путь, может быть с `?запросом`.
    pub path: String,
    /// Имя для `Host` / `:authority`; пусто — имя TLS или адрес сервера.
    pub host: String,
    pub mode: Mode,
    pub headers: Vec<(String, String)>,
    pub x_padding_bytes: Range,
    /// `None` — паддинг в `Referer: …?x_padding=XXX`, как обычно в Xray.
    pub padding_obfs: Option<PaddingObfs>,
    /// Метод потоковой отправки и кусков (`uplinkHTTPMethod`).
    pub uplink_method: String,
    pub session_placement: Placement,
    pub session_key: String,
    pub seq_placement: Placement,
    pub seq_key: String,
    pub data_placement: DataPlacement,
    pub data_key: String,
    /// Длина одного заголовка или cookie с данными; 0 — как в Xray.
    pub uplink_chunk_size: Range,
    /// Не ставить `Content-Type: application/grpc` потоковой отправке.
    pub no_grpc_header: bool,
    pub sc_max_each_post_bytes: Range,
    pub sc_min_posts_interval_ms: Range,
    pub xmux: Xmux,
    pub download: Option<Arc<DownloadSettings>>,
    pool: Arc<Mutex<Pool>>,
}

impl fmt::Debug for XhttpConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Путь и имя бывают секретом сервера: в журнал не попадают.
        f.debug_struct("XhttpConfig")
            .field("mode", &self.mode)
            .field("download", &self.download.is_some())
            .finish_non_exhaustive()
    }
}

impl XhttpConfig {
    pub fn new(path: impl Into<String>, host: impl Into<String>, mode: Mode) -> Self {
        Self {
            path: path.into(),
            host: host.into(),
            mode,
            headers: Vec::new(),
            x_padding_bytes: Range::new(100, 1000),
            padding_obfs: None,
            uplink_method: "POST".into(),
            session_placement: Placement::Path,
            session_key: String::new(),
            seq_placement: Placement::Path,
            seq_key: String::new(),
            data_placement: DataPlacement::Body,
            data_key: String::new(),
            uplink_chunk_size: Range::default(),
            no_grpc_header: false,
            sc_max_each_post_bytes: Range::new(1_000_000, 1_000_000),
            sc_min_posts_interval_ms: Range::new(30, 30),
            xmux: Xmux::XRAY_DEFAULT,
            download: None,
            pool: Arc::new(Mutex::new(Pool::default())),
        }
    }

    /// Режим для этой защиты: `auto` раскрывается, как в Xray.
    pub fn resolved_mode(&self, security: &Security) -> Mode {
        match self.mode {
            Mode::Auto if matches!(security, Security::Reality(_)) && self.download.is_some() => {
                Mode::StreamUp
            }
            Mode::Auto if matches!(security, Security::Reality(_)) => Mode::StreamOne,
            Mode::Auto => Mode::PacketUp,
            mode => mode,
        }
    }

    /// `GetNormalizedUplinkChunkSize`.
    fn uplink_chunk_size(&self) -> Range {
        let size = self.uplink_chunk_size;
        if size.is_zero() {
            return match self.data_placement {
                DataPlacement::Cookie => Range::new(2 * 1024, 3 * 1024),
                DataPlacement::Header => Range::new(3000, 4000),
                DataPlacement::Body => self.sc_max_each_post_bytes,
            };
        }
        if size.from < 64 {
            return Range::new(64, size.to.max(64));
        }
        size
    }
}

/// Версия HTTP по защите и заданному ALPN (`decideHTTPVersion` в Xray).
pub fn http_version(security: &Security, alpn: &[String]) -> HttpVersion {
    match security {
        Security::Reality(_) => HttpVersion::H2,
        Security::None => HttpVersion::H1,
        Security::Tls(_) => match alpn {
            [only] if only == "http/1.1" => HttpVersion::H1,
            [only] if only == "h3" => HttpVersion::H3,
            _ => HttpVersion::H2,
        },
    }
}

/// ALPN, который предлагать серверу.
pub fn alpn(security: &Security, configured: &[String]) -> Vec<String> {
    match http_version(security, configured) {
        HttpVersion::H1 => vec!["http/1.1".into()],
        HttpVersion::H3 => vec!["h3".into()],
        HttpVersion::H2 if configured.iter().any(|p| p == "h2") => configured.to_vec(),
        HttpVersion::H2 => vec!["h2".into()],
    }
}

/// Адрес запросов: схема, имя, путь с `/` на конце, запрос.
#[derive(Clone)]
pub struct Base {
    scheme: &'static str,
    authority: String,
    path: String,
    query: String,
}

impl Base {
    fn new(config: &XhttpConfig, server: &TargetAddr, security: &Security) -> Self {
        let (path, query) = config
            .path
            .split_once('?')
            .unwrap_or((config.path.as_str(), ""));
        let mut path = if path.starts_with('/') {
            path.to_owned()
        } else {
            format!("/{path}")
        };
        if !path.ends_with('/') {
            path.push('/');
        }
        let tls_name = match security {
            Security::None => None,
            Security::Tls(tls) => Some(tls.server_name.clone()),
            Security::Reality(reality) => Some(reality.server_name.clone()),
        };
        // Как в Xray: host > имя TLS > адрес сервера (без порта).
        let authority = Some(config.host.clone())
            .filter(|h| !h.is_empty())
            .or(tls_name.filter(|n| !n.is_empty()))
            .unwrap_or_else(|| match server {
                TargetAddr::Domain(host, _) => host.clone(),
                TargetAddr::Ip(addr) if addr.is_ipv6() => format!("[{}]", addr.ip()),
                TargetAddr::Ip(addr) => addr.ip().to_string(),
            });
        Self {
            scheme: if security.is_none() { "http" } else { "https" },
            authority,
            path,
            query: query.to_owned(),
        }
    }
}

fn session_id() -> Result<String> {
    // UUID v4 текстом, как `uuid.New()` в Xray.
    let mut bytes: [u8; 16] = random_bytes()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!(
        "{}-{}-{}-{}-{}",
        &hex[..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    ))
}

fn http_request(request: &request::Request, base: &Base) -> Result<http::Request<()>> {
    let method = http::Method::from_bytes(request.method.as_bytes())
        .map_err(|_| EngineError::Protocol("xhttp: bad method"))?;
    let mut builder = http::Request::builder()
        .method(method)
        .uri(request.url(base));
    for (name, value) in &request.headers {
        builder = builder.header(name, value);
    }
    builder
        .body(())
        .map_err(|_| EngineError::Protocol("xhttp: bad request"))
}

/// Тело запроса с учётом окна HTTP/2.
async fn send_body(send: &mut SendStream<Bytes>, data: &[u8], end: bool) -> Result<()> {
    let mut data = Bytes::copy_from_slice(data);
    if data.is_empty() {
        if end {
            send.send_data(Bytes::new(), true).map_err(h2_error)?;
        }
        return Ok(());
    }
    while !data.is_empty() {
        send.reserve_capacity(data.len());
        let capacity = std::future::poll_fn(|cx| send.poll_capacity(cx))
            .await
            .ok_or(EngineError::Protocol("xhttp: stream closed"))?
            .map_err(h2_error)?;
        if capacity == 0 {
            continue;
        }
        let chunk = data.split_to(capacity.min(data.len()));
        send.send_data(chunk, end && data.is_empty())
            .map_err(h2_error)?;
    }
    Ok(())
}

fn check_status(status: http::StatusCode) -> Result<()> {
    if status == http::StatusCode::OK {
        Ok(())
    } else {
        Err(EngineError::Transport(format!(
            "xhttp: unexpected status {status}"
        )))
    }
}

/// Ответ 200 и его тело, которое потом читается или выбрасывается.
async fn h2_response(response: ResponseFuture) -> Result<RecvStream> {
    let response = response.await.map_err(h2_error)?;
    check_status(response.status())?;
    Ok(response.into_body())
}

/// Читает и выбрасывает тело (паддинг сервера), освобождая окно.
async fn h2_drain(mut body: RecvStream) {
    while let Some(Ok(bytes)) = body.data().await {
        let _ = body.flow_control().release_capacity(bytes.len());
    }
}

async fn h3_response(recv: &mut H3Recv) -> Result<()> {
    let response = recv.recv_response().await.map_err(h3_error)?;
    check_status(response.status())
}

async fn h3_drain(mut recv: H3Recv) -> Result<()> {
    h3_response(&mut recv).await?;
    while recv.recv_data().await.map_err(h3_error)?.is_some() {}
    Ok(())
}

// --- Сессия ---------------------------------------------------------------

enum Download {
    H2Pending(ResponseFuture),
    H2(RecvStream),
    H3Pending(H3Recv),
    H3(H3Recv),
    H1(Box<H1Download>),
}

/// Что сессия держит, пока жива: место в соединении HTTP/2 или HTTP/3 или
/// половину записи соединения с `GET` (HTTP/1.1) — иначе сервер увидит
/// закрытие.
enum Hold {
    Mux(#[allow(dead_code)] Usage),
    H1Get(#[allow(dead_code)] std::sync::Mutex<Up>),
}

pub struct XhttpReader {
    download: Option<Download>,
    _hold: Arc<Vec<Hold>>,
}

enum Upload {
    /// Куски уходят отдельными запросами (packet-up).
    Packets(mpsc::Sender<Vec<u8>>),
    /// Тело одного потокового запроса (stream-up, stream-one).
    H2(SendStream<Bytes>),
    H3(Box<H3Send>),
    H1(Box<Up>),
}

pub struct XhttpWriter {
    upload: Upload,
    _hold: Arc<Vec<Hold>>,
}

/// Сервер и его настройки XHTTP: запросы одной стороны сессии.
struct Endpoint<'a> {
    config: &'a XhttpConfig,
    server: &'a TargetAddr,
    security: &'a Security,
    alpn: Vec<String>,
    version: HttpVersion,
    base: Base,
}

impl<'a> Endpoint<'a> {
    fn new(
        config: &'a XhttpConfig,
        server: &'a TargetAddr,
        security: &'a Security,
        configured_alpn: &[String],
    ) -> Self {
        Self {
            config,
            server,
            security,
            alpn: alpn(security, configured_alpn),
            version: http_version(security, configured_alpn),
            base: Base::new(config, server, security),
        }
    }

    /// Соединение из пула; у HTTP/1.1 пула нет.
    async fn conn(&self) -> Result<Option<Usage>> {
        match self.version {
            HttpVersion::H1 => Ok(None),
            version => Ok(Some(
                self.config
                    .mux_conn(self.server, self.security, &self.alpn, version)
                    .await?,
            )),
        }
    }

    fn mux(conn: Option<&Usage>) -> Result<&Arc<MuxConn>> {
        conn.map(|usage| &usage.0)
            .ok_or(EngineError::Protocol("xhttp: no connection"))
    }

    async fn h1_open(
        &self,
        request: &request::Request,
        streaming: bool,
    ) -> Result<(crate::stream::Down, Up)> {
        h1::open(
            self.server,
            self.security,
            &self.alpn,
            &h1::head(request, &self.base, streaming, false),
        )
        .await
    }

    async fn stream_down(
        &self,
        conn: Option<&Usage>,
        session: &str,
        holds: &mut Vec<Hold>,
    ) -> Result<Download> {
        let request = request::build(self.config, &self.base, Kind::Down { session })?;
        match self.version {
            HttpVersion::H2 => {
                let (response, _) = Self::mux(conn)?
                    .h2(http_request(&request, &self.base)?, true)
                    .await?;
                Ok(Download::H2Pending(response))
            }
            HttpVersion::H3 => {
                let (mut send, recv) = Self::mux(conn)?
                    .h3(http_request(&request, &self.base)?)
                    .await?;
                send.finish().await.map_err(h3_error)?;
                Ok(Download::H3Pending(recv))
            }
            HttpVersion::H1 => {
                let (down, up) = self.h1_open(&request, false).await?;
                holds.push(Hold::H1Get(std::sync::Mutex::new(up)));
                Ok(Download::H1(Box::new(H1Download::new(down))))
            }
        }
    }

    async fn stream_up(&self, conn: Option<&Usage>, session: &str) -> Result<Upload> {
        let request = request::build(self.config, &self.base, Kind::Up { session })?;
        // Сервер пишет в ответ паддинг: читаем, чтобы не держать окно.
        match self.version {
            HttpVersion::H2 => {
                let (response, send) = Self::mux(conn)?
                    .h2(http_request(&request, &self.base)?, false)
                    .await?;
                tokio::spawn(async move {
                    if let Ok(body) = h2_response(response).await {
                        h2_drain(body).await;
                    }
                });
                Ok(Upload::H2(send))
            }
            HttpVersion::H3 => {
                let (send, recv) = Self::mux(conn)?
                    .h3(http_request(&request, &self.base)?)
                    .await?;
                tokio::spawn(h3_drain(recv));
                Ok(Upload::H3(Box::new(send)))
            }
            HttpVersion::H1 => {
                let (down, up) = self.h1_open(&request, true).await?;
                tokio::spawn(H1Download::new(down).drain());
                Ok(Upload::H1(Box::new(up)))
            }
        }
    }

    async fn stream_one(&self) -> Result<(XhttpReader, XhttpWriter)> {
        let request = request::build(self.config, &self.base, Kind::One)?;
        let conn = self.conn().await?;
        let (download, upload) = match self.version {
            HttpVersion::H2 => {
                let (response, send) = Self::mux(conn.as_ref())?
                    .h2(http_request(&request, &self.base)?, false)
                    .await?;
                (Download::H2Pending(response), Upload::H2(send))
            }
            HttpVersion::H3 => {
                let (send, recv) = Self::mux(conn.as_ref())?
                    .h3(http_request(&request, &self.base)?)
                    .await?;
                (Download::H3Pending(recv), Upload::H3(Box::new(send)))
            }
            HttpVersion::H1 => {
                let (down, up) = self.h1_open(&request, true).await?;
                (
                    Download::H1(Box::new(H1Download::new(down))),
                    Upload::H1(Box::new(up)),
                )
            }
        };
        let hold = Arc::new(conn.map(Hold::Mux).into_iter().collect::<Vec<_>>());
        Ok((
            XhttpReader {
                download: Some(download),
                _hold: Arc::clone(&hold),
            },
            XhttpWriter {
                upload,
                _hold: hold,
            },
        ))
    }

    fn packets(&self, conn: Option<&Usage>, session: String) -> Result<Upload> {
        let poster = match conn {
            Some(usage) => Poster::Mux {
                config: Box::new(self.config.clone()),
                server: self.server.clone(),
                security: self.security.clone(),
                alpn: self.alpn.clone(),
                version: self.version,
                conn: Arc::clone(&usage.0),
                in_flight: Arc::new(tokio::sync::Semaphore::new(POSTS_IN_FLIGHT)),
            },
            None => Poster::H1(H1Uploader {
                server: self.server.clone(),
                security: self.security.clone(),
                alpn: self.alpn.clone(),
                conn: None,
            }),
        };
        Ok(Upload::Packets(spawn_uploader(
            self.config,
            self.base.clone(),
            session,
            poster,
        )))
    }
}

/// Открывает сессию XHTTP к серверу. `alpn` — заданный в настройках TLS.
pub async fn open(
    config: &XhttpConfig,
    server: &TargetAddr,
    security: &Security,
    configured_alpn: &[String],
) -> Result<(XhttpReader, XhttpWriter)> {
    let main = Endpoint::new(config, server, security, configured_alpn);
    let mode = config.resolved_mode(security);
    if mode == Mode::StreamOne {
        if config.download.is_some() {
            return Err(EngineError::Unsupported(
                "xhttp downloadSettings with stream-one".into(),
            ));
        }
        return main.stream_one().await;
    }
    let session = session_id()?;
    let conn = main.conn().await?;
    let mut holds = Vec::new();
    let download = match &config.download {
        Some(settings) => {
            let endpoint = Endpoint::new(
                &settings.xhttp,
                &settings.server,
                &settings.security,
                &settings.alpn,
            );
            let download_conn = endpoint.conn().await?;
            let download = endpoint
                .stream_down(download_conn.as_ref(), &session, &mut holds)
                .await?;
            holds.extend(download_conn.map(Hold::Mux));
            download
        }
        None => {
            main.stream_down(conn.as_ref(), &session, &mut holds)
                .await?
        }
    };
    let upload = match mode {
        Mode::StreamUp => main.stream_up(conn.as_ref(), &session).await?,
        _ => main.packets(conn.as_ref(), session)?,
    };
    holds.extend(conn.map(Hold::Mux));
    let hold = Arc::new(holds);
    Ok((
        XhttpReader {
            download: Some(download),
            _hold: Arc::clone(&hold),
        },
        XhttpWriter {
            upload,
            _hold: hold,
        },
    ))
}

impl XhttpReader {
    pub async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        loop {
            let download = self
                .download
                .take()
                .ok_or(EngineError::Protocol("xhttp: reader is gone"))?;
            match download {
                Download::H2Pending(response) => {
                    self.download = Some(Download::H2(h2_response(response).await?));
                }
                Download::H2(mut body) => {
                    let chunk = body.data().await;
                    let released = match &chunk {
                        Some(Ok(bytes)) => bytes.len(),
                        _ => 0,
                    };
                    let _ = body.flow_control().release_capacity(released);
                    self.download = Some(Download::H2(body));
                    return match chunk {
                        None => Ok(None),
                        Some(Ok(bytes)) if bytes.is_empty() => continue,
                        Some(Ok(bytes)) => Ok(Some(bytes.to_vec())),
                        Some(Err(error)) => Err(h2_error(error)),
                    };
                }
                Download::H3Pending(mut recv) => {
                    h3_response(&mut recv).await?;
                    self.download = Some(Download::H3(recv));
                }
                Download::H3(mut recv) => {
                    let chunk = recv.recv_data().await.map_err(h3_error);
                    self.download = Some(Download::H3(recv));
                    return match chunk? {
                        None => Ok(None),
                        Some(mut data) => {
                            let bytes = data.copy_to_bytes(data.remaining());
                            if bytes.is_empty() {
                                continue;
                            }
                            Ok(Some(bytes.to_vec()))
                        }
                    };
                }
                Download::H1(mut download) => {
                    let chunk = download.read_chunk().await;
                    self.download = Some(Download::H1(download));
                    return chunk;
                }
            }
        }
    }
}

impl XhttpWriter {
    pub async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        if data.is_empty() {
            return Ok(());
        }
        match &mut self.upload {
            Upload::Packets(queue) => queue
                .send(data.to_vec())
                .await
                .map_err(|_| EngineError::Transport("xhttp: upload failed".into())),
            Upload::H2(send) => send_body(send, data, false).await,
            Upload::H3(send) => send
                .send_data(Bytes::copy_from_slice(data))
                .await
                .map_err(h3_error),
            Upload::H1(up) => Box::pin(up.write_all(&h1::chunk(data))).await,
        }
    }
}

// --- Отправка кусками (packet-up) -------------------------------------------

enum Poster {
    Mux {
        config: Box<XhttpConfig>,
        server: TargetAddr,
        security: Security,
        alpn: Vec<String>,
        version: HttpVersion,
        conn: Arc<MuxConn>,
        in_flight: Arc<tokio::sync::Semaphore>,
    },
    H1(H1Uploader),
}

/// Задача отправки: копит записанное, раз в `sc_min_posts_interval_ms`
/// отправляет накопленное (не больше `sc_max_each_post_bytes`) запросом с
/// очередным номером.
fn spawn_uploader(
    config: &XhttpConfig,
    base: Base,
    session: String,
    mut poster: Poster,
) -> mpsc::Sender<Vec<u8>> {
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(UPLOAD_QUEUE);
    let (failed_tx, mut failed) = mpsc::channel::<()>(1);
    let max_post = usize::try_from(config.sc_max_each_post_bytes.pick())
        .unwrap_or(usize::MAX)
        .max(1);
    let interval = config.sc_min_posts_interval_ms;
    let config = config.clone();
    tokio::spawn(async move {
        let mut seq = 0u64;
        let mut last: Option<Instant> = None;
        let mut pending: Vec<u8> = Vec::new();
        loop {
            if pending.is_empty() {
                tokio::select! {
                    _ = failed.recv() => return,
                    next = rx.recv() => match next {
                        Some(data) => pending = data,
                        None => return,
                    },
                }
            }
            if let Some(last) = last {
                let wait = Duration::from_millis(interval.pick());
                tokio::time::sleep_until(last + wait).await;
            }
            // Пока ждали, клиент мог написать ещё: всё в один запрос.
            while pending.len() < max_post {
                match rx.try_recv() {
                    Ok(more) => pending.extend_from_slice(&more),
                    Err(_) => break,
                }
            }
            let rest = if pending.len() > max_post {
                pending.split_off(max_post)
            } else {
                Vec::new()
            };
            let chunk = std::mem::replace(&mut pending, rest);
            last = Some(Instant::now());
            let result = post(
                &mut poster,
                &config,
                &base,
                &session,
                seq,
                &chunk,
                failed_tx.clone(),
            )
            .await;
            seq += 1;
            if let Err(error) = result {
                tracing::debug!(%error, "xhttp: upload failed");
                return;
            }
        }
    });
    tx
}

async fn post(
    poster: &mut Poster,
    config: &XhttpConfig,
    base: &Base,
    session: &str,
    seq: u64,
    chunk: &[u8],
    failed: mpsc::Sender<()>,
) -> Result<()> {
    let request = request::build(
        config,
        base,
        Kind::Packet {
            session,
            seq,
            data: chunk,
        },
    )?;
    let body = request.body.clone().unwrap_or_default();
    match poster {
        Poster::Mux {
            config,
            server,
            security,
            alpn,
            version,
            conn,
            in_flight,
        } => {
            // Соединение исчерпало запросы или срок — следующий кусок идёт
            // по другому, как в Xray.
            if !conn.reusable() {
                let usage = config.mux_conn(server, security, alpn, *version).await?;
                *conn = Arc::clone(&usage.0);
            }
            let permit = Arc::clone(in_flight)
                .acquire_owned()
                .await
                .map_err(|_| EngineError::Protocol("xhttp: uploader closed"))?;
            let http = http_request(&request, base)?;
            if *version == HttpVersion::H3 {
                let (mut send, recv) = conn.h3(http).await?;
                if !body.is_empty() {
                    send.send_data(Bytes::from(body)).await.map_err(h3_error)?;
                }
                send.finish().await.map_err(h3_error)?;
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(error) = h3_drain(recv).await {
                        tracing::debug!(%error, "xhttp: post refused");
                        let _ = failed.try_send(());
                    }
                });
                return Ok(());
            }
            let (response, mut send) = conn.h2(http, body.is_empty()).await?;
            if !body.is_empty() {
                send_body(&mut send, &body, true).await?;
            }
            tokio::spawn(async move {
                let _permit = permit;
                match h2_response(response).await {
                    Ok(body) => h2_drain(body).await,
                    Err(error) => {
                        tracing::debug!(%error, "xhttp: post refused");
                        let _ = failed.try_send(());
                    }
                }
            });
            Ok(())
        }
        Poster::H1(uploader) => {
            let _ = failed;
            uploader.post(&h1::head(&request, base, false, true)).await
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn tls(name: &str) -> Security {
        Security::Tls(crate::tls::TlsConfig::new(name, false, None).unwrap())
    }

    #[test]
    fn versions_and_modes_follow_xray() {
        let none: Vec<String> = Vec::new();
        assert_eq!(http_version(&Security::None, &none), HttpVersion::H1);
        assert_eq!(http_version(&tls("a"), &none), HttpVersion::H2);
        assert_eq!(
            http_version(&tls("a"), &["http/1.1".into()]),
            HttpVersion::H1
        );
        assert_eq!(http_version(&tls("a"), &["h3".into()]), HttpVersion::H3);
        assert_eq!(
            http_version(&tls("a"), &["h2".into(), "http/1.1".into()]),
            HttpVersion::H2
        );
        assert_eq!(alpn(&tls("a"), &none), ["h2"]);
        assert_eq!(alpn(&tls("a"), &["h3".into()]), ["h3"]);
        assert_eq!(alpn(&Security::None, &none), ["http/1.1"]);

        let mut config = XhttpConfig::new("/p", "", Mode::Auto);
        assert_eq!(config.resolved_mode(&tls("a")), Mode::PacketUp);
        let reality = Security::Reality(
            crate::reality::RealityConfig::new("r.example.com", [7; 32], "").unwrap(),
        );
        assert_eq!(config.resolved_mode(&reality), Mode::StreamOne);
        assert_eq!(
            XhttpConfig::new("/p", "", Mode::StreamUp).resolved_mode(&reality),
            Mode::StreamUp
        );
        // Скачивание отдельно — поверх REALITY stream-up.
        config.download = Some(Arc::new(DownloadSettings {
            server: TargetAddr::Domain("dl.example.com".into(), 443),
            security: tls("dl.example.com"),
            alpn: Vec::new(),
            xhttp: XhttpConfig::new("/d", "", Mode::Auto),
        }));
        assert_eq!(config.resolved_mode(&reality), Mode::StreamUp);
        assert!(!format!("{config:?}").contains("dl.example.com"));
    }

    #[test]
    fn urls_and_chunk_sizes() {
        let server = TargetAddr::Domain("1.example.com".into(), 443);
        let config = XhttpConfig::new("xh?ed=1", "", Mode::Auto);
        let base = Base::new(&config, &server, &tls("cdn.example.com"));
        assert_eq!(base.path, "/xh/");
        assert_eq!(base.query, "ed=1");
        assert_eq!(base.authority, "cdn.example.com");

        // Host из настроек важнее имени TLS; без TLS — адрес без порта.
        let config = XhttpConfig::new("/", "front.example.com", Mode::Auto);
        assert_eq!(
            Base::new(&config, &server, &tls("x")).authority,
            "front.example.com"
        );
        let plain = Base::new(
            &XhttpConfig::new("", "", Mode::Auto),
            &server,
            &Security::None,
        );
        assert_eq!(plain.authority, "1.example.com");
        assert_eq!(plain.scheme, "http");
        assert_eq!(plain.path, "/");

        let mut config = XhttpConfig::new("/", "", Mode::PacketUp);
        assert_eq!(config.uplink_chunk_size(), config.sc_max_each_post_bytes);
        config.data_placement = DataPlacement::Header;
        assert_eq!(config.uplink_chunk_size(), Range::new(3000, 4000));
        config.data_placement = DataPlacement::Cookie;
        assert_eq!(config.uplink_chunk_size(), Range::new(2048, 3072));
        config.uplink_chunk_size = Range::new(10, 20);
        assert_eq!(config.uplink_chunk_size(), Range::new(64, 64));
    }

    #[test]
    fn session_ids_are_uuid_v4() {
        let id = session_id().unwrap();
        assert_eq!(id.len(), 36);
        assert_eq!(&id[14..15], "4");
        assert_ne!(id, session_id().unwrap());
    }

    #[test]
    fn ranges_pick_inside() {
        let range = Range::new(16, 32);
        for _ in 0..100 {
            assert!((16..=32).contains(&range.pick()));
        }
        assert_eq!(Range::new(30, 30).pick(), 30);
        assert!(Range::default().is_zero());
    }
}
