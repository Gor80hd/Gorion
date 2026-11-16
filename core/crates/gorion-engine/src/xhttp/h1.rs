//! XHTTP поверх HTTP/1.1: каждый запрос — своё соединение (как
//! `DisableKeepAlives` в Xray), куски packet-up идут по очереди по одному
//! соединению с keep-alive, потоковое тело — `Transfer-Encoding: chunked`.

use super::Base;
use super::request::Request;
use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::stream::{self, Down, Security, Up};

/// Предел заголовков ответа.
const MAX_HEAD: usize = 16 * 1024;

/// Заголовок запроса: у потокового тела — `chunked`, у готового —
/// `Content-Length`, у `GET` — ничего.
///
/// `Connection: close` — у запросов на своём соединении, как у Xray с
/// `DisableKeepAlives`. Без него сервер Go при keep-alive не шлёт заголовок
/// ответа, пока не дочитает тело, а потоковое тело не кончается.
pub fn head(request: &Request, base: &Base, streaming: bool, keep_alive: bool) -> Vec<u8> {
    let mut head = format!(
        "{} {} HTTP/1.1\r\nHost: {}\r\n",
        request.method, request.target, base.authority
    );
    for (name, value) in &request.headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    if !keep_alive {
        head.push_str("Connection: close\r\n");
    }
    if streaming {
        head.push_str("Transfer-Encoding: chunked\r\n");
    } else if let Some(body) = &request.body {
        head.push_str(&format!("Content-Length: {}\r\n", body.len()));
    }
    head.push_str("\r\n");
    let mut out = head.into_bytes();
    if let Some(body) = &request.body {
        out.extend_from_slice(body);
    }
    out
}

/// Кусок потокового тела.
pub fn chunk(data: &[u8]) -> Vec<u8> {
    let mut out = format!("{:x}\r\n", data.len()).into_bytes();
    out.extend_from_slice(data);
    out.extend_from_slice(b"\r\n");
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Body {
    Length(usize),
    Chunked,
    UntilClose,
}

/// Читает заголовок ответа: статус 200 и как читать тело. Остаток буфера
/// после заголовка остаётся в `buf`.
async fn response(down: &mut Down, buf: &mut Vec<u8>) -> Result<Body> {
    let end = loop {
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break end;
        }
        if buf.len() > MAX_HEAD {
            return Err(EngineError::Protocol("xhttp: response head too long"));
        }
        let chunk = Box::pin(down.read_chunk())
            .await?
            .ok_or(EngineError::Protocol("xhttp: closed before response"))?;
        buf.extend_from_slice(&chunk);
    };
    let head = String::from_utf8_lossy(&buf[..end]).into_owned();
    buf.drain(..end + 4);
    let mut lines = head.split("\r\n");
    let status = lines.next().unwrap_or_default();
    let mut parts = status.split(' ');
    if !parts.next().unwrap_or_default().starts_with("HTTP/1.") || parts.next() != Some("200") {
        return Err(EngineError::Transport(format!(
            "xhttp: unexpected status {}",
            status.split(' ').nth(1).unwrap_or_default()
        )));
    }
    let mut body = Body::UntilClose;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let (name, value) = (name.trim(), value.trim());
        if name.eq_ignore_ascii_case("transfer-encoding")
            && value.to_ascii_lowercase().contains("chunked")
        {
            body = Body::Chunked;
        } else if name.eq_ignore_ascii_case("content-length") && body != Body::Chunked {
            body = Body::Length(
                value
                    .parse()
                    .map_err(|_| EngineError::Protocol("xhttp: bad content-length"))?,
            );
        }
    }
    Ok(body)
}

/// Разбор тела `Transfer-Encoding: chunked`.
#[derive(Default)]
pub struct Chunked {
    /// Сколько байт данных текущего куска ещё впереди.
    remaining: usize,
    /// После данных куска ждём CRLF.
    need_crlf: bool,
    pub done: bool,
}

impl Chunked {
    /// Данные из буфера; съеденное удаляется из `buf`.
    pub fn decode(&mut self, buf: &mut Vec<u8>) -> Result<Vec<u8>> {
        let mut out = Vec::new();
        loop {
            if self.done {
                return Ok(out);
            }
            if self.remaining > 0 {
                let take = self.remaining.min(buf.len());
                out.extend(buf.drain(..take));
                self.remaining -= take;
                if self.remaining > 0 {
                    return Ok(out);
                }
                self.need_crlf = true;
            }
            if self.need_crlf {
                if buf.len() < 2 {
                    return Ok(out);
                }
                if &buf[..2] != b"\r\n" {
                    return Err(EngineError::Protocol("xhttp: bad chunk"));
                }
                buf.drain(..2);
                self.need_crlf = false;
            }
            let Some(line_end) = buf.windows(2).position(|w| w == b"\r\n") else {
                if buf.len() > 64 {
                    return Err(EngineError::Protocol("xhttp: bad chunk size"));
                }
                return Ok(out);
            };
            let line = String::from_utf8_lossy(&buf[..line_end]).into_owned();
            let size = line.split(';').next().unwrap_or_default().trim();
            let size = usize::from_str_radix(size, 16)
                .map_err(|_| EngineError::Protocol("xhttp: bad chunk size"))?;
            buf.drain(..line_end + 2);
            if size == 0 {
                // Трейлеры не нужны: поток закончился.
                self.done = true;
                return Ok(out);
            }
            self.remaining = size;
        }
    }
}

