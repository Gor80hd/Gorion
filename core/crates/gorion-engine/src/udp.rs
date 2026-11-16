//! UDP через выбранный маршрут: напрямую или через Hysteria2. Остальные
//! протоколы движка UDP пока не передают — вход отвечает отказом, и
//! приложения переходят на TCP (QUIC → HTTPS).

use std::net::SocketAddr;
use std::sync::Arc;

use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinSet;

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::hysteria2::{self, Hysteria2Udp};
use crate::outbound::Outbound;

/// Наибольшая датаграмма UDP.
const MAX_DATAGRAM: usize = 65_535;
/// Очередь принятых пакетов прямой сессии; дальше — отбрасываем.
const DIRECT_QUEUE: usize = 1024;

/// UDP-сессия одного клиента: пакеты к любым адресам и ответы от них.
pub enum UdpSession {
    Direct(DirectUdp),
    Hysteria2(Box<Hysteria2Udp>),
}

impl Outbound {
    /// Умеет ли маршрут передавать UDP.
    pub fn supports_udp(&self) -> bool {
        match self {
            Self::Direct => true,
            Self::Hysteria2(config) => config.udp,
            _ => false,
        }
    }

    pub async fn udp(&self) -> Result<UdpSession> {
        match self {
            Self::Direct => Ok(UdpSession::Direct(DirectUdp::new())),
            Self::Hysteria2(config) => Ok(UdpSession::Hysteria2(Box::new(
                hysteria2::udp(config).await?,
            ))),
            _ => Err(EngineError::Unsupported("udp over this protocol".into())),
        }
    }
}

impl UdpSession {
    pub async fn send(&mut self, target: &TargetAddr, data: &[u8]) -> Result<()> {
        match self {
            Self::Direct(direct) => direct.send(target, data).await,
            Self::Hysteria2(hy) => hy.send(target, data).await,
        }
    }

    /// Следующий ответ и его отправитель; `None` — сессия закончилась.
    /// Отмена безопасна: пакет не теряется.
    pub async fn recv(&mut self) -> Option<(Vec<u8>, TargetAddr)> {
        match self {
            Self::Direct(direct) => direct
                .incoming
                .recv()
                .await
                .map(|(data, from)| (data, TargetAddr::Ip(from))),
            Self::Hysteria2(hy) => loop {
                let (data, from) = hy.recv().await?;
                // Адрес приходит строкой `host:port`.
                if let Ok(from) = TargetAddr::parse_authority(&from, 0) {
                    break Some((data, from));
                }
            },
        }
    }
}

/// Прямой UDP: свой сокет на семейство адресов (и отдельный для петли —
/// в режиме TUN остальные привязаны к физическому интерфейсу).
pub struct DirectUdp {
    sockets: Vec<((bool, bool), Arc<UdpSocket>)>,
    sender: mpsc::Sender<(Vec<u8>, SocketAddr)>,
    incoming: mpsc::Receiver<(Vec<u8>, SocketAddr)>,
    readers: JoinSet<()>,
}

impl DirectUdp {
    fn new() -> Self {
        let (sender, incoming) = mpsc::channel(DIRECT_QUEUE);
        Self {
            sockets: Vec::new(),
            sender,
            incoming,
            readers: JoinSet::new(),
        }
    }

    async fn send(&mut self, target: &TargetAddr, data: &[u8]) -> Result<()> {
        let addr = crate::netbind::resolve(target)
            .await?
            .into_iter()
            .next()
            .ok_or(EngineError::BadAddress)?;
        let key = (addr.is_ipv4(), addr.ip().is_loopback());
        let socket = match self.sockets.iter().find(|(k, _)| *k == key) {
            Some((_, socket)) => Arc::clone(socket),
            None => {
                let socket = Arc::new(UdpSocket::from_std(crate::netbind::udp_socket(addr)?)?);
                self.readers
                    .spawn(read_direct(Arc::clone(&socket), self.sender.clone()));
                self.sockets.push((key, Arc::clone(&socket)));
                socket
            }
        };
        socket.send_to(data, addr).await?;
        Ok(())
    }
}

async fn read_direct(socket: Arc<UdpSocket>, sender: mpsc::Sender<(Vec<u8>, SocketAddr)>) {
    let mut buf = vec![0u8; MAX_DATAGRAM];
    while let Ok((n, from)) = socket.recv_from(&mut buf).await {
        if sender.is_closed() {
            return;
        }
        let _ = sender.try_send((buf[..n].to_vec(), from));
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[tokio::test]
    async fn direct_session_reaches_any_address() {
        let echo = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let echo_addr = echo.local_addr().unwrap();
        tokio::spawn(async move {
            let mut buf = [0u8; 1500];
            while let Ok((n, from)) = echo.recv_from(&mut buf).await {
                echo.send_to(&buf[..n], from).await.unwrap();
            }
        });
        assert!(Outbound::Direct.supports_udp());
        let mut session = Outbound::Direct.udp().await.unwrap();
        session
            .send(&TargetAddr::Ip(echo_addr), b"ping")
            .await
            .unwrap();
        let (data, from) = session.recv().await.unwrap();
        assert_eq!(data, b"ping");
        assert_eq!(from, TargetAddr::Ip(echo_addr));
    }
}
