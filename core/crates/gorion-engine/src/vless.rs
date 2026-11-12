//! VLESS: заголовок запроса с UUID и адресом, дальше — сырой поток.
//! Поверх TCP, TLS или REALITY, с Vision или без. Эталон: sing-vmess `vless/`.
//!
//! Запрос: [версия 0] [UUID 16] [длина дополнений] [дополнения: protobuf,
//! поле 1 — flow] [команда: 1 — TCP] [порт u16] [тип адреса: 1 — IPv4,
//! 2 — домен, 3 — IPv6] [адрес]. Ответ: [версия] [длина дополнений] [они].

use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::relay::{ChunkRead, PayloadWrite};
pub use crate::stream::Security;
use crate::stream::{self, Down, Up};
use crate::transport::Transport;
use crate::vision::{SharedFilter, VisionReader, VisionWriter};
use sha1::{Digest, Sha1};

const VERSION: u8 = 0;
const COMMAND_TCP: u8 = 1;
const ATYP_IPV4: u8 = 1;
const ATYP_DOMAIN: u8 = 2;
const ATYP_IPV6: u8 = 3;
pub const FLOW_VISION: &str = "xtls-rprx-vision";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Flow {
    None,
    Vision,
}

impl Flow {
    pub fn parse(flow: &str) -> Result<Self> {
        match flow {
            "" | "none" => Ok(Self::None),
            FLOW_VISION => Ok(Self::Vision),
            _ => Err(EngineError::Protocol("vless: unsupported flow")),
        }
    }
}

#[derive(Clone)]
pub struct VlessConfig {
    pub server: TargetAddr,
    pub uuid: [u8; 16],
    pub flow: Flow,
    pub security: Security,
    /// ALPN в ClientHello; по умолчанию как у Chrome.
    pub alpn: Vec<String>,
    pub transport: Transport,
}

impl fmt::Debug for VlessConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // UUID — пароль пользователя: в журнал не попадает.
        f.debug_struct("VlessConfig")
            .field("server", &self.server)
            .field("flow", &self.flow)
            .field("security", &self.security)
            .field("transport", &self.transport)
            .finish_non_exhaustive()
    }
}

impl VlessConfig {
    pub fn new(server: TargetAddr, user_id: &str, flow: Flow, security: Security) -> Self {
        Self {
            server,
            uuid: parse_user_id(user_id),
            flow,
            security,
            alpn: vec!["h2".into(), "http/1.1".into()],
            transport: Transport::None,
        }
    }
}

/// UUID пользователя. Не-UUID строка, как в Xray и sing-box, превращается
/// в UUIDv5 от нулевого пространства имён.
pub fn parse_user_id(id: &str) -> [u8; 16] {
    let hex: String = id.chars().filter(|c| *c != '-').collect();
    if id.len() == 36 && hex.len() == 32 {
        let mut out = [0u8; 16];
        let parsed = (0..16).all(|i| {
            u8::from_str_radix(&hex[2 * i..2 * i + 2], 16)
                .map(|b| out[i] = b)
                .is_ok()
        });
        if parsed {
            return out;
        }
    }
    let digest = Sha1::new()
        .chain_update([0u8; 16])
        .chain_update(id.as_bytes())
        .finalize();
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest[..16]);
    out[6] = (out[6] & 0x0f) | 0x50;
    out[8] = (out[8] & 0x3f) | 0x80;
    out
}

pub fn request_header(uuid: &[u8; 16], flow: Flow, target: &TargetAddr) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(64);
    out.push(VERSION);
    out.extend_from_slice(uuid);
    match flow {
        Flow::None => out.push(0),
        Flow::Vision => {
            // protobuf: поле 1, тип 2 (строка), длина, строка.
            out.push((2 + FLOW_VISION.len()) as u8);
            out.push(0x0a);
            out.push(FLOW_VISION.len() as u8);
            out.extend_from_slice(FLOW_VISION.as_bytes());
        }
    }
    out.push(COMMAND_TCP);
    out.extend_from_slice(&target.port().to_be_bytes());
    match target {
        TargetAddr::Ip(addr) => match addr.ip() {
            std::net::IpAddr::V4(ip) => {
                out.push(ATYP_IPV4);
                out.extend_from_slice(&ip.octets());
            }
            std::net::IpAddr::V6(ip) => {
                out.push(ATYP_IPV6);
                out.extend_from_slice(&ip.octets());
            }
        },
        TargetAddr::Domain(host, _) => {
            let len = u8::try_from(host.len()).map_err(|_| EngineError::BadAddress)?;
            out.push(ATYP_DOMAIN);
            out.push(len);
            out.extend_from_slice(host.as_bytes());
        }
    }
    Ok(out)
}

/// Перешёл ли Vision на прямое копирование (для проверок и журнала).
#[derive(Debug, Default)]
pub struct DirectCopy {
    pub up: AtomicBool,
    pub down: AtomicBool,
}

impl DirectCopy {
    pub fn both(&self) -> bool {
        self.up.load(Ordering::Relaxed) && self.down.load(Ordering::Relaxed)
    }
}

pub struct VlessReader {
    down: Down,
    /// Ответ сервера ещё не дочитан: копим байты.
    response: Option<Vec<u8>>,
    vision: Option<VisionReader>,
    direct: Arc<DirectCopy>,
}

