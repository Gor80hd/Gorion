//! Пересылка между клиентом и протоколом, который режет поток на куски.

use std::future::Future;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::{mpsc, watch};
use tokio::time::{Instant, sleep_until, timeout};

use crate::error::{EngineError, Result};
use crate::outbound::{HALF_CLOSE_LINGER, Transferred};
use crate::selector::Traffic;

/// Сколько ждать первых байтов клиента, прежде чем отправить заголовок
/// без них (протоколы, где сервер говорит первым). Как в Xray.
pub const FIRST_PAYLOAD_WAIT: Duration = Duration::from_millis(500);

pub trait ChunkRead: Send + 'static {
    /// Следующий кусок от сервера; `None` — поток закончился.
    fn read_chunk(&mut self) -> impl Future<Output = Result<Option<Vec<u8>>>> + Send;
}

pub trait PayloadWrite: Send {
    fn write_payload(&mut self, data: &[u8]) -> impl Future<Output = Result<()>> + Send;

    /// Клиент молчит: отправить заголовок запроса без данных.
    fn flush_header(&mut self) -> impl Future<Output = Result<()>> + Send {
        async { Ok(()) }
    }
}

/// Пересылает данные в обе стороны.
///
/// Клиент не посылает серверу FIN: sing-box в ответ на него закрывает
/// подключение целиком и теряет недосланный ответ. Обратное направление
/// живёт, пока данные идут, и закрывается после паузы `HALF_CLOSE_LINGER`.
pub async fn relay<R: ChunkRead, W: PayloadWrite>(
    client: TcpStream,
    mut reader: R,
    mut writer: W,
    read_size: usize,
    traffic: &Traffic,
) -> Result<Transferred> {
    let (mut client_read, mut client_write) = client.into_split();
    let (uplink_done, mut uplink_closed) = watch::channel(false);
    let up = async {
        let mut buf = vec![0u8; read_size];
        let mut total = 0u64;
        let mut first = true;
        loop {
            let n = if first {
                first = false;
                match timeout(FIRST_PAYLOAD_WAIT, client_read.read(&mut buf)).await {
                    Ok(read) => read?,
                    Err(_) => {
                        writer.flush_header().await?;
                        client_read.read(&mut buf).await?
                    }
                }
            } else {
                client_read.read(&mut buf).await?
            };
            if n == 0 {
                let _ = uplink_done.send(true);
                // `writer` живёт до конца пересылки: сокет закроется вместе с ней.
                return Ok::<u64, EngineError>(total);
            }
            writer.write_payload(&buf[..n]).await?;
            traffic.add_up(n);
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
                        traffic.add_down(chunk.len());
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
    Ok(Transferred {
        up,
        down,
        direct: false,
    })
}
