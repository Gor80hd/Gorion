//! Обфускация salamander у Hysteria2: каждый UDP-пакет QUIC — это
//! `[соль 8][данные XOR ключ]`, где ключ — BLAKE2b-256(пароль ‖ соль),
//! повторённый по длине пакета. Эталон: hysteria `extras/obfs/salamander.go`.
//!
//! Сокет-обёртка для quinn: шифрует при отправке и снимает обфускацию при
//! приёме. Пакеты уходят по одному (без GSO), иначе соль пришлось бы
//! ставить в каждый сегмент внутри одной отправки.

use std::fmt;
use std::io::{self, IoSliceMut};
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

use blake2::digest::consts::U32;
use blake2::{Blake2b, Digest};
use quinn::udp::{RecvMeta, Transmit};
use quinn::{AsyncUdpSocket, UdpPoller};

use crate::tls::hello::random_bytes;

const SALT_LEN: usize = 8;
const KEY_LEN: usize = 32;

/// Пароль меньше этого hysteria не принимает.
pub const MIN_PASSWORD_LEN: usize = 4;

fn key(password: &[u8], salt: &[u8]) -> [u8; KEY_LEN] {
    let mut hasher = Blake2b::<U32>::new();
    hasher.update(password);
    hasher.update(salt);
    hasher.finalize().into()
}

fn xor(data: &mut [u8], key: &[u8; KEY_LEN]) {
    for (i, byte) in data.iter_mut().enumerate() {
        *byte ^= key[i % KEY_LEN];
    }
}

/// Пакет для отправки: соль и данные под ключом.
pub fn obfuscate(password: &[u8], packet: &[u8]) -> io::Result<Vec<u8>> {
    let salt: [u8; SALT_LEN] = random_bytes().map_err(|e| io::Error::other(e.to_string()))?;
    let mut out = Vec::with_capacity(SALT_LEN + packet.len());
    out.extend_from_slice(&salt);
    out.extend_from_slice(packet);
    xor(&mut out[SALT_LEN..], &key(password, &salt));
    Ok(out)
}

/// Снимает обфускацию на месте: данные сдвигаются в начало буфера.
/// Возвращает их длину; `None` — пакет короче соли.
pub fn deobfuscate(password: &[u8], packet: &mut [u8]) -> Option<usize> {
    if packet.len() <= SALT_LEN {
        return None;
    }
    let key = key(password, &packet[..SALT_LEN]);
    xor(&mut packet[SALT_LEN..], &key);
    packet.copy_within(SALT_LEN.., 0);
    Some(packet.len() - SALT_LEN)
}

pub struct Salamander {
    inner: Arc<dyn AsyncUdpSocket>,
    password: Vec<u8>,
}

impl fmt::Debug for Salamander {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Пароль обфускации — не для журнала.
        f.debug_struct("Salamander").finish_non_exhaustive()
    }
}

impl Salamander {
    pub fn new(inner: Arc<dyn AsyncUdpSocket>, password: &str) -> Self {
        Self {
            inner,
            password: password.as_bytes().to_vec(),
        }
    }
}

impl AsyncUdpSocket for Salamander {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        Arc::clone(&self.inner).create_io_poller()
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        let packet = obfuscate(&self.password, transmit.contents)?;
        self.inner.try_send(&Transmit {
            destination: transmit.destination,
            ecn: transmit.ecn,
            contents: &packet,
            segment_size: None,
            src_ip: transmit.src_ip,
        })
    }

    fn poll_recv(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        let count = match self.inner.poll_recv(cx, bufs, meta) {
            Poll::Ready(Ok(count)) => count,
            other => return other,
        };
        for (buf, meta) in bufs.iter_mut().zip(meta.iter_mut()).take(count) {
            // Склеенные системой пакеты (GRO) идут сегментами по `stride`:
            // каждый со своей солью. Очищенные сегменты пишутся подряд.
            let stride = meta.stride.max(1);
            let mut read = 0;
            let mut written = 0;
            let mut segment_len = 0;
            while read < meta.len {
                let end = (read + stride).min(meta.len);
                if let Some(len) = deobfuscate(&self.password, &mut buf[read..end]) {
                    buf.copy_within(read..read + len, written);
                    written += len;
                    segment_len = segment_len.max(len);
                }
                read = end;
            }
            meta.len = written;
            meta.stride = segment_len.max(1);
        }
        Poll::Ready(Ok(count))
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.inner.local_addr()
    }

    fn max_transmit_segments(&self) -> usize {
        1
    }

    fn max_receive_segments(&self) -> usize {
        self.inner.max_receive_segments()
    }

    fn may_fragment(&self) -> bool {
        self.inner.may_fragment()
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn round_trip_and_short_packets() {
        let packet: Vec<u8> = (0..1200u32).map(|i| (i % 251) as u8).collect();
        let mut sent = obfuscate(b"secret", &packet).unwrap();
        assert_eq!(sent.len(), packet.len() + SALT_LEN);
        assert_ne!(&sent[SALT_LEN..], &packet[..]);
        let len = deobfuscate(b"secret", &mut sent).unwrap();
        assert_eq!(&sent[..len], &packet[..]);
        assert!(deobfuscate(b"secret", &mut [0u8; SALT_LEN]).is_none());
        // Другой пароль — другие данные.
        let mut sent = obfuscate(b"secret", &packet).unwrap();
        let len = deobfuscate(b"other", &mut sent).unwrap();
        assert_ne!(&sent[..len], &packet[..]);
    }
}
