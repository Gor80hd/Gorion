//! Как выглядит каждый запрос XHTTP: метод, путь, заголовки, cookie, тело.
//! Эталон: Xray `config.go` (`FillStreamRequest`, `FillPacketRequest`,
//! `ApplyMetaToRequest`), `xpadding.go`, `common/utils/browser.go`.
//!
//! Порядок как в Xray: заголовки по умолчанию → данные куска (тело,
//! заголовки или cookie) → паддинг → сессия и номер → `Content-Type`.

use std::time::{SystemTime, UNIX_EPOCH};

use super::{Base, DataPlacement, PaddingMethod, PaddingPlacement, Placement, XhttpConfig};
use crate::error::Result;
use crate::tls::hello::random_bytes;

const BASE62: &[u8] = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
/// Длины кодов Хаффмана HPACK (RFC 7541, приложение B) для символов BASE62.
const HUFFMAN_BITS: [u8; 62] = [
    5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
    7, 8, 7, 8, 5, 6, 5, 6, 5, 6, 6, 6, 5, 7, 7, 6, 6, 6, 5, 6, 7, 6, 5, 5, 6, 7, 7, 7, 7, 7,
];
/// Допуск длины паддинга tokenish, байт после сжатия.
const TOKENISH_TOLERANCE: i64 = 2;

/// Какой запрос строится.
pub enum Kind<'a> {
    /// `GET` скачивания (stream-down).
    Down { session: &'a str },
    /// Потоковая отправка (stream-up).
    Up { session: &'a str },
    /// Один запрос в обе стороны (stream-one).
    One,
    /// Кусок отправки (packet-up).
    Packet {
        session: &'a str,
        seq: u64,
        data: &'a [u8],
    },
}

/// Готовый запрос: путь с запросом, заголовки (без `Host`), тело куска.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Request {
    pub method: String,
    pub target: String,
    pub headers: Vec<(String, String)>,
    /// Тело куска packet-up; у потоковых запросов тело идёт отдельно.
    pub body: Option<Vec<u8>>,
}

impl Request {
    pub fn url(&self, base: &Base) -> String {
        format!("{}://{}{}", base.scheme, base.authority, self.target)
    }
}

/// Заголовки как `http.Header` в Go: `set` заменяет одноимённые.
#[derive(Default)]
struct Headers(Vec<(String, String)>);

impl Headers {
    fn get(&self, name: &str) -> Option<&str> {
        self.0
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    fn set(&mut self, name: &str, value: impl Into<String>) {
        self.0.retain(|(n, _)| !n.eq_ignore_ascii_case(name));
        self.0.push((name.to_owned(), value.into()));
    }

    fn set_default(&mut self, name: &str, value: &str) {
        if self.get(name).is_none_or(str::is_empty) {
            self.set(name, value);
        }
    }

    fn remove(&mut self, name: &str) {
        self.0.retain(|(n, _)| !n.eq_ignore_ascii_case(name));
    }
}

/// Запрос URL: пары до разбора и обратно, как `url.Values`.
struct Query {
    raw: String,
    pairs: Option<Vec<(String, String)>>,
}

impl Query {
    fn new(raw: &str) -> Self {
        Self {
            raw: raw.to_owned(),
            pairs: None,
        }
    }

    /// `q.Set(key, value)` и `RawQuery = q.Encode()`: ключи по алфавиту.
    fn set(&mut self, key: &str, value: &str) {
        let raw = &self.raw;
        let pairs = self.pairs.get_or_insert_with(|| parse_query(raw));
        pairs.retain(|(k, _)| k != key);
        pairs.push((key.to_owned(), value.to_owned()));
        pairs.sort_by(|a, b| a.0.cmp(&b.0));
    }

