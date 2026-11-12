//! URL-тест сервера: настоящий HTTP(S)-запрос через исходящий протокол,
//! время до строки статуса ответа. Как URLTest в sing-box — сквозная
//! проверка, а не TCP-коннект (правило 1).

use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::outbound::Outbound;
use crate::selector::Traffic;

/// Предел строки статуса и заголовков, которые читаем.
const MAX_STATUS: usize = 8 * 1024;

#[derive(Debug, PartialEq, Eq)]
struct TestUrl {
    https: bool,
    host: String,
    port: u16,
    path: String,
}

fn parse_url(url: &str) -> Result<TestUrl> {
    let bad = || EngineError::Protocol("urltest: bad url");
    let (https, rest) = if let Some(rest) = url.strip_prefix("https://") {
        (true, rest)
    } else if let Some(rest) = url.strip_prefix("http://") {
        (false, rest)
    } else {
        return Err(bad());
    };
    let (authority, path) = match rest.find('/') {
        Some(index) => (&rest[..index], &rest[index..]),
        None => (rest, "/"),
    };
    let target =
        TargetAddr::parse_authority(authority, if https { 443 } else { 80 }).map_err(|_| bad())?;
    let host = match &target {
        TargetAddr::Domain(host, _) => host.clone(),
        TargetAddr::Ip(addr) => addr.ip().to_string(),
    };
    Ok(TestUrl {
        https,
        host,
        port: target.port(),
        path: path.to_owned(),
    })
}

fn tls_config() -> Arc<rustls::ClientConfig> {
    static CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();
    Arc::clone(CONFIG.get_or_init(|| {
        let roots = rustls::RootCertStore {
            roots: webpki_roots::TLS_SERVER_ROOTS.to_vec(),
        };
        let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
        let config = rustls::ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .map(|builder| builder.with_root_certificates(roots).with_no_client_auth());
        match config {
            Ok(config) => Arc::new(config),
            // Набор по умолчанию у провайдера всегда есть; на всякий случай —
            // пустой конфиг, который просто не пройдёт рукопожатие.
            Err(_) => Arc::new(
                rustls::ClientConfig::builder()
                    .with_root_certificates(rustls::RootCertStore::empty())
                    .with_no_client_auth(),
            ),
        }
    }))
}

async fn request<S: AsyncRead + AsyncWrite + Unpin>(mut stream: S, url: &TestUrl) -> Result<()> {
    let head = format!(
        "GET {} HTTP/1.1\r\nHost: {}\r\nUser-Agent: Mozilla/5.0\r\nAccept: */*\r\nConnection: close\r\n\r\n",
        url.path, url.host
    );
    stream.write_all(head.as_bytes()).await?;
    let mut response = Vec::with_capacity(256);
    let mut chunk = [0u8; 1024];
    loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Err(EngineError::Protocol("urltest: no response"));
        }
        response.extend_from_slice(&chunk[..n]);
        if response.windows(2).any(|w| w == b"\r\n") {
            break;
        }
        if response.len() > MAX_STATUS {
            return Err(EngineError::Protocol("urltest: response too long"));
        }
    }
    if response.starts_with(b"HTTP/1.") {
        Ok(())
    } else {
        Err(EngineError::Protocol("urltest: not an HTTP response"))
    }
}

/// Задержка в миллисекундах (не меньше 1). Ошибка — сервер не ответил.
pub async fn delay(outbound: &Outbound, url: &str, timeout: Duration) -> Result<u64> {
    let url = parse_url(url)?;
    let started = Instant::now();
    let attempt = async {
        let target = TargetAddr::from_host(&url.host, url.port)?;
        let connection = outbound.connect(&target, &[]).await?;
        // Протокол отдаёт поток через пару сокетов на петле: так запрос и
        // TLS работают поверх него без особого кода.
        let listener = TcpListener::bind("127.0.0.1:0").await?;
        let client = TcpStream::connect(listener.local_addr()?).await?;
        let (proxy_side, _) = listener.accept().await?;
        let relay = tokio::spawn(async move {
            let _ = connection.relay(proxy_side, &Traffic::default()).await;
        });
        let result = if url.https {
            let name = rustls::pki_types::ServerName::try_from(url.host.clone())
                .map_err(|_| EngineError::Protocol("urltest: bad host"))?;
            let tls = tokio_rustls::TlsConnector::from(tls_config())
                .connect(name, client)
                .await?;
            request(tls, &url).await
        } else {
            request(client, &url).await
        };
        relay.abort();
        result
    };
    match tokio::time::timeout(timeout, attempt).await {
        Ok(Ok(())) => Ok((started.elapsed().as_millis() as u64).max(1)),
        Ok(Err(error)) => Err(error),
        Err(_) => Err(std::io::Error::from(std::io::ErrorKind::TimedOut).into()),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn parses_test_urls() {
        assert_eq!(
            parse_url("https://www.gstatic.com/generate_204").unwrap(),
            TestUrl {
                https: true,
                host: "www.gstatic.com".into(),
                port: 443,
                path: "/generate_204".into()
            }
        );
        let plain = parse_url("http://127.0.0.1:8080").unwrap();
        assert_eq!(
            (plain.port, plain.path.as_str(), plain.https),
            (8080, "/", false)
        );
        assert!(parse_url("ftp://x").is_err());
    }
}
