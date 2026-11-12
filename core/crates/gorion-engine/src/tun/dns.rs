//! DNS приложений в режиме TUN: запрос на порт 53 любого адреса движок
//! забирает себе (`hijack-dns` в sing-box) и отправляет через выбранный
//! сервер по DNS-over-HTTPS (RFC 8484) — провайдер не видит имён.
//!
//! HTTP/2 и TLS к серверу DNS — `h2` и rustls поверх исходящего протокола,
//! как в URL-тесте: это не формат протокола прокси (ADR-0005).

use std::fmt;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use h2::client::SendRequest;
use tokio::sync::Mutex;
use tokio::task::JoinHandle;

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::selector::Selector;

/// Размер ответа без EDNS (RFC 1035).
const CLASSIC_UDP_SIZE: usize = 512;
const HEADER: usize = 12;
const TYPE_OPT: u16 = 41;
/// Предел ответа сервера DNS.
const MAX_RESPONSE: usize = 64 * 1024;
const QUERY_TIMEOUT: Duration = Duration::from_secs(5);
const MESSAGE_TYPE: &str = "application/dns-message";

/// Сервер DNS-over-HTTPS из настроек.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DohServer {
    pub address: SocketAddr,
    pub server_name: String,
    pub path: String,
}

/// Похоже ли на запрос DNS: заголовок целый, флаг ответа снят, вопрос есть.
pub fn is_query(message: &[u8]) -> bool {
    message.len() >= HEADER
        && message[2] & 0x80 == 0
        && u16::from_be_bytes([message[4], message[5]]) >= 1
}

/// Конец секции вопросов (один вопрос) или `None`.
fn question_end(message: &[u8]) -> Option<usize> {
    let mut at = HEADER;
    loop {
        let len = usize::from(*message.get(at)?);
        if len == 0 {
            at += 1;
            break;
        }
        // Сжатие в вопросе запроса не встречается.
        if len & 0xC0 != 0 {
            return None;
        }
        at += 1 + len;
    }
    let end = at + 4;
    (end <= message.len()).then_some(end)
}

/// Сколько байт ответа примет клиент по UDP: из записи OPT (EDNS) или 512.
pub fn max_udp_size(query: &[u8]) -> usize {
    let counts = |i: usize| u16::from_be_bytes([query[4 + 2 * i], query[5 + 2 * i]]);
    if query.len() < HEADER || counts(0) != 1 || counts(1) != 0 || counts(2) != 0 {
        return CLASSIC_UDP_SIZE;
    }
    let Some(end) = question_end(query) else {
        return CLASSIC_UDP_SIZE;
    };
    // OPT: корневое имя (0), тип 41, класс — размер буфера.
    match query.get(end..end + 5) {
        Some([0, t1, t2, s1, s2]) if u16::from_be_bytes([*t1, *t2]) == TYPE_OPT => {
            usize::from(u16::from_be_bytes([*s1, *s2])).max(CLASSIC_UDP_SIZE)
        }
        _ => CLASSIC_UDP_SIZE,
    }
}

/// Ответ под размер клиента: длинный — только заголовок и вопрос с флагом
/// TC, и клиент повторит запрос по TCP (а TCP идёт через туннель).
pub fn fit_response(query: &[u8], response: Vec<u8>) -> Vec<u8> {
    if response.len() <= max_udp_size(query) {
        return response;
    }
    let Some(end) = question_end(&response) else {
        return response;
    };
    let mut short = response[..end].to_vec();
    short[2] |= 0x02;
    // Один вопрос, ни одной записи.
    short[4..12].copy_from_slice(&[0, 1, 0, 0, 0, 0, 0, 0]);
    short
}

/// Соединение HTTP/2 через сервер, выбранный в момент `generation`.
struct Link {
    generation: u64,
    sender: SendRequest<Bytes>,
    tasks: [JoinHandle<()>; 2],
}

impl Drop for Link {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

pub struct DohClient {
    server: DohServer,
    selector: Arc<Selector>,
    link: Mutex<Option<Link>>,
}

impl fmt::Debug for DohClient {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("DohClient")
            .field("server", &self.server)
            .finish_non_exhaustive()
    }
}

fn h2_error(error: h2::Error) -> EngineError {
    EngineError::Transport(format!("doh: {error}"))
}

impl DohClient {
    pub fn new(server: DohServer, selector: Arc<Selector>) -> Self {
        Self {
            server,
            selector,
            link: Mutex::new(None),
        }
    }

    /// Готовое соединение: прежнее, если сервер не меняли и оно живо.
    async fn sender(&self) -> Result<(u64, SendRequest<Bytes>)> {
        let mut slot = self.link.lock().await;
        let generation = self.selector.generation();
        if let Some(link) = slot.as_ref()
            && link.generation == generation
            && let Ok(ready) = link.sender.clone().ready().await
        {
            return Ok((generation, ready));
        }
        *slot = None;
        let outbound = self.selector.current();
        let connection = outbound
            .connect(&TargetAddr::Ip(self.server.address), &[])
            .await?;
        let (stream, relay) = crate::urltest::local_stream(connection).await?;
        let name = rustls::pki_types::ServerName::try_from(self.server.server_name.clone())
            .map_err(|_| EngineError::Protocol("doh: bad server name"))?;
        let tls = tokio_rustls::TlsConnector::from(crate::urltest::tls_config(&[b"h2"]))
            .connect(name, stream)
            .await;
        let tls = match tls {
            Ok(tls) => tls,
            Err(error) => {
                relay.abort();
                return Err(error.into());
            }
        };
        let (sender, connection) = match h2::client::handshake(tls).await {
            Ok(parts) => parts,
            Err(error) => {
                relay.abort();
                return Err(h2_error(error));
            }
        };
        let driver = tokio::spawn(async move {
            if let Err(error) = connection.await {
                tracing::debug!(%error, "doh: connection closed");
            }
        });
        // Сбой ниже снимет обе задачи вместе с `link`.
        let link = Link {
            generation,
            sender: sender.clone(),
            tasks: [relay, driver],
        };
        let ready = sender.ready().await.map_err(h2_error)?;
        *slot = Some(link);
        Ok((generation, ready))
    }

