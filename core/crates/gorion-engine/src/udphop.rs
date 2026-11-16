//! Смена портов Hysteria2 (port hopping). Эталон: hysteria
//! `extras/transport/udphop/conn.go`.
//!
//! Раз в `hop_interval` клиент открывает новый UDP-сокет и шлёт пакеты на
//! случайный порт из `server_ports`; прежний сокет ещё один интервал
//! принимает запоздавшие ответы. Для quinn адрес сервера не меняется:
//! отправка идёт на текущий настоящий адрес, а у принятых пакетов адрес
//! источника подменяется на постоянный — иначе клиент quinn отбросит их
//! как пакеты от чужого собеседника.

use std::fmt;
use std::io::{self, IoSliceMut};
use std::net::SocketAddr;
use std::pin::Pin;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::task::{Context, Poll, Waker};
use std::time::Duration;

use quinn::udp::{RecvMeta, Transmit};
use quinn::{AsyncUdpSocket, Runtime as _, TokioRuntime, UdpPoller};

use crate::error::Result;
use crate::tls::hello::random_bytes;

/// Интервал по умолчанию и наименьший допустимый, как у hysteria.
pub const DEFAULT_INTERVAL: Duration = Duration::from_secs(30);
pub const MIN_INTERVAL: Duration = Duration::from_secs(5);

/// Случайный порт из диапазонов; `None` — диапазонов нет.
pub fn random_port(ranges: &[(u16, u16)]) -> Result<Option<u16>> {
    let total: u32 = ranges
        .iter()
        .map(|(from, to)| u32::from(to.saturating_sub(*from)) + 1)
        .sum();
    if total == 0 {
        return Ok(None);
    }
    let mut index = u32::from_le_bytes(random_bytes()?) % total;
    for (from, to) in ranges {
        let size = u32::from(to.saturating_sub(*from)) + 1;
        if index < size {
            // index < size ≤ 65536, а from + index ≤ to.
            return Ok(Some(from + u16::try_from(index).unwrap_or(0)));
        }
        index -= size;
    }
    Ok(None)
}

struct State {
    current: Arc<dyn AsyncUdpSocket>,
    previous: Option<Arc<dyn AsyncUdpSocket>>,
    /// Настоящий адрес сервера сейчас.
    target: SocketAddr,
    generation: u64,
    /// Кого разбудить после смены: новый сокет ещё никто не ждёт.
    waker: Option<Waker>,
}

pub struct Hopper {
    /// Адрес сервера для quinn — постоянный.
    fixed: SocketAddr,
    ports: Vec<(u16, u16)>,
    runtime: Arc<TokioRuntime>,
    state: Mutex<State>,
}

impl fmt::Debug for Hopper {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Hopper")
            .field("ports", &self.ports)
            .finish_non_exhaustive()
    }
}

impl Hopper {
    /// Сокет к `first` (адрес первого рукопожатия), дальше — смена портов
    /// раз в `interval`, пока сокет жив.
    pub fn start(
        first: SocketAddr,
        ports: Vec<(u16, u16)>,
        interval: Duration,
        runtime: Arc<TokioRuntime>,
    ) -> io::Result<Arc<Self>> {
        let current = runtime.wrap_udp_socket(crate::netbind::udp_socket(first)?)?;
        let hopper = Arc::new(Self {
            fixed: first,
            ports,
            runtime,
            state: Mutex::new(State {
                current,
                previous: None,
                target: first,
                generation: 0,
                waker: None,
            }),
        });
        let weak = Arc::downgrade(&hopper);
        tokio::spawn(hop_loop(weak, interval));
        Ok(hopper)
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }

    fn hop(&self) -> io::Result<()> {
        let port = random_port(&self.ports)
            .map_err(|e| io::Error::other(e.to_string()))?
            .unwrap_or(self.fixed.port());
        let target = SocketAddr::new(self.fixed.ip(), port);
        let socket = self
            .runtime
            .wrap_udp_socket(crate::netbind::udp_socket(target)?)?;
        let waker = {
            let mut state = self.state();
            let previous = std::mem::replace(&mut state.current, socket);
            state.previous = Some(previous);
            state.target = target;
            state.generation += 1;
            state.waker.take()
        };
        if let Some(waker) = waker {
            waker.wake();
        }
        tracing::trace!(port, "hysteria2: port hop");
        Ok(())
    }
}

async fn hop_loop(hopper: Weak<Hopper>, interval: Duration) {
    loop {
        tokio::time::sleep(interval).await;
        let Some(hopper) = hopper.upgrade() else {
            return;
        };
        // Не вышло открыть сокет — остаёмся на старом до следующего раза.
        if let Err(error) = hopper.hop() {
            tracing::debug!(%error, "hysteria2: port hop skipped");
        }
    }
}

impl AsyncUdpSocket for Hopper {
    fn create_io_poller(self: Arc<Self>) -> Pin<Box<dyn UdpPoller>> {
        Box::pin(HopPoller {
            hopper: self,
            generation: None,
            inner: None,
        })
    }

