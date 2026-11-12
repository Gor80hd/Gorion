//! Локальный вход: один порт для SOCKS5 и HTTP-прокси (как `mixed` в sing-box).
//! Протокол определяется по первому байту: 0x05 — SOCKS5, иначе HTTP.

use std::io::ErrorKind;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinSet;

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::outbound::Outbound;

const SOCKS_VERSION: u8 = 5;
const SOCKS_NO_AUTH: u8 = 0;
const SOCKS_NO_ACCEPTABLE: u8 = 0xFF;
const SOCKS_CMD_CONNECT: u8 = 1;
const REPLY_SUCCEEDED: u8 = 0;
const REPLY_GENERAL_FAILURE: u8 = 1;
const REPLY_HOST_UNREACHABLE: u8 = 4;
const REPLY_CONNECTION_REFUSED: u8 = 5;
const REPLY_COMMAND_NOT_SUPPORTED: u8 = 7;
/// Предел заголовков HTTP-запроса к прокси.
const MAX_HTTP_HEAD: usize = 16 * 1024;

/// Принимает подключения, пока задачу не отменят. Дочерние задачи живут в
/// `JoinSet` и отменяются вместе с ней.
pub async fn serve(listener: TcpListener, outbound: Arc<Outbound>) {
    let mut tasks = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, peer)) => {
                    let outbound = Arc::clone(&outbound);
                    tasks.spawn(async move {
                        if let Err(error) = handle(stream, &outbound).await {
                            tracing::debug!(%peer, %error, "connection ended with error");
                        }
                    });
                }
                Err(error) => {
                    // Например, закончились дескрипторы: не крутимся вхолостую.
                    tracing::warn!(%error, "accept failed");
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            },
            Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
}

async fn handle(stream: TcpStream, outbound: &Outbound) -> Result<()> {
    stream.set_nodelay(true)?;
    let mut first = [0u8; 1];
    if stream.peek(&mut first).await? == 0 {
        return Ok(());
    }
    if first[0] == SOCKS_VERSION {
        socks5(stream, outbound).await
    } else {
        http(stream, outbound).await
    }
}

async fn socks5(mut client: TcpStream, outbound: &Outbound) -> Result<()> {
    let mut head = [0u8; 2];
    client.read_exact(&mut head).await?;
    let mut methods = vec![0u8; usize::from(head[1])];
    client.read_exact(&mut methods).await?;
    if !methods.contains(&SOCKS_NO_AUTH) {
        client
            .write_all(&[SOCKS_VERSION, SOCKS_NO_ACCEPTABLE])
            .await?;
        return Err(EngineError::Protocol("socks: no acceptable auth method"));
    }
    client.write_all(&[SOCKS_VERSION, SOCKS_NO_AUTH]).await?;

    let mut request = [0u8; 3];
    client.read_exact(&mut request).await?;
    if request[0] != SOCKS_VERSION {
        return Err(EngineError::Protocol("socks: bad version"));
    }
    if request[1] != SOCKS_CMD_CONNECT {
        socks_reply(&mut client, REPLY_COMMAND_NOT_SUPPORTED).await?;
        return Err(EngineError::Protocol("socks: only CONNECT is supported"));
    }
    let target = TargetAddr::read_socks(&mut client).await?;
    match outbound.connect(&target, &[]).await {
        Ok(connection) => {
            socks_reply(&mut client, REPLY_SUCCEEDED).await?;
            let transferred = connection.relay(client).await?;
            tracing::trace!(%target, ?transferred, "socks connection closed");
            Ok(())
        }
        Err(error) => {
            socks_reply(&mut client, socks_failure_code(&error)).await?;
            Err(error)
        }
    }
}

fn socks_failure_code(error: &EngineError) -> u8 {
    match error {
        EngineError::Io(e) if e.kind() == ErrorKind::ConnectionRefused => REPLY_CONNECTION_REFUSED,
        EngineError::Io(e)
            if matches!(
                e.kind(),
                ErrorKind::HostUnreachable | ErrorKind::NetworkUnreachable
            ) =>
        {
            REPLY_HOST_UNREACHABLE
        }
        _ => REPLY_GENERAL_FAILURE,
    }
}

async fn socks_reply(client: &mut TcpStream, code: u8) -> Result<()> {
    // Адрес привязки не используется клиентами — отдаём нули.
    client
        .write_all(&[SOCKS_VERSION, code, 0, 1, 0, 0, 0, 0, 0, 0])
        .await?;
    Ok(())
}

