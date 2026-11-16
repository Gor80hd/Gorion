//! Поток до сервера: голый TCP, обычный TLS или REALITY, по желанию с
//! транспортом поверх (WebSocket, HTTPUpgrade, gRPC, XHTTP). Общий для
//! протоколов, которые идут поверх него (VLESS, Trojan).

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::grpc::{self, GrpcReader, GrpcWriter};
use crate::reality::RealityConfig;
use crate::tls::{self, Auth, TlsConfig, TlsReader, TlsWriter};
use crate::transport::{self, Transport, UpgradeReader, UpgradeWriter};
use crate::xhttp::{self, XhttpReader, XhttpWriter};

/// Кусок чтения без TLS.
pub const READ_SIZE: usize = 16 * 1024;

#[derive(Debug, Clone)]
pub enum Security {
    None,
    Tls(TlsConfig),
    Reality(RealityConfig),
}

impl Security {
    pub fn is_none(&self) -> bool {
        matches!(self, Self::None)
    }

    fn server_name(&self) -> Option<String> {
        match self {
            Self::None => None,
            Self::Tls(config) => Some(config.server_name.clone()),
            Self::Reality(config) => Some(config.server_name.clone()),
        }
    }
}

pub enum Down {
    Tcp(OwnedReadHalf),
    Tls(Box<TlsReader<OwnedReadHalf>>),
    Upgrade(Box<UpgradeReader>),
    Grpc(Box<GrpcReader>),
    Xhttp(Box<XhttpReader>),
    /// Переход TLS → сырой TCP (Vision) в процессе.
    Switching,
}

pub enum Up {
    Tcp(OwnedWriteHalf),
    Tls(Box<TlsWriter<OwnedWriteHalf>>),
    Upgrade(Box<UpgradeWriter>),
    Grpc(Box<GrpcWriter>),
    Xhttp(Box<XhttpWriter>),
    Switching,
}

/// Устанавливает защиту поверх подключённого сокета.
pub async fn secure(stream: TcpStream, security: &Security, alpn: &[String]) -> Result<(Down, Up)> {
    let auth = match security {
        Security::None => {
            let (read, write) = stream.into_split();
            return Ok((Down::Tcp(read), Up::Tcp(write)));
        }
        Security::Tls(config) => Auth::Certificate(config),
        Security::Reality(config) => Auth::Reality(config),
    };
    let (read, write) = tls::connect(stream, &auth, alpn).await?;
    Ok((Down::Tls(Box::new(read)), Up::Tls(Box::new(write))))
}

/// Подключается к серверу: TCP, защита, транспорт.
pub async fn open(
    server: &TargetAddr,
    security: &Security,
    transport: &Transport,
    alpn: &[String],
) -> Result<(Down, Up)> {
    if let Transport::Xhttp(config) = transport {
        let (reader, writer) = xhttp::open(config, server, security, alpn).await?;
        return Ok((Down::Xhttp(Box::new(reader)), Up::Xhttp(Box::new(writer))));
    }
    let alpn = transport.alpn(alpn);
    if let Transport::Grpc(config) = transport {
        let (reader, writer) = grpc::open(config, server, security, &alpn).await?;
        return Ok((Down::Grpc(Box::new(reader)), Up::Grpc(Box::new(writer))));
    }
    let tcp = crate::outbound::dial(server).await?;
    let (down, up) = secure(tcp, security, &alpn).await?;
    let (reader, writer) = match transport {
        Transport::None | Transport::Grpc(_) | Transport::Xhttp(_) => return Ok((down, up)),
        Transport::WebSocket(config) => transport::websocket(down, up, config, server.to_string()),
        Transport::HttpUpgrade(config) => {
            transport::http_upgrade(down, up, config, server.to_string(), security.server_name())
        }
    };
    Ok((
        Down::Upgrade(Box::new(reader)),
        Up::Upgrade(Box::new(writer)),
    ))
}

impl Down {
    /// Следующий кусок от сервера; `None` — поток закончился.
    pub async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        match self {
            Self::Tls(reader) => reader.read_record().await,
            Self::Tcp(reader) => {
                let mut buf = vec![0u8; READ_SIZE];
                let n = reader.read(&mut buf).await?;
                buf.truncate(n);
                Ok((n > 0).then_some(buf))
            }
            Self::Upgrade(reader) => reader.read_chunk().await,
            Self::Grpc(reader) => reader.read_chunk().await,
            // Box: сессия HTTP/1.1 читает свой `Down` — рекурсия типов.
            Self::Xhttp(reader) => Box::pin(reader.read_chunk()).await,
            Self::Switching => Err(EngineError::Protocol("stream: reader is gone")),
        }
    }
}

impl Up {
    pub async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        match self {
            Self::Tcp(w) => Ok(w.write_all(data).await?),
            Self::Tls(w) => w.write_all(data).await,
            Self::Upgrade(w) => w.write_all(data).await,
            Self::Grpc(w) => w.write_all(data).await,
            Self::Xhttp(w) => Box::pin(w.write_all(data)).await,
            Self::Switching => Err(EngineError::Protocol("stream: writer is gone")),
        }
    }
}
