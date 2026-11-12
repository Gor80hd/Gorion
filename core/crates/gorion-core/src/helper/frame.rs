//! Строки JSON поверх потока: одна строка — одно сообщение.
//!
//! Чтение идёт в отдельной задаче и отдаёт сообщения в канал: так ожидание
//! сообщения можно безопасно отменять в `select!`.

use std::io;

use serde::Serialize;
use serde::de::DeserializeOwned;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use super::MAX_FRAME;

pub(crate) struct FrameReader<T> {
    frames: mpsc::Receiver<io::Result<T>>,
    task: JoinHandle<()>,
}

impl<T: DeserializeOwned + Send + 'static> FrameReader<T> {
    pub(crate) fn spawn<R: AsyncRead + Unpin + Send + 'static>(read: R) -> Self {
        let (tx, frames) = mpsc::channel(8);
        let task = tokio::spawn(async move {
            let mut reader = BufReader::new(read);
            loop {
                let frame = match read_line(&mut reader).await {
                    Ok(Some(line)) => serde_json::from_slice::<T>(&line)
                        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e)),
                    Ok(None) => return,
                    Err(error) => Err(error),
                };
                let failed = frame.is_err();
                if tx.send(frame).await.is_err() || failed {
                    return;
                }
            }
        });
        Self { frames, task }
    }

    /// Следующее сообщение; `None` — собеседник закрыл соединение.
    pub(crate) async fn next(&mut self) -> Option<io::Result<T>> {
        self.frames.recv().await
    }
}

impl<T> Drop for FrameReader<T> {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn read_line<R: AsyncRead + Unpin>(reader: &mut BufReader<R>) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    let limit = u64::try_from(MAX_FRAME).unwrap_or(u64::MAX) + 1;
    let read = (&mut *reader)
        .take(limit)
        .read_until(b'\n', &mut line)
        .await?;
    if read == 0 {
        return Ok(None);
    }
    if line.last() != Some(&b'\n') {
        return if line.len() > MAX_FRAME {
            Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "frame too large",
            ))
        } else {
            // Оборванная строка в конце потока.
            Ok(None)
        };
    }
    line.pop();
    Ok(Some(line))
}

pub(crate) async fn write_frame<W: AsyncWrite + Unpin, T: Serialize>(
    write: &mut W,
    message: &T,
) -> io::Result<()> {
    let mut line = serde_json::to_vec(message).map_err(io::Error::other)?;
    line.push(b'\n');
    write.write_all(&line).await?;
    write.flush().await
}
