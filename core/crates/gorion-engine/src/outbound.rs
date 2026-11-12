//! Исходящие подключения: напрямую или через протокол.

use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::net::tcp::{OwnedReadHalf, OwnedWriteHalf};
use tokio::sync::{mpsc, watch};
use tokio::time::{Instant, sleep_until};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::shadowsocks::{self, MAX_PAYLOAD, ShadowsocksConfig, SsReader, SsWriter};

#[derive(Debug, Clone)]
pub enum Outbound {
    Direct,
    Shadowsocks(ShadowsocksConfig),
}

/// Установленное подключение, готовое к пересылке данных.
pub enum Connection {
    Direct(TcpStream),
    Shadowsocks(SsReader<OwnedReadHalf>, SsWriter<OwnedWriteHalf>),
}

/// Счётчики переданного за подключение, байт.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct Transferred {
    pub up: u64,
    pub down: u64,
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
                Ok(Transferred { up, down })
            }
            Self::Shadowsocks(reader, writer) => relay_shadowsocks(client, reader, writer).await,
        }
    }
}

/// Сколько ещё ждать ответа сервера, когда клиент закончил отправку.
///
/// Клиент не посылает серверу FIN: sing-box в ответ на него закрывает
/// подключение целиком и теряет недосланный ответ. Как Xray и sing-box,
/// оставляем обратное направление открытым, пока данные идут, и закрываем
/// после паузы.
pub const HALF_CLOSE_LINGER: Duration = Duration::from_secs(2);

async fn relay_shadowsocks(
    client: TcpStream,
    mut reader: SsReader<OwnedReadHalf>,
    mut writer: SsWriter<OwnedWriteHalf>,
) -> Result<Transferred> {
    let (mut client_read, mut client_write) = client.into_split();
    let (uplink_done, mut uplink_closed) = watch::channel(false);
    let up = async {
        let mut buf = vec![0u8; MAX_PAYLOAD];
        let mut total = 0u64;
        loop {
            let n = client_read.read(&mut buf).await?;
            if n == 0 {
                let _ = uplink_done.send(true);
                // `writer` живёт до конца пересылки: сокет закроется вместе с ней.
                return Ok::<u64, EngineError>(total);
            }
            writer.write_payload(&buf[..n]).await?;
            total += n as u64;
        }
    };
    let down = async {
        // Чтение кусков — в отдельной задаче: ожидание в `select!` можно
        // прервать без потери уже прочитанных байтов.
        let (chunks_tx, mut chunks) = mpsc::channel::<Result<Vec<u8>>>(16);
        let pump = tokio::spawn(async move {
            loop {
                let next = reader.read_chunk().await.transpose();
                let stop = !matches!(next, Some(Ok(_)));
                if let Some(item) = next
                    && chunks_tx.send(item).await.is_err()
                {
                    return;
                }
                if stop {
                    return;
                }
            }
        });
        let mut total = 0u64;
        let mut linger: Option<Instant> = None;
        let result = loop {
            tokio::select! {
                chunk = chunks.recv() => match chunk {
                    Some(Ok(chunk)) => {
                        if let Err(error) = client_write.write_all(&chunk).await {
                            break Err(error.into());
                        }
                        total += chunk.len() as u64;
                        if linger.is_some() {
                            linger = Some(Instant::now() + HALF_CLOSE_LINGER);
                        }
                    }
                    Some(Err(error)) => break Err(error),
                    None => break Ok(()),
                },
                _ = uplink_closed.changed(), if linger.is_none() => {
                    linger = Some(Instant::now() + HALF_CLOSE_LINGER);
                }
                () = sleep_until(linger.unwrap_or_else(Instant::now)), if linger.is_some() => break Ok(()),
            }
        };
        pump.abort();
        result?;
        client_write.shutdown().await?;
        Ok::<u64, EngineError>(total)
    };
    let (up, down) = tokio::try_join!(up, down)?;
    Ok(Transferred { up, down })
}

/// TCP-подключение к адресу; домен разрешается системным резолвером.
pub async fn dial(target: &TargetAddr) -> Result<TcpStream> {
    let stream = match target {
        TargetAddr::Ip(addr) => TcpStream::connect(addr).await?,
        TargetAddr::Domain(host, port) => TcpStream::connect((host.as_str(), *port)).await?,
    };
    stream.set_nodelay(true)?;
    Ok(stream)
}