    /// Ответ на запрос DNS (сообщение целиком, с исходным ID).
    pub async fn exchange(&self, query: &[u8]) -> Result<Vec<u8>> {
        if !is_query(query) {
            return Err(EngineError::Protocol("doh: not a query"));
        }
        match tokio::time::timeout(QUERY_TIMEOUT, self.exchange_inner(query)).await {
            Ok(result) => result,
            Err(_) => Err(std::io::Error::from(std::io::ErrorKind::TimedOut).into()),
        }
    }

    async fn exchange_inner(&self, query: &[u8]) -> Result<Vec<u8>> {
        let (generation, sender) = self.sender().await?;
        let result = self.request(sender, query).await;
        if result.is_err() {
            // Сломанное соединение не держим: следующий запрос откроет новое.
            let mut slot = self.link.lock().await;
            if slot.as_ref().is_some_and(|l| l.generation == generation) {
                *slot = None;
            }
        }
        result
    }

    async fn request(&self, mut sender: SendRequest<Bytes>, query: &[u8]) -> Result<Vec<u8>> {
        // RFC 8484: ID в запросе — ноль (лучше кэшируется), ответу вернём свой.
        let mut body = query.to_vec();
        body[0] = 0;
        body[1] = 0;
        let request = http::Request::builder()
            .method(http::Method::POST)
            .uri(format!(
                "https://{}{}",
                self.server.server_name, self.server.path
            ))
            .header("content-type", MESSAGE_TYPE)
            .header("accept", MESSAGE_TYPE)
            .header("content-length", body.len())
            .body(())
            .map_err(|_| EngineError::Protocol("doh: bad request"))?;
        let (response, mut send) = sender.send_request(request, false).map_err(h2_error)?;
        send.send_data(Bytes::from(body), true).map_err(h2_error)?;
        let response = response.await.map_err(h2_error)?;
        if response.status() != http::StatusCode::OK {
            return Err(EngineError::Transport(format!(
                "doh: status {}",
                response.status()
            )));
        }
        let mut body = response.into_body();
        let mut answer = Vec::new();
        while let Some(chunk) = body.data().await {
            let chunk = chunk.map_err(h2_error)?;
            let _ = body.flow_control().release_capacity(chunk.len());
            answer.extend_from_slice(&chunk);
            if answer.len() > MAX_RESPONSE {
                return Err(EngineError::Protocol("doh: response too large"));
            }
        }
        if answer.len() < HEADER {
            return Err(EngineError::Protocol("doh: short response"));
        }
        answer[0] = query[0];
        answer[1] = query[1];
        Ok(answer)
    }
}

#[cfg(test)]
pub(crate) mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    /// Запрос A для имени; `edns` — размер буфера в записи OPT.
    pub(crate) fn query(name: &str, edns: Option<u16>) -> Vec<u8> {
        let mut q = vec![0x12, 0x34, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
        for label in name.split('.') {
            q.push(label.len() as u8);
            q.extend_from_slice(label.as_bytes());
        }
        q.extend_from_slice(&[0, 0, 1, 0, 1]);
        if let Some(size) = edns {
            q[11] = 1;
            q.extend_from_slice(&[0, 0, 41]);
            q.extend_from_slice(&size.to_be_bytes());
            q.extend_from_slice(&[0, 0, 0, 0, 0, 0]);
        }
        q
    }

    #[test]
    fn recognises_queries_and_buffer_size() {
        let plain = query("example.com", None);
        assert!(is_query(&plain));
        assert_eq!(max_udp_size(&plain), 512);
        assert_eq!(max_udp_size(&query("example.com", Some(4096))), 4096);
        assert_eq!(max_udp_size(&query("example.com", Some(100))), 512);
        let mut answer = plain.clone();
        answer[2] |= 0x80;
        assert!(!is_query(&answer));
        assert!(!is_query(&plain[..11]));
    }

    #[test]
    fn long_answer_is_truncated_to_question() {
        let q = query("example.com", None);
        let mut response = q.clone();
        response[2] = 0x81;
        response[7] = 40; // 40 ответов
        response.extend_from_slice(&[0xAB; 700]);
        let short = fit_response(&q, response);
        assert_eq!(short.len(), q.len());
        assert_eq!(short[2] & 0x02, 0x02, "TC");
        assert_eq!(&short[4..12], &[0, 1, 0, 0, 0, 0, 0, 0]);
        assert_eq!(&short[12..], &q[12..]);
        // Влезающий ответ не трогаем.
        let small = q.clone();
        assert_eq!(fit_response(&q, small.clone()), small);
    }
}