pub struct VlessWriter {
    up: Up,
    header: Option<Vec<u8>>,
    vision: Option<VisionWriter>,
    direct: Arc<DirectCopy>,
}

/// Подключается к серверу. Заголовок уходит вместе с первыми данными
/// клиента (или по `flush_header`), чтобы не выдавать себя отдельной записью.
pub async fn connect(
    config: &VlessConfig,
    target: &TargetAddr,
    initial: &[u8],
) -> Result<(VlessReader, VlessWriter, Arc<DirectCopy>)> {
    if config.flow == Flow::Vision && (config.security.is_none() || !config.transport.is_none()) {
        return Err(EngineError::Protocol("vless: vision requires TLS over TCP"));
    }
    let (down, up) = stream::open(
        &config.server,
        &config.security,
        &config.transport,
        &config.alpn,
    )
    .await?;
    let direct = Arc::new(DirectCopy::default());
    let filter = SharedFilter::default();
    let vision = config.flow == Flow::Vision;
    let reader = VlessReader {
        down,
        response: Some(Vec::new()),
        vision: vision.then(|| VisionReader::new(config.uuid, filter.clone())),
        direct: Arc::clone(&direct),
    };
    let mut writer = VlessWriter {
        up,
        header: Some(request_header(&config.uuid, config.flow, target)?),
        vision: vision.then(|| VisionWriter::new(config.uuid, filter)),
        direct: Arc::clone(&direct),
    };
    if !initial.is_empty() {
        writer.write_payload(initial).await?;
    }
    Ok((reader, writer, direct))
}

impl ChunkRead for VlessReader {
    async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        loop {
            let Some(mut chunk) = self.down.read_chunk().await? else {
                return Ok(None);
            };
            if let Some(pending) = &mut self.response {
                pending.extend_from_slice(&chunk);
                if pending.len() < 2 {
                    continue;
                }
                if pending[0] != VERSION {
                    return Err(EngineError::Protocol("vless: unexpected response version"));
                }
                let header = 2 + usize::from(pending[1]);
                if pending.len() < header {
                    continue;
                }
                chunk = pending.split_off(header);
                self.response = None;
                if chunk.is_empty() {
                    continue;
                }
            }
            if let Some(vision) = &mut self.vision {
                let (mut out, direct) = vision.decode(&chunk)?;
                if direct {
                    // Дальше сервер пишет мимо TLS: остаток буфера записей —
                    // уже сырые байты.
                    if let Down::Tls(reader) = std::mem::replace(&mut self.down, Down::Switching) {
                        let (raw, leftover) = reader.into_raw();
                        out.extend_from_slice(&leftover);
                        self.down = Down::Tcp(raw);
                        self.direct.down.store(true, Ordering::Relaxed);
                    }
                }
                if out.is_empty() {
                    continue;
                }
                return Ok(Some(out));
            }
            return Ok(Some(chunk));
        }
    }
}

impl PayloadWrite for VlessWriter {
    async fn write_payload(&mut self, data: &[u8]) -> Result<()> {
        let mut first = self.header.take().unwrap_or_default();
        let Some(vision) = &mut self.vision else {
            first.extend_from_slice(data);
            return self.up.write_all(&first).await;
        };
        let encoded = vision.encode(data)?;
        first.extend_from_slice(&encoded.tls);
        self.up.write_all(&first).await?;
        if encoded.switch_to_raw
            && let Up::Tls(writer) = std::mem::replace(&mut self.up, Up::Switching)
        {
            self.up = Up::Tcp(writer.into_inner());
            self.direct.up.store(true, Ordering::Relaxed);
        }
        self.up.write_all(&encoded.raw).await
    }

    async fn flush_header(&mut self) -> Result<()> {
        let Some(mut header) = self.header.take() else {
            return Ok(());
        };
        if let Some(vision) = &mut self.vision {
            header.extend_from_slice(&vision.empty_frame()?);
        }
        self.up.write_all(&header).await
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn header_bytes() {
        let uuid = parse_user_id("b831381d-6324-4d53-ad4f-8cda48b30811");
        assert_eq!(uuid[..4], [0xb8, 0x31, 0x38, 0x1d]);
        let target = TargetAddr::Domain("example.com".into(), 443);
        let header = request_header(&uuid, Flow::None, &target).unwrap();
        let mut expected = vec![0];
        expected.extend_from_slice(&uuid);
        expected.extend_from_slice(&[0, 1, 0x01, 0xbb, 2, 11]);
        expected.extend_from_slice(b"example.com");
        assert_eq!(header, expected);

        let target = TargetAddr::Ip("10.0.0.1:80".parse().unwrap());
        let header = request_header(&uuid, Flow::Vision, &target).unwrap();
        assert_eq!(header[17], 18);
        assert_eq!(&header[18..20], &[0x0a, 16]);
        assert_eq!(&header[20..36], FLOW_VISION.as_bytes());
        assert_eq!(&header[36..], &[1, 0, 80, 1, 10, 0, 0, 1]);
    }

    #[test]
    fn non_uuid_ids_map_to_uuid_v5() {
        let id = parse_user_id("gorion");
        assert_eq!(id[6] >> 4, 5);
        assert_eq!(id[8] >> 6, 0b10);
        assert_ne!(id, parse_user_id("gorion2"));
    }
}