    fn try_send(&self, transmit: &Transmit) -> io::Result<()> {
        let (socket, target) = {
            let state = self.state();
            (Arc::clone(&state.current), state.target)
        };
        socket.try_send(&Transmit {
            destination: target,
            ecn: transmit.ecn,
            contents: transmit.contents,
            segment_size: transmit.segment_size,
            src_ip: transmit.src_ip,
        })
    }

    fn poll_recv(
        &self,
        cx: &mut Context,
        bufs: &mut [IoSliceMut<'_>],
        meta: &mut [RecvMeta],
    ) -> Poll<io::Result<usize>> {
        let (current, previous) = {
            let mut state = self.state();
            state.waker = Some(cx.waker().clone());
            (Arc::clone(&state.current), state.previous.clone())
        };
        let sockets = std::iter::once(current).chain(previous);
        for (index, socket) in sockets.enumerate() {
            match socket.poll_recv(cx, bufs, meta) {
                Poll::Ready(Ok(count)) => {
                    for meta in meta.iter_mut().take(count) {
                        meta.addr = self.fixed;
                    }
                    return Poll::Ready(Ok(count));
                }
                // Ошибка прежнего сокета не важна: он доживает своё.
                Poll::Ready(Err(error)) if index == 0 => return Poll::Ready(Err(error)),
                _ => {}
            }
        }
        Poll::Pending
    }

    fn local_addr(&self) -> io::Result<SocketAddr> {
        self.state().current.local_addr()
    }

    fn max_transmit_segments(&self) -> usize {
        self.state().current.max_transmit_segments()
    }

    fn max_receive_segments(&self) -> usize {
        self.state().current.max_receive_segments()
    }

    fn may_fragment(&self) -> bool {
        self.state().current.may_fragment()
    }
}

/// Готовность к записи текущего сокета: после смены — уже нового.
struct HopPoller {
    hopper: Arc<Hopper>,
    generation: Option<u64>,
    inner: Option<Pin<Box<dyn UdpPoller>>>,
}

impl fmt::Debug for HopPoller {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("HopPoller").finish_non_exhaustive()
    }
}

impl UdpPoller for HopPoller {
    fn poll_writable(mut self: Pin<&mut Self>, cx: &mut Context) -> Poll<io::Result<()>> {
        let (generation, socket) = {
            let state = self.hopper.state();
            (state.generation, Arc::clone(&state.current))
        };
        if self.generation != Some(generation) || self.inner.is_none() {
            self.inner = Some(socket.create_io_poller());
            self.generation = Some(generation);
        }
        match self.inner.as_mut() {
            Some(inner) => inner.as_mut().poll_writable(cx),
            None => Poll::Ready(Ok(())),
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn ports_come_from_ranges() {
        assert_eq!(random_port(&[]).unwrap(), None);
        let ranges = [(20000, 20002), (30000, 30000)];
        for _ in 0..50 {
            let port = random_port(&ranges).unwrap().unwrap();
            assert!((20000..=20002).contains(&port) || port == 30000, "{port}");
        }
    }

    /// После смены пакеты уходят с нового сокета на другой порт, а ответы
    /// для quinn приходят от постоянного адреса.
    #[tokio::test]
    async fn hop_moves_socket_and_port() {
        let a = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let b = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (pa, pb) = (a.local_addr().unwrap(), b.local_addr().unwrap());
        let hopper = Hopper::start(
            pa,
            vec![(pb.port(), pb.port())],
            Duration::from_secs(3600),
            Arc::new(TokioRuntime),
        )
        .unwrap();
        // Как quinn: сначала готовность к записи, потом отправка.
        let mut poller = Arc::clone(&hopper).create_io_poller();
        let mut send = async |hopper: &Hopper, data: &[u8]| {
            std::future::poll_fn(|cx| poller.as_mut().poll_writable(cx))
                .await
                .unwrap();
            hopper
                .try_send(&Transmit {
                    destination: pa,
                    ecn: None,
                    contents: data,
                    segment_size: None,
                    src_ip: None,
                })
                .unwrap();
        };
        let mut buf = [0u8; 64];
        send(&hopper, b"one").await;
        let (n, first_from) = a.recv_from(&mut buf).await.unwrap();
        assert_eq!(&buf[..n], b"one");

        hopper.hop().unwrap();
        send(&hopper, b"two").await;
        let (n, second_from) = b.recv_from(&mut buf).await.unwrap();
        assert_eq!(&buf[..n], b"two");
        assert_ne!(first_from, second_from);

        // Ответ на прежний сокет ещё принимается — от имени постоянного адреса.
        a.send_to(b"late", first_from).await.unwrap();
        b.send_to(b"new", second_from).await.unwrap();
        let mut got = Vec::new();
        for _ in 0..2 {
            let mut storage = [0u8; 64];
            let mut meta = [RecvMeta::default()];
            let count = std::future::poll_fn(|cx| {
                let mut bufs = [IoSliceMut::new(&mut storage)];
                hopper.poll_recv(cx, &mut bufs, &mut meta)
            })
            .await
            .unwrap();
            assert_eq!(count, 1);
            assert_eq!(meta[0].addr, pa);
            got.push(storage[..meta[0].len].to_vec());
        }
        got.sort();
        assert_eq!(got, [b"late".to_vec(), b"new".to_vec()]);
    }
}
