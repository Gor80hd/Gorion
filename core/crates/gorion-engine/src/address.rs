//! Адрес назначения в формате SOCKS5 (RFC 1928, раздел 5). Тот же формат
//! используют Shadowsocks, Trojan и VLESS (с поправками у VLESS).

use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};

use tokio::io::{AsyncRead, AsyncReadExt};

use crate::error::{EngineError, Result};

const ATYP_IPV4: u8 = 1;
const ATYP_DOMAIN: u8 = 3;
const ATYP_IPV6: u8 = 4;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum TargetAddr {
    Ip(SocketAddr),
    Domain(String, u16),
}

impl TargetAddr {
    pub fn port(&self) -> u16 {
        match self {
            Self::Ip(addr) => addr.port(),
            Self::Domain(_, port) => *port,
        }
    }

    /// Дописывает адрес в формате SOCKS5: тип, адрес, порт (big-endian).
    pub fn write_socks(&self, out: &mut Vec<u8>) -> Result<()> {
        match self {
            Self::Ip(SocketAddr::V4(addr)) => {
                out.push(ATYP_IPV4);
                out.extend_from_slice(&addr.ip().octets());
            }
            Self::Ip(SocketAddr::V6(addr)) => {
                out.push(ATYP_IPV6);
                out.extend_from_slice(&addr.ip().octets());
            }
            Self::Domain(host, _) => {
                let len = u8::try_from(host.len()).map_err(|_| EngineError::BadAddress)?;
                if len == 0 {
                    return Err(EngineError::BadAddress);
                }
                out.push(ATYP_DOMAIN);
                out.push(len);
                out.extend_from_slice(host.as_bytes());
            }
        }
        out.extend_from_slice(&self.port().to_be_bytes());
        Ok(())
    }

    pub async fn read_socks<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Self> {
        let atyp = reader.read_u8().await?;
        let addr = match atyp {
            ATYP_IPV4 => {
                let mut ip = [0u8; 4];
                reader.read_exact(&mut ip).await?;
                let port = reader.read_u16().await?;
                Self::Ip(SocketAddr::new(IpAddr::V4(Ipv4Addr::from(ip)), port))
            }
            ATYP_IPV6 => {
                let mut ip = [0u8; 16];
                reader.read_exact(&mut ip).await?;
                let port = reader.read_u16().await?;
                Self::Ip(SocketAddr::new(IpAddr::V6(Ipv6Addr::from(ip)), port))
            }
            ATYP_DOMAIN => {
                let len = usize::from(reader.read_u8().await?);
                let mut host = vec![0u8; len];
                reader.read_exact(&mut host).await?;
                let port = reader.read_u16().await?;
                let host = String::from_utf8(host).map_err(|_| EngineError::BadAddress)?;
                Self::from_host(&host, port)?
            }
            _ => return Err(EngineError::BadAddress),
        };
        Ok(addr)
    }

    /// Хост из строки: IP становится `Ip`, остальное — `Domain`.
    pub fn from_host(host: &str, port: u16) -> Result<Self> {
        let host = host.trim_start_matches('[').trim_end_matches(']');
        if host.is_empty() {
            return Err(EngineError::BadAddress);
        }
        Ok(match host.parse::<IpAddr>() {
            Ok(ip) => Self::Ip(SocketAddr::new(ip, port)),
            Err(_) => Self::Domain(host.to_ascii_lowercase(), port),
        })
    }

    /// `host`, `host:port`, `[v6]` или `[v6]:port`.
    pub fn parse_authority(authority: &str, default_port: u16) -> Result<Self> {
        if let Some(rest) = authority.strip_prefix('[') {
            let (host, tail) = rest.split_once(']').ok_or(EngineError::BadAddress)?;
            let port = match tail.strip_prefix(':') {
                Some(port) => port.parse().map_err(|_| EngineError::BadAddress)?,
                None if tail.is_empty() => default_port,
                None => return Err(EngineError::BadAddress),
            };
            return Self::from_host(host, port);
        }
        match authority.rsplit_once(':') {
            // Голый IPv6 без скобок: двоеточий больше одного.
            Some((host, _)) if host.contains(':') => Self::from_host(authority, default_port),
            Some((host, port)) => {
                Self::from_host(host, port.parse().map_err(|_| EngineError::BadAddress)?)
            }
            None => Self::from_host(authority, default_port),
        }
    }
}

impl fmt::Display for TargetAddr {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ip(addr) => write!(f, "{addr}"),
            Self::Domain(host, port) => write!(f, "{host}:{port}"),
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[tokio::test]
    async fn socks_round_trip() {
        let cases = [
            TargetAddr::Ip("1.2.3.4:443".parse().unwrap()),
            TargetAddr::Ip("[2001:db8::1]:8443".parse().unwrap()),
            TargetAddr::Domain("example.com".into(), 80),
        ];
        for addr in cases {
            let mut buf = Vec::new();
            addr.write_socks(&mut buf).unwrap();
            let decoded = TargetAddr::read_socks(&mut buf.as_slice()).await.unwrap();
            assert_eq!(decoded, addr);
        }
    }

    #[test]
    fn domain_wire_format() {
        let mut buf = Vec::new();
        TargetAddr::Domain("ab".into(), 0x1234)
            .write_socks(&mut buf)
            .unwrap();
        assert_eq!(buf, [3, 2, b'a', b'b', 0x12, 0x34]);
    }

    #[test]
    fn parses_authorities() {
        assert_eq!(
            TargetAddr::parse_authority("Example.com", 80).unwrap(),
            TargetAddr::Domain("example.com".into(), 80)
        );
        assert_eq!(
            TargetAddr::parse_authority("example.com:8080", 80).unwrap(),
            TargetAddr::Domain("example.com".into(), 8080)
        );
        assert_eq!(
            TargetAddr::parse_authority("[::1]:443", 80).unwrap(),
            TargetAddr::Ip("[::1]:443".parse().unwrap())
        );
        assert_eq!(
            TargetAddr::parse_authority("[::1]", 80).unwrap(),
            TargetAddr::Ip("[::1]:80".parse().unwrap())
        );
        assert_eq!(
            TargetAddr::parse_authority("10.0.0.1:22", 80).unwrap(),
            TargetAddr::Ip("10.0.0.1:22".parse().unwrap())
        );
        assert!(TargetAddr::parse_authority("host:port", 80).is_err());
        assert!(TargetAddr::parse_authority("", 80).is_err());
        assert!(
            TargetAddr::Domain("x".repeat(256), 1)
                .write_socks(&mut Vec::new())
                .is_err()
        );
    }
}
