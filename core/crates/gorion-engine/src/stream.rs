//! Поток до сервера: голый TCP, обычный TLS или REALITY. Общий для
//! протоколов, которые идут поверх него (VLESS, Trojan).

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};

use crate::error::{EngineError, Result};
use crate::reality::RealityConfig;
use crate::tls::{self, Auth, TlsConfig, TlsReader, TlsWriter};

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
}

pub enum Down {
    Tcp(OwnedReadHalf),
    Tls(Box<TlsReader<OwnedReadHalf>>),
    /// Переход TLS → сырой TCP (Vision) в процессе.
    Switching,
}

pub enum Up {
    Tcp(OwnedWriteHalf),
    Tls(Box<TlsWriter<OwnedWriteHalf>>),
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
            Self::Switching => Err(EngineError::Protocol("stream: reader is gone")),
        }
    }
}

impl Up {
    pub async fn write_all(&mut self, data: &[u8]) -> Result<()> {
        match self {
            Self::Tcp(w) => Ok(w.write_all(data).await?),
            Self::Tls(w) => w.write_all(data).await,
            Self::Switching => Err(EngineError::Protocol("stream: writer is gone")),
        }
    }
}
