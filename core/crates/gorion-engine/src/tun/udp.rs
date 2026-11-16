//! UDP приложений через выбранный маршрут. Каждому сокету приложения
//! (адрес и порт источника) — своя UDP-сессия маршрута: пакеты к любым
//! адресам и ответы от них (full cone, как `udp_nat` sing-box). Ответы
//! становятся пакетами туннеля и уходят в `replies`.
//!
//! Поток закрывается после паузы без пакетов, при смене сервера и при
//! остановке туннеля (задачи живут в `JoinSet` владельца).

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::mpsc;
use tokio::task::JoinSet;

use super::packet;
use crate::address::TargetAddr;
use crate::selector::{Selector, Traffic};

/// Пауза, после которой поток закрывается (UDP-таймаут sing-box).
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(5 * 60);
/// Потоков одновременно; новые сверх — отбрасываются.
const MAX_FLOWS: usize = 4096;
/// Очередь пакетов от приложения в один поток.
const FLOW_QUEUE: usize = 256;

pub struct UdpRelay {
    selector: Arc<Selector>,
    traffic: Arc<Traffic>,
    replies: mpsc::Sender<Vec<u8>>,
    idle: Duration,
    flows: HashMap<SocketAddr, mpsc::Sender<(SocketAddr, Vec<u8>)>>,
    tasks: JoinSet<()>,
}

impl UdpRelay {
    pub fn new(
        selector: Arc<Selector>,
        traffic: Arc<Traffic>,
        replies: mpsc::Sender<Vec<u8>>,
        idle: Duration,
    ) -> Self {
        Self {
            selector,
            traffic,
            replies,
            idle,
            flows: HashMap::new(),
            tasks: JoinSet::new(),
        }
    }

    /// Передаёт датаграмму. `false` — маршрут UDP не передаёт: приложению
    /// стоит ответить «порт недоступен».
    pub fn send(&mut self, client: SocketAddr, server: SocketAddr, payload: Vec<u8>) -> bool {
        if let Some(flow) = self.flows.get(&client) {
            match flow.try_send((server, payload)) {
                // Полная очередь — пакет теряется, как в сети.
                Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => return true,
                Err(mpsc::error::TrySendError::Closed((server, payload))) => {
                    self.flows.remove(&client);
                    return self.open(client, server, payload);
                }
            }
        }
        self.open(client, server, payload)
    }

    fn open(&mut self, client: SocketAddr, server: SocketAddr, payload: Vec<u8>) -> bool {
        let outbound = self.selector.current();
        if !outbound.supports_udp() {
            return false;
        }
        if self.flows.len() >= MAX_FLOWS {
            self.sweep();
            if self.flows.len() >= MAX_FLOWS {
                return true;
            }
        }
        let (sender, incoming) = mpsc::channel(FLOW_QUEUE);
        let _ = sender.try_send((server, payload));
        self.flows.insert(client, sender);
        self.tasks.spawn(flow(
            client,
            incoming,
            Arc::clone(&self.selector),
            Arc::clone(&self.traffic),
            self.replies.clone(),
            self.idle,
        ));
        true
    }

    /// Забывает закрытые потоки.
    pub fn sweep(&mut self) {
        self.flows.retain(|_, flow| !flow.is_closed());
    }

    /// Ждёт завершения какого-нибудь потока (для `select!` владельца).
    pub async fn reap(&mut self) {
        if self.tasks.join_next().await.is_none() {
            std::future::pending::<()>().await;
        }
    }
}

async fn flow(
    client: SocketAddr,
    mut incoming: mpsc::Receiver<(SocketAddr, Vec<u8>)>,
    selector: Arc<Selector>,
    traffic: Arc<Traffic>,
    replies: mpsc::Sender<Vec<u8>>,
    idle: Duration,
) {
    let mut changed = selector.subscribe();
    let outbound = selector.current();
    let mut session = match outbound.udp().await {
        Ok(session) => session,
        Err(error) => {
            tracing::debug!(%error, "tun udp: session failed");
            return;
        }
    };
    // Последняя цель: ответ от имени, а не IP, вернётся от неё.
    let mut last = None;
    loop {
        tokio::select! {
            packet = incoming.recv() => {
                let Some((server, payload)) = packet else {
                    return;
                };
                last = Some(server);
                traffic.add_up(payload.len());
                if let Err(error) = session.send(&TargetAddr::Ip(server), &payload).await {
                    tracing::debug!(%error, "tun udp: send failed");
                }
            }
            answer = session.recv() => {
                let Some((data, from)) = answer else {
                    return;
                };
                let from = match from {
                    TargetAddr::Ip(from) => from,
                    TargetAddr::Domain(..) => match last {
                        Some(last) => last,
                        None => continue,
                    },
                };
                if let Some(reply) = packet::udp(from, client, &data) {
                    traffic.add_down(data.len());
                    let _ = replies.try_send(reply);
                }
            }
            _ = changed.changed() => return,
            () = tokio::time::sleep(idle) => return,
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::outbound::Outbound;

    #[tokio::test]
    async fn flows_relay_both_ways_and_end() {
        let echo = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let echo_addr = echo.local_addr().unwrap();
        tokio::spawn(async move {
            let mut buf = [0u8; 1500];
            while let Ok((n, from)) = echo.recv_from(&mut buf).await {
                echo.send_to(&buf[..n], from).await.unwrap();
            }
        });
        let selector = Arc::new(Selector::new(Arc::new(Outbound::Direct)));
        let (replies, mut out) = mpsc::channel(16);
        let mut relay = UdpRelay::new(
            Arc::clone(&selector),
            Arc::new(Traffic::default()),
            replies,
            Duration::from_secs(60),
        );
        let app: SocketAddr = "127.0.0.1:50000".parse().unwrap();
        assert!(relay.send(app, echo_addr, b"one".to_vec()));
        assert!(relay.send(app, echo_addr, b"two".to_vec()));
        for expected in [b"one", b"two"] {
            let reply = out.recv().await.unwrap();
            let header = packet::parse(&reply).unwrap();
            assert_eq!(header.ports(&reply), Some((echo_addr.port(), 50000)));
            assert_eq!(header.udp_payload(&reply).unwrap(), expected);
        }
        assert_eq!(relay.flows.len(), 1);

        // Смена сервера закрывает поток; маршрут без UDP — отказ.
        let tls = crate::tls::TlsConfig::new("h", true, None).unwrap();
        let trojan = crate::trojan::TrojanConfig::new(
            TargetAddr::Domain("h".into(), 1),
            "p",
            crate::vless::Security::Tls(tls),
        );
        selector.set(Arc::new(Outbound::Trojan(Box::new(trojan))));
        tokio::time::timeout(Duration::from_secs(5), relay.reap())
            .await
            .unwrap();
        assert!(!relay.send(app, echo_addr, b"three".to_vec()));
    }
}