    fn encode(&self) -> String {
        match &self.pairs {
            None => self.raw.clone(),
            Some(pairs) => pairs
                .iter()
                .map(|(k, v)| format!("{}={}", query_escape(k), query_escape(v)))
                .collect::<Vec<_>>()
                .join("&"),
        }
    }
}

fn parse_query(raw: &str) -> Vec<(String, String)> {
    raw.split('&')
        .filter(|part| !part.is_empty())
        .map(|part| {
            let (k, v) = part.split_once('=').unwrap_or((part, ""));
            (query_unescape(k), query_unescape(v))
        })
        .collect()
}

fn query_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(char::from(byte));
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn query_unescape(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => out.push(b' '),
            b'%' if i + 2 < bytes.len() => {
                let hex = |b: u8| char::from(b).to_digit(16);
                match (hex(bytes[i + 1]), hex(bytes[i + 2])) {
                    (Some(high), Some(low)) => {
                        out.push((high * 16 + low) as u8);
                        i += 2;
                    }
                    _ => out.push(b'%'),
                }
            }
            byte => out.push(byte),
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// `appendToPath` в Xray.
fn append_to_path(path: &mut String, value: &str) {
    if !path.ends_with('/') {
        path.push('/');
    }
    path.push_str(value);
}

/// Base64 URL без `=` (`base64.RawURLEncoding`).
fn base64_url(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    for chunk in data.chunks(3) {
        let b = [
            chunk[0],
            chunk.get(1).copied().unwrap_or(0),
            chunk.get(2).copied().unwrap_or(0),
        ];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        let chars = chunk.len() + 1;
        for i in 0..chars {
            out.push(char::from(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize]));
        }
    }
    out
}

// --- Паддинг ----------------------------------------------------------------

/// Случайная строка из BASE62 (без перекоса: как `randStringFromCharset`).
fn random_base62(len: usize) -> Result<String> {
    let limit = 256 - (256 % BASE62.len());
    let mut out = String::with_capacity(len);
    while out.len() < len {
        for byte in random_bytes::<64>()? {
            if usize::from(byte) >= limit {
                continue;
            }
            out.push(char::from(BASE62[usize::from(byte) % BASE62.len()]));
            if out.len() == len {
                break;
            }
        }
    }
    Ok(out)
}

/// Длина строки после сжатия Хаффманом HPACK, байт.
fn huffman_len(text: &str) -> i64 {
    let bits: i64 = text
        .bytes()
        .map(|b| {
            BASE62
                .iter()
                .position(|c| *c == b)
                .map_or(8, |i| i64::from(HUFFMAN_BITS[i]))
        })
        .sum();
    (bits + 7) / 8
}

/// Паддинг «tokenish»: похож на токен и после сжатия HPACK занимает
/// примерно `target` байт (`GenerateTokenishPaddingBase62`).
fn tokenish(target: usize) -> Result<String> {
    let target = i64::try_from(target).unwrap_or(i64::MAX);
    let start = ((target as f64) / 0.8).ceil().max(1.0) as usize;
    let mut text = random_base62(start)?;
    let mut adjust = 'X';
    for _ in 0..150 {
        let diff = huffman_len(&text) - target;
        if diff.abs() <= TOKENISH_TOLERANCE {
            break;
        }
        if diff < 0 {
            text.push(adjust);
            adjust = if adjust == 'X' { 'Z' } else { 'X' };
        } else {
            if text.len() <= 1 {
                break;
            }
            text.pop();
        }
    }
    Ok(text)
}

fn padding_value(method: PaddingMethod, len: usize) -> Result<String> {
    if len == 0 {
        return Ok(String::new());
    }
    match method {
        PaddingMethod::RepeatX => Ok("X".repeat(len)),
        PaddingMethod::Tokenish => tokenish(len),
    }
}

// --- Браузерные заголовки -----------------------------------------------------

/// Версия Chrome по дате: Xray начинает со 144 (13.01.2026) и прибавляет
/// по версии каждые 25–45 дней; здесь — в среднем раз в 35 дней.
fn chrome_version() -> u64 {
    const CHROME_144: u64 = 1_768_262_400;
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(CHROME_144, |d| d.as_secs());
    144 + now.saturating_sub(CHROME_144) / (35 * 86_400)
}

/// `Sec-CH-UA` с GREASE, как `getGreasedChUa`.
fn chrome_client_hints(version: u64, fork: &str) -> String {
    const GREASE: [&str; 11] = [" ", "(", ":", "-", ".", "/", ")", ";", "=", "?", "_"];
    const GREASE_VERSION: [&str; 3] = ["8", "99", "24"];
    const SHUFFLE: [[usize; 3]; 6] = [
        [0, 1, 2],
        [0, 2, 1],
        [1, 0, 2],
        [1, 2, 0],
        [2, 0, 1],
        [2, 1, 0],
    ];
    let seed = usize::try_from(version).unwrap_or(0);
    let brands = [
        format!(
            "\"Not{}A{}Brand\";v=\"{}\"",
            GREASE[seed % GREASE.len()],
            GREASE[(seed + 1) % GREASE.len()],
            GREASE_VERSION[seed % GREASE_VERSION.len()]
        ),
        format!("\"Chromium\";v=\"{version}\""),
        format!("\"{fork}\";v=\"{version}\""),
    ];
    let mut shuffled = vec![String::new(); 3];
    for (i, e) in SHUFFLE[seed % SHUFFLE.len()].iter().enumerate() {
        shuffled[*e] = brands[i].clone();
    }
    shuffled.join(", ")
}

/// `TryDefaultHeadersWith(header, "fetch")`: без своего User-Agent (или с
/// `chrome`, `firefox`, `edge`, `golang`) — заголовки браузера.
fn browser_headers(headers: &mut Headers) {
    let browser = match headers.get("User-Agent") {
        None => "chrome",
        Some(ua) if ["chrome", "firefox", "edge", "golang"].contains(&ua) => ua,
        Some(_) => return,
    }
    .to_owned();
    let version = chrome_version();
    let chrome_ua = format!(
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/{version}.0.0.0 Safari/537.36"
    );
    match browser.as_str() {
        "chrome" | "edge" => {
            let (ua, fork) = if browser == "edge" {
                (format!("{chrome_ua}Edg/{version}.0.0.0"), "Microsoft Edge")
            } else {
                (chrome_ua, "Google Chrome")
            };
            headers.set("Sec-CH-UA", chrome_client_hints(version, fork));
            headers.set("Sec-CH-UA-Mobile", "?0");
            headers.set("Sec-CH-UA-Platform", "\"Windows\"");
            headers.set("DNT", "1");
            headers.set("User-Agent", ua);
            headers.set("Accept-Language", "en-US,en;q=0.9");
        }
        "firefox" => {
            headers.set(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0",
            );
            headers.set("DNT", "1");
            headers.set("Accept-Language", "en-US,en;q=0.5");
        }
        _ => {
            headers.remove("User-Agent");
            return;
        }
    }
    headers.set("Sec-Fetch-Mode", "cors");
    headers.set("Sec-Fetch-Dest", "empty");
    headers.set("Sec-Fetch-Site", "same-origin");
    headers.set_default(
        "Priority",
        if browser == "firefox" {
            "u=4"
        } else {
            "u=1, i"
        },
    );
    headers.set_default("Cache-Control", "no-cache");
    headers.set_default("Pragma", "no-cache");
    headers.set_default("Accept", "*/*");
}

// --- Сборка -----------------------------------------------------------------

pub fn build(config: &XhttpConfig, base: &Base, kind: Kind<'_>) -> Result<Request> {
    let mut headers = Headers(
        config
            .headers
            .iter()
            .filter(|(name, _)| !name.eq_ignore_ascii_case("host"))
            .cloned()
            .collect(),
    );
    browser_headers(&mut headers);
    let mut cookies: Vec<(String, String)> = Vec::new();
    let mut path = base.path.clone();
    let mut query = Query::new(&base.query);

    // Потоковое тело есть у stream-up и stream-one (а не у GET и кусков).
    let streaming = matches!(kind, Kind::Up { .. } | Kind::One);
    let (method, session, seq, body) = match kind {
        Kind::Down { session } => ("GET".to_owned(), Some(session), None, None),
        Kind::Up { session } => (config.uplink_method.clone(), Some(session), None, None),
        Kind::One => (config.uplink_method.clone(), None, None, None),
        Kind::Packet { session, seq, data } => {
            let body = match config.data_placement {
                DataPlacement::Body => Some(data.to_vec()),
                DataPlacement::Header | DataPlacement::Cookie => {
                    let encoded = base64_url(data);
                    let mut rest = encoded.as_str();
                    let mut index = 0;
                    while !rest.is_empty() {
                        let size = usize::try_from(config.uplink_chunk_size().pick())
                            .unwrap_or(usize::MAX)
                            .clamp(1, rest.len());
                        let (chunk, tail) = rest.split_at(size);
                        if config.data_placement == DataPlacement::Header {
                            headers.set(&format!("{}-{index}", config.data_key), chunk);
                        } else {
                            cookies.push((format!("{}_{index}", config.data_key), chunk.into()));
                        }
                        rest = tail;
                        index += 1;
                    }
                    // Тело пустое, но длина известна — `Content-Length: 0`.
                    Some(Vec::new())
                }
            };
            (config.uplink_method.clone(), Some(session), Some(seq), body)
        }
    };

    // Паддинг: адрес до сессии и номера, как `request.URL.String()` в Xray.
    let len = usize::try_from(config.x_padding_bytes.pick()).unwrap_or(0);
    let raw_url = |query: &str| {
        let mut url = format!("{}://{}{}", base.scheme, base.authority, path);
        if !query.is_empty() {
            url.push('?');
            url.push_str(query);
        }
        url
    };
    match &config.padding_obfs {
        None => {
            let value = padding_value(PaddingMethod::RepeatX, len)?;
            headers.set("Referer", raw_url(&format!("x_padding={value}")));
        }
        Some(obfs) => {
            let value = padding_value(obfs.method, len)?;
            match obfs.placement {
                PaddingPlacement::Header => headers.set(&obfs.header, value),
                PaddingPlacement::QueryInHeader => {
                    headers.set(&obfs.header, raw_url(&format!("{}={value}", obfs.key)));
                }
                PaddingPlacement::Cookie if !value.is_empty() => {
                    cookies.push((obfs.key.clone(), value));
                }
                PaddingPlacement::Query if !value.is_empty() => query.set(&obfs.key, &value),
                _ => {}
            }
        }
    }

    // Сессия и номер.
    let seq = seq.map(|s| s.to_string());
    let meta = [
        (session, config.session_placement, &config.session_key),
        (seq.as_deref(), config.seq_placement, &config.seq_key),
    ];
    for (value, placement, key) in meta {
        let Some(value) = value.filter(|v| !v.is_empty()) else {
            continue;
        };
        match placement {
            Placement::Path => append_to_path(&mut path, value),
            Placement::Query => query.set(key, value),
            Placement::Header => headers.set(key, value),
            Placement::Cookie => cookies.push((key.to_string(), value.to_owned())),
        }
    }

    if streaming && !config.no_grpc_header {
        headers.set("Content-Type", "application/grpc");
    }
    if !cookies.is_empty() {
        let line = cookies
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("; ");
        headers.set("Cookie", line);
    }
    let query = query.encode();
    let mut target = path;
    if !query.is_empty() {
        target.push('?');
        target.push_str(&query);
    }
    Ok(Request {
        method,
        target,
        headers: headers.0,
        body,
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::address::TargetAddr;
    use crate::stream::Security;
    use crate::xhttp::{Mode, PaddingObfs};

    fn base(config: &XhttpConfig) -> Base {
        let tls = crate::tls::TlsConfig::new("cdn.example.com", false, None).unwrap();
        Base::new(
            config,
            &TargetAddr::Domain("1.example.com".into(), 443),
            &Security::Tls(tls),
        )
    }

    fn header<'a>(request: &'a Request, name: &str) -> Option<&'a str> {
        request
            .headers
            .iter()
            .find(|(n, _)| n.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }

    #[test]
    fn default_requests_look_like_xray() {
        let config = XhttpConfig::new("/xh?ed=1", "", Mode::PacketUp);
        let base = base(&config);
        let get = build(&config, &base, Kind::Down { session: "sid" }).unwrap();
        assert_eq!(get.method, "GET");
        assert_eq!(get.target, "/xh/sid?ed=1");
        assert_eq!(get.body, None);
        let referer = header(&get, "Referer").unwrap();
        let padding = referer
            .strip_prefix("https://cdn.example.com/xh/?x_padding=")
            .unwrap();
        assert!((100..=1000).contains(&padding.len()));
        assert!(padding.bytes().all(|b| b == b'X'));
        assert!(header(&get, "Content-Type").is_none());
        assert!(header(&get, "User-Agent").unwrap().contains("Chrome/"));
        assert_eq!(header(&get, "Sec-Fetch-Mode"), Some("cors"));
        assert_eq!(header(&get, "Accept"), Some("*/*"));

        let post = build(
            &config,
            &base,
            Kind::Packet {
                session: "sid",
                seq: 3,
                data: b"abc",
            },
        )
        .unwrap();
        assert_eq!(
            (post.method.as_str(), post.target.as_str()),
            ("POST", "/xh/sid/3?ed=1")
        );
        assert_eq!(post.body.as_deref(), Some(&b"abc"[..]));
        assert!(header(&post, "Content-Type").is_none());

        let up = build(&config, &base, Kind::Up { session: "sid" }).unwrap();
        assert_eq!(header(&up, "Content-Type"), Some("application/grpc"));
        let one = build(&config, &base, Kind::One).unwrap();
        assert_eq!(one.target, "/xh/?ed=1");
        assert_eq!(header(&one, "Content-Type"), Some("application/grpc"));

        // Свой User-Agent — без браузерных заголовков.
        let mut custom = config.clone();
        custom.headers = vec![("User-Agent".into(), "UA".into())];
        let get = build(&custom, &base, Kind::Down { session: "s" }).unwrap();
        assert_eq!(header(&get, "User-Agent"), Some("UA"));
        assert!(header(&get, "Sec-Fetch-Mode").is_none());
    }

    #[test]
    fn placements_and_obfuscated_padding() {
        let mut config = XhttpConfig::new("/p?b=2", "", Mode::PacketUp);
        config.uplink_method = "PUT".into();
        config.session_placement = Placement::Query;
        config.session_key = "x_session".into();
        config.seq_placement = Placement::Header;
        config.seq_key = "X-Seq".into();
        config.data_placement = DataPlacement::Header;
        config.data_key = "X-Data".into();
        // Меньше 64 Xray не режет: куски по 64 знака.
        config.uplink_chunk_size = super::super::Range::new(4, 4);
        config.padding_obfs = Some(PaddingObfs {
            placement: PaddingPlacement::Cookie,
            key: "x_padding".into(),
            header: "X-Padding".into(),
            method: PaddingMethod::Tokenish,
        });
        let base = base(&config);
        let data = [0xffu8; 100];
        let post = build(
            &config,
            &base,
            Kind::Packet {
                session: "s1",
                seq: 7,
                data: &data,
            },
        )
        .unwrap();
        assert_eq!(post.method, "PUT");
        // Сессия в запросе: ключи по алфавиту, как `q.Encode()`.
        assert_eq!(post.target, "/p/?b=2&x_session=s1");
        assert_eq!(header(&post, "X-Seq"), Some("7"));
        // 100 байт — 134 знака base64url: 64 + 64 + 6.
        let encoded = base64_url(&data);
        assert_eq!(encoded.len(), 134);
        assert_eq!(header(&post, "X-Data-0"), Some(&encoded[..64]));
        assert_eq!(header(&post, "X-Data-1"), Some(&encoded[64..128]));
        assert_eq!(header(&post, "X-Data-2"), Some(&encoded[128..]));
        assert!(header(&post, "X-Data-3").is_none());
        assert_eq!(post.body.as_deref(), Some(&[][..]));
        let cookie = header(&post, "Cookie").unwrap();
        let padding = cookie.strip_prefix("x_padding=").unwrap();
        let squeezed = huffman_len(padding);
        assert!((98..=1002).contains(&squeezed), "{squeezed}");
        assert!(header(&post, "Referer").is_none());

        // Данные в cookie, паддинг в заголовке и в запросе.
        config.data_placement = DataPlacement::Cookie;
        config.data_key = "x_data".into();
        config.session_placement = Placement::Cookie;
        let mut obfs = config.padding_obfs.clone().unwrap();
        obfs.placement = PaddingPlacement::Header;
        obfs.method = PaddingMethod::RepeatX;
        config.padding_obfs = Some(obfs.clone());
        let post = build(
            &config,
            &base,
            Kind::Packet {
                session: "s1",
                seq: 0,
                data: b"hi",
            },
        )
        .unwrap();
        assert_eq!(header(&post, "Cookie"), Some("x_data_0=aGk; x_session=s1"));
        assert!(
            header(&post, "X-Padding")
                .unwrap()
                .bytes()
                .all(|b| b == b'X')
        );
        obfs.placement = PaddingPlacement::Query;
        config.padding_obfs = Some(obfs);
        let get = build(&config, &base, Kind::Down { session: "s1" }).unwrap();
        assert!(get.target.starts_with("/p/?b=2&x_padding=XXX"));
    }

    #[test]
    fn helpers_match_go() {
        assert_eq!(base64_url(b""), "");
        assert_eq!(base64_url(b"f"), "Zg");
        assert_eq!(base64_url(b"fo"), "Zm8");
        assert_eq!(base64_url(b"foo"), "Zm9v");
        assert_eq!(base64_url(&[0xfb, 0xff]), "-_8");
        assert_eq!(query_escape("a b&c=é"), "a+b%26c%3D%C3%A9");
        assert_eq!(query_unescape("a+b%26c%3d%C3%A9"), "a b&c=é");
        let mut query = Query::new("z=1&a=%2F");
        assert_eq!(query.encode(), "z=1&a=%2F");
        query.set("m", "x");
        assert_eq!(query.encode(), "a=%2F&m=x&z=1");
        // «0» — 5 бит, «X» — 8: две «0» и «X» — 18 бит, 3 байта.
        assert_eq!(huffman_len("00X"), 3);
        for target in [1usize, 50, 700] {
            let text = tokenish(target).unwrap();
            assert!((huffman_len(&text) - target as i64).abs() <= 2, "{target}");
        }
        let hints = chrome_client_hints(144, "Google Chrome");
        assert!(hints.contains("\"Chromium\";v=\"144\""));
        assert!(hints.contains("\"Google Chrome\";v=\"144\""));
        assert!(chrome_version() >= 144);
    }
}
