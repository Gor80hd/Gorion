//! Исходящие подключения: напрямую или через протокол.

use std::sync::Arc;
use std::time::Duration;

use tokio::io::AsyncWriteExt;
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};

use crate::address::TargetAddr;
use crate::error::Result;
use crate::relay::{ChunkRead, PayloadWrite, relay};
use crate::shadowsocks::{self, MAX_PAYLOAD, ShadowsocksConfig, SsReader, SsWriter};
use crate::vless::{self, DirectCopy, VlessConfig, VlessReader, VlessWriter};

#[derive(Debug, Clone)]
pub enum Outbound {
    Direct,
    Shadowsocks(ShadowsocksConfig),
    Vless(Box<VlessConfig>),
}

/// Установленное подключение, готовое к пересылке данных.
pub enum Connection {
    Direct(TcpStream),
    Shadowsocks(SsReader<OwnedReadHalf>, SsWriter<OwnedWriteHalf>),
    Vless(Box<(VlessReader, VlessWriter, Arc<DirectCopy>)>),
}

/// Счётчики переданного за подключение, байт.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Transferred {
    pub up: u64,
    pub down: u64,
    /// Vision перешёл на прямое копирование в обе стороны.
    pub direct: bool,
}

impl Outbound {
    /// Открывает подключение к `target`; `initial` уходит первым.
    pub async fn connect(&self, target: &TargetAddr, initial: &[u8]) -> Result<Connection> {
        match self {
            Self::Direct => {
                let mut stream = dial(target).await?;
                if !initial.is_empty() {
                    stream.write_all(initial).await?;
                }
                Ok(Connection::Direct(stream))
            }
            Self::Shadowsocks(config) => {
                let (reader, writer) = shadowsocks::connect(config, target, initial).await?;
                Ok(Connection::Shadowsocks(reader, writer))
            }
            Self::Vless(config) => {
                let parts = vless::connect(config, target, initial).await?;
                Ok(Connection::Vless(Box::new(parts)))
            }
        }
    }
}

impl Connection {
    /// Пересылает данные в обе стороны, пока обе не закроются.
    pub async fn relay(self, client: TcpStream) -> Result<Transferred> {
        match self {
            Self::Direct(mut remote) => {
                let mut client = client;
                let (up, down) = tokio::io::copy_bidirectional(&mut client, &mut remote).await?;
                Ok(Transferred {
                    up,
                    down,
                    direct: false,
                })
            }
            Self::Shadowsocks(reader, writer) => relay(client, reader, writer, MAX_PAYLOAD).await,
            Self::Vless(parts) => {
                let (reader, writer, direct) = *parts;
                let mut transferred = relay(client, reader, writer, VLESS_READ_SIZE).await?;
                transferred.direct = direct.both();
                Ok(transferred)
            }
        }
    }
}

/// Кусок чтения от клиента для VLESS: Vision сам делит его на кадры.
const VLESS_READ_SIZE: usize = 16 * 1024;

impl ChunkRead for SsReader<OwnedReadHalf> {
    async fn read_chunk(&mut self) -> Result<Option<Vec<u8>>> {
        SsReader::read_chunk(self).await
    }
}

impl PayloadWrite for SsWriter<OwnedWriteHalf> {
    async fn write_payload(&mut self, data: &[u8]) -> Result<()> {
        SsWriter::write_payload(self, data).await
    }
}

/// Сколько ещё ждать ответа сервера, когда клиент закончил отправку.
///
/// Клиент не посылает серверу FIN: sing-box в ответ на него закрывает
/// подключение целиком и теряет недосланный ответ. Как Xray и sing-box,
/// оставляем обратное направление открытым, пока данные идут, и закрываем
/// после паузы.
pub const HALF_CLOSE_LINGER: Duration = Duration::from_secs(2);

/// TCP-подключение к адресу; домен разрешается системным резолвером.
pub async fn dial(target: &TargetAddr) -> Result<TcpStream> {
    let stream = match target {
        TargetAddr::Ip(addr) => TcpStream::connect(addr).await?,
        TargetAddr::Domain(host, port) => TcpStream::connect((host.as_str(), *port)).await?,
    };
    stream.set_nodelay(true)?;
    Ok(stream)
}