/// Тело ответа, которое читается кусками.
pub struct H1Download {
    down: Down,
    buf: Vec<u8>,
    body: Option<Body>,
    chunked: Chunked,
}

impl H1Download {
    pub fn new(down: Down) -> Self {
        Self {
            down,
            buf: Vec::new(),
            body: None,
            chunked: Chunked::default(),
        }
    }

    pub async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        let body = match self.body {
            Some(body) => body,
            None => {
                let body = response(&mut self.down, &mut self.buf).await?;
                self.body = Some(body);
                body
            }
        };
        loop {
            let data = match body {
                Body::Chunked => self.chunked.decode(&mut self.buf)?,
                Body::Length(_) => {
                    let Some(Body::Length(left)) = self.body else {
                        return Ok(None);
                    };
                    if left == 0 {
                        return Ok(None);
                    }
                    let take = left.min(self.buf.len());
                    self.body = Some(Body::Length(left - take));
                    self.buf.drain(..take).collect()
                }
                Body::UntilClose => std::mem::take(&mut self.buf),
            };
            if !data.is_empty() {
                return Ok(Some(data));
            }
            if self.chunked.done {
                return Ok(None);
            }
            match Box::pin(self.down.read_chunk()).await? {
                Some(chunk) => self.buf.extend_from_slice(&chunk),
                None => return Ok(None),
            }
        }
    }

    /// Читает тело до конца и выбрасывает.
    pub async fn drain(mut self) {
        while let Ok(Some(_)) = self.read_chunk().await {}
    }
}

/// Новое соединение (TCP и защита) и запрос на нём.
pub async fn open(
    server: &TargetAddr,
    security: &Security,
    alpn: &[String],
    head: &[u8],
) -> Result<(Down, Up)> {
    let tcp = crate::outbound::dial(server).await?;
    let (down, mut up) = stream::secure(tcp, security, alpn).await?;
    Box::pin(up.write_all(head)).await?;
    Ok((down, up))
}

/// Отправка кусками: запросы по очереди на одном соединении с keep-alive;
/// если оно закрылось — новое.
pub struct H1Uploader {
    pub server: TargetAddr,
    pub security: Security,
    pub alpn: Vec<String>,
    pub conn: Option<(Down, Up)>,
}

impl H1Uploader {
    pub async fn post(&mut self, request: &[u8]) -> Result<()> {
        for attempt in 0..2 {
            let reused = self.conn.is_some();
            let (mut down, mut up) = match self.conn.take() {
                Some(conn) => conn,
                None => {
                    let tcp = crate::outbound::dial(&self.server).await?;
                    stream::secure(tcp, &self.security, &self.alpn).await?
                }
            };
            let sent = async {
                Box::pin(up.write_all(request)).await?;
                let mut buf = Vec::new();
                match response(&mut down, &mut buf).await? {
                    Body::Length(len) => {
                        while buf.len() < len {
                            let more = Box::pin(down.read_chunk())
                                .await?
                                .ok_or(EngineError::Protocol("xhttp: closed in response"))?;
                            buf.extend_from_slice(&more);
                        }
                        Ok(true)
                    }
                    Body::Chunked => {
                        let mut chunked = Chunked::default();
                        loop {
                            chunked.decode(&mut buf)?;
                            if chunked.done {
                                break;
                            }
                            let more = Box::pin(down.read_chunk())
                                .await?
                                .ok_or(EngineError::Protocol("xhttp: closed in response"))?;
                            buf.extend_from_slice(&more);
                        }
                        Ok(true)
                    }
                    // Тело до закрытия: соединение больше не годится.
                    Body::UntilClose => Ok(false),
                }
            }
            .await;
            match sent {
                Ok(keep) => {
                    if keep {
                        self.conn = Some((down, up));
                    }
                    return Ok(());
                }
                // Сохранённое соединение могло закрыться — ещё раз на новом.
                Err(error) if reused && attempt == 0 => {
                    tracing::debug!(%error, "xhttp: upload connection closed, reconnecting");
                }
                Err(error) => return Err(error),
            }
        }
        Err(EngineError::Transport("xhttp: upload failed".into()))
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn chunked_bodies() {
        let mut decoder = Chunked::default();
        let mut buf = b"5\r\nhel".to_vec();
        assert_eq!(decoder.decode(&mut buf).unwrap(), b"hel");
        buf.extend_from_slice(b"lo\r\n3;x=1\r\n wo\r\n0\r\n\r\n");
        assert_eq!(decoder.decode(&mut buf).unwrap(), b"lo wo");
        assert!(decoder.done);
        assert!(Chunked::default().decode(&mut b"zz\r\n".to_vec()).is_err());
        assert_eq!(chunk(b"hello"), b"5\r\nhello\r\n");
        let mut buf = chunk(&[7u8; 300]);
        assert_eq!(Chunked::default().decode(&mut buf).unwrap(), vec![7u8; 300]);
    }
}