async fn http(mut client: TcpStream, outbound: &Outbound) -> Result<()> {
    let (head, rest) = read_http_head(&mut client).await?;
    let request = match HttpRequest::parse(&head) {
        Ok(request) => request,
        Err(error) => {
            client
                .write_all(
                    b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await?;
            return Err(error);
        }
    };
    let (target, initial) = match &request {
        HttpRequest::Connect { target } => (target.clone(), rest),
        HttpRequest::Forward { target, head } => {
            let mut initial = head.clone().into_bytes();
            initial.extend_from_slice(&rest);
            (target.clone(), initial)
        }
    };
    match outbound.connect(&target, &initial).await {
        Ok(connection) => {
            if matches!(request, HttpRequest::Connect { .. }) {
                client
                    .write_all(b"HTTP/1.1 200 Connection established\r\n\r\n")
                    .await?;
            }
            let transferred = connection.relay(client).await?;
            tracing::trace!(%target, ?transferred, "http connection closed");
            Ok(())
        }
        Err(error) => {
            client
                .write_all(
                    b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await?;
            Err(error)
        }
    }
}

/// Заголовки до пустой строки и всё, что клиент успел прислать после них.
async fn read_http_head(client: &mut TcpStream) -> Result<(String, Vec<u8>)> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 2048];
    loop {
        let n = client.read(&mut chunk).await?;
        if n == 0 {
            return Err(EngineError::Protocol(
                "http: connection closed before headers",
            ));
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let rest = buf.split_off(end + 4);
            let head = String::from_utf8(buf)
                .map_err(|_| EngineError::Protocol("http: headers are not utf-8"))?;
            return Ok((head, rest));
        }
        if buf.len() > MAX_HTTP_HEAD {
            return Err(EngineError::Protocol("http: headers too large"));
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum HttpRequest {
    Connect {
        target: TargetAddr,
    },
    /// Обычный запрос к прокси: переписанный в форму для сервера заголовок.
    Forward {
        target: TargetAddr,
        head: String,
    },
}

/// Заголовки, которые адресованы прокси, а не серверу.
const HOP_BY_HOP: [&str; 4] = [
    "proxy-connection",
    "proxy-authorization",
    "connection",
    "keep-alive",
];

impl HttpRequest {
    fn parse(head: &str) -> Result<Self> {
        let mut lines = head.split("\r\n");
        let request_line = lines
            .next()
            .ok_or(EngineError::Protocol("http: empty request"))?;
        let mut parts = request_line.split(' ');
        let (Some(method), Some(uri), Some(version), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(EngineError::Protocol("http: bad request line"));
        };
        if method.eq_ignore_ascii_case("CONNECT") {
            return Ok(Self::Connect {
                target: TargetAddr::parse_authority(uri, 443)?,
            });
        }
        let rest = uri
            .get(..7)
            .filter(|scheme| scheme.eq_ignore_ascii_case("http://"))
            .map(|_| &uri[7..])
            .ok_or(EngineError::Protocol(
                "http: only absolute http:// URIs are proxied",
            ))?;
        let (authority, path) = match rest.find('/') {
            Some(slash) => (&rest[..slash], &rest[slash..]),
            None => (rest, "/"),
        };
        let target = TargetAddr::parse_authority(authority, 80)?;
        // Один запрос на подключение: следующий может идти к другому серверу.
        let mut out = format!("{method} {path} {version}\r\n");
        for line in lines.filter(|line| !line.is_empty()) {
            let name = line
                .split(':')
                .next()
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase();
            if !HOP_BY_HOP.contains(&name.as_str()) {
                out.push_str(line);
                out.push_str("\r\n");
            }
        }
        out.push_str("Connection: close\r\n\r\n");
        Ok(Self::Forward { target, head: out })
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn parses_connect() {
        let request =
            HttpRequest::parse("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n")
                .unwrap();
        assert_eq!(
            request,
            HttpRequest::Connect {
                target: TargetAddr::Domain("example.com".into(), 443)
            }
        );
    }

    #[test]
    fn rewrites_forward_request() {
        let head = "GET http://Example.com:8080/a?b=1 HTTP/1.1\r\nHost: example.com:8080\r\nProxy-Connection: keep-alive\r\nAccept: */*\r\n\r\n";
        let HttpRequest::Forward { target, head } = HttpRequest::parse(head).unwrap() else {
            panic!("expected forward");
        };
        assert_eq!(target, TargetAddr::Domain("example.com".into(), 8080));
        assert_eq!(
            head,
            "GET /a?b=1 HTTP/1.1\r\nHost: example.com:8080\r\nAccept: */*\r\nConnection: close\r\n\r\n"
        );
    }

    #[test]
    fn rejects_relative_uri() {
        assert!(HttpRequest::parse("GET /index.html HTTP/1.1\r\n\r\n").is_err());
        assert!(HttpRequest::parse("GET https://x/ HTTP/1.1\r\n\r\n").is_err());
    }
}
