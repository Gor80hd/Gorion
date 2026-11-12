//! Исходящие подключения: напрямую или через протокол.

use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};

use crate::address::TargetAddr;
use crate::error::Result;
use crate::relay::{ChunkRead, PayloadWrite, relay};
use crate::selector::Traffic;
use crate::shadowsocks::{self, MAX_PAYLOAD, ShadowsocksConfig, SsReader, SsWriter};
use crate::shadowsocks2022::{self, Ss2022Config, Ss2022Reader, Ss2022Writer};
use crate::trojan::{self, TrojanConfig, TrojanReader, TrojanWriter};
use crate::vless::{self, DirectCopy, VlessConfig, VlessReader, VlessWriter};

#[derive(Debug, Clone)]
pub enum Outbound {
    Direct,
    Shadowsocks(ShadowsocksConfig),
    Shadowsocks2022(Box<Ss2022Config>),
    Trojan(Box<TrojanConfig>),
    Vless(Box<VlessConfig>),
}

/// Установленное подключение, готовое к пересылке данных.
pub enum Connection {
    Direct(TcpStream),
    Shadowsocks(SsReader<OwnedReadHalf>, SsWriter<OwnedWriteHalf>),
    Shadowsocks2022(Box<(Ss2022Reader<OwnedReadHalf>, Ss2022Writer<OwnedWriteHalf>)>),
    Trojan(Box<(TrojanReader, TrojanWriter)>),
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
    /// Адрес сервера протокола; у прямого подключения его нет.
    pub fn server(&self) -> Option<&TargetAddr> {
        match self {
            Self::Direct => None,
            Self::Shadowsocks(config) => Some(&config.server),
            Self::Shadowsocks2022(config) => Some(&config.server),
            Self::Trojan(config) => Some(&config.server),
            Self::Vless(config) => Some(&config.server),
        }
    }

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
            Self::Shadowsocks2022(config) => {
                let parts = shadowsocks2022::connect(config, target, initial).await?;
                Ok(Connection::Shadowsocks2022(Box::new(parts)))
            }
            Self::Trojan(config) => {
                let parts = trojan::connect(config, target, initial).await?;
                Ok(Connection::Trojan(Box::new(parts)))
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
    /// `traffic` растёт по мере передачи — для графика скорости.
    pub async fn relay(self, client: TcpStream, traffic: &Traffic) -> Result<Transferred> {
        match self {
            Self::Direct(mut remote) => {
                let mut client = Counted {
                    inner: client,
                    traffic,
                };
                let (up, down) = tokio::io::copy_bidirectional(&mut client, &mut remote).await?;
                Ok(Transferred {
                    up,
                    down,
                    direct: false,
                })
            }
            Self::Shadowsocks(reader, writer) => {
                relay(client, reader, writer, MAX_PAYLOAD, traffic).await
            }
            Self::Shadowsocks2022(parts) => {
                let (reader, writer) = *parts;
                relay(client, reader, writer, STREAM_READ_SIZE, traffic).await
            }
            Self::Trojan(parts) => {
                let (reader, writer) = *parts;
                relay(client, reader, writer, STREAM_READ_SIZE, traffic).await
            }
            Self::Vless(parts) => {
                let (reader, writer, direct) = *parts;
                let mut transferred =
                    relay(client, reader, writer, VLESS_READ_SIZE, traffic).await?;
                transferred.direct = direct.both();
                Ok(transferred)
            }
        }
    }
}

/// Клиентский сокет, считающий байты: чтение — отправка, запись — приём.
struct Counted<'a> {
    inner: TcpStream,
    traffic: &'a Traffic,
}

impl AsyncRead for Counted<'_> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buf.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, buf);
        self.traffic.add_up(buf.filled().len() - before);
        result
    }
}

impl AsyncWrite for Counted<'_> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        let result = Pin::new(&mut self.inner).poll_write(cx, data);
        if let Poll::Ready(Ok(n)) = result {
            self.traffic.add_down(n);
        }
        result
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

/// Кусок чтения от клиента для VLESS: Vision сам делит его на кадры.
const VLESS_READ_SIZE: usize = 16 * 1024;
/// Кусок чтения от клиента для потоковых протоколов: одна запись TLS.
const STREAM_READ_SIZE: usize = 16 * 1024;

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

/// TCP-подключение к адресу; домен разрешается системным резолвером или
/// берётся из заранее разрешённых (режим TUN, см. `netbind`).
pub async fn dial(target: &TargetAddr) -> Result<TcpStream> {
    let stream = crate::netbind::connect(target).await?;
    stream.set_nodelay(true)?;
    Ok(stream)
}
