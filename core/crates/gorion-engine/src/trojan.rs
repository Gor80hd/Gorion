//! Trojan: поверх TLS клиент шлёт хеш пароля и адрес, дальше — сырой поток.
//! Эталон: sing-box `transport/trojan`.
//!
//! Запрос: [hex(SHA224(пароль)) 56] [CRLF] [команда: 1 — TCP] [адрес как в
//! SOCKS5] [CRLF]. Ответа нет: сервер сразу пересылает данные.

use std::fmt;

use sha2::{Digest, Sha224};

use crate::address::TargetAddr;
use crate::error::Result;
use crate::relay::{ChunkRead, PayloadWrite};
pub use crate::stream::Security;
use crate::stream::{self, Down, Up};

const COMMAND_TCP: u8 = 1;
const CRLF: &[u8] = b"\r\n";

#[derive(Clone)]
pub struct TrojanConfig {
    pub server: TargetAddr,
    /// hex(SHA224(пароль)) — то, что видит сервер.
    key: [u8; 56],
    pub security: Security,
    pub alpn: Vec<String>,
}

impl fmt::Debug for TrojanConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Хеш пароля — пропуск к серверу: в журнал не попадает.
        f.debug_struct("TrojanConfig")
            .field("server", &self.server)
            .field("security", &self.security)
            .finish_non_exhaustive()
    }
}

impl TrojanConfig {
    pub fn new(server: TargetAddr, password: &str, security: Security) -> Self {
        Self {
            server,
            key: password_key(password),
            security,
            alpn: vec!["h2".into(), "http/1.1".into()],
        }
    }
}

pub fn password_key(password: &str) -> [u8; 56] {
    let digest = Sha224::digest(password.as_bytes());
    let mut out = [0u8; 56];
    for (i, byte) in digest.iter().enumerate() {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        out[2 * i] = HEX[usize::from(byte >> 4)];
        out[2 * i + 1] = HEX[usize::from(byte & 0x0f)];
    }
    out
}

pub fn request_header(key: &[u8; 56], target: &TargetAddr) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(56 + 2 + 1 + 32 + 2);
    out.extend_from_slice(key);
    out.extend_from_slice(CRLF);
    out.push(COMMAND_TCP);
    target.write_socks(&mut out)?;
    out.extend_from_slice(CRLF);
    Ok(out)
}

pub struct TrojanReader {
    down: Down,
}

pub struct TrojanWriter {
    up: Up,
    header: Option<Vec<u8>>,
}

/// Подключается к серверу. Заголовок уходит вместе с первыми данными
/// клиента (или по `flush_header`).
pub async fn connect(
    config: &TrojanConfig,
    target: &TargetAddr,
    initial: &[u8],
) -> Result<(TrojanReader, TrojanWriter)> {
    let tcp = crate::outbound::dial(&config.server).await?;
    let (down, up) = stream::secure(tcp, &config.security, &config.alpn).await?;
    let mut writer = TrojanWriter {
        up,
        header: Some(request_header(&config.key, target)?),
    };
    if !initial.is_empty() {
        writer.write_payload(initial).await?;
    }
    Ok((TrojanReader { down }, writer))
}

impl ChunkRead for TrojanReader {
    async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        self.down.read_chunk().await
    }
}

impl PayloadWrite for TrojanWriter {
    async fn write_payload(&mut self, data: &[u8]) -> Result<()> {
        match self.header.take() {
            Some(mut first) => {
                first.extend_from_slice(data);
                self.up.write_all(&first).await
            }
            None => self.up.write_all(data).await,
        }
    }

    async fn flush_header(&mut self) -> Result<()> {
        match self.header.take() {
            Some(header) => self.up.write_all(&header).await,
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn header_bytes() {
        // SHA224("password") — известный вектор.
        let key = password_key("password");
        assert_eq!(
            &key,
            b"d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01"
        );
        let target = TargetAddr::Domain("example.com".into(), 443);
        let header = request_header(&key, &target).unwrap();
        assert_eq!(&header[56..59], b"\r\n\x01");
        assert_eq!(&header[59..61], &[3, 11]);
        assert_eq!(&header[61..72], b"example.com");
        assert_eq!(&header[72..], &[0x01, 0xbb, b'\r', b'\n']);
    }

    #[test]
    fn debug_hides_password() {
        let config = TrojanConfig::new(TargetAddr::Domain("h".into(), 1), "secret", Security::None);
        let text = format!("{config:?}");
        assert!(!text.contains("key") && !text.contains("secret"));
    }
}
