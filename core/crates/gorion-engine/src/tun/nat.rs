//! Таблица NAT системного стека: каждому потоку TCP приложения — свой порт
//! на втором адресе туннеля. Ядро macOS видит подключение к нашему
//! слушателю с этого порта, а движок по порту узнаёт настоящую цель.
//! Как `TCPNat` в sing-tun, но ключ — пара (источник, цель): порт,
//! повторно занятый системой под другую цель, не уведёт поток не туда.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::time::{Duration, Instant};

/// Первый порт NAT, как в sing-tun.
const FIRST_PORT: u16 = 10000;
/// Сколько живёт поток без пакетов (UDP-таймаут sing-box по умолчанию).
pub const SESSION_TIMEOUT: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Session {
    pub source: SocketAddr,
    pub destination: SocketAddr,
}

#[derive(Debug)]
struct Entry {
    session: Session,
    last_active: Instant,
}

#[derive(Debug)]
pub struct Nat {
    timeout: Duration,
    next_port: u16,
    by_flow: HashMap<(SocketAddr, SocketAddr), u16>,
    by_port: HashMap<u16, Entry>,
}

impl Nat {
    pub fn new(timeout: Duration) -> Self {
        Self {
            timeout,
            next_port: FIRST_PORT,
            by_flow: HashMap::new(),
            by_port: HashMap::new(),
        }
    }

    /// Порт NAT для потока; новый поток получает свободный порт. `None` —
    /// свободных портов нет.
    pub fn lookup(
        &mut self,
        source: SocketAddr,
        destination: SocketAddr,
        now: Instant,
    ) -> Option<u16> {
        if let Some(&port) = self.by_flow.get(&(source, destination)) {
            if let Some(entry) = self.by_port.get_mut(&port) {
                entry.last_active = now;
            }
            return Some(port);
        }
        let range = usize::from(u16::MAX - FIRST_PORT) + 1;
        for _ in 0..range {
            let port = self.next_port;
            self.next_port = if port == u16::MAX {
                FIRST_PORT
            } else {
                port + 1
            };
            if self.by_port.contains_key(&port) {
                continue;
            }
            self.by_flow.insert((source, destination), port);
            self.by_port.insert(
                port,
                Entry {
                    session: Session {
                        source,
                        destination,
                    },
                    last_active: now,
                },
            );
            return Some(port);
        }
        None
    }

    /// Поток по порту NAT — для ответов слушателя и для принятых подключений.
    pub fn lookup_back(&mut self, port: u16, now: Instant) -> Option<Session> {
        let entry = self.by_port.get_mut(&port)?;
        entry.last_active = now;
        Some(entry.session)
    }

    /// Забывает потоки, по которым давно не было пакетов.
    pub fn expire(&mut self, now: Instant) {
        let timeout = self.timeout;
        let by_flow = &mut self.by_flow;
        self.by_port.retain(|_, entry| {
            let alive = now.duration_since(entry.last_active) <= timeout;
            if !alive {
                by_flow.remove(&(entry.session.source, entry.session.destination));
            }
            alive
        });
    }

    pub fn len(&self) -> usize {
        self.by_port.len()
    }

    pub fn is_empty(&self) -> bool {
        self.by_port.is_empty()
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn addr(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    #[test]
    fn maps_flows_to_ports_and_back() {
        let now = Instant::now();
        let mut nat = Nat::new(SESSION_TIMEOUT);
        let app = addr("10.0.0.5:51000");
        let site = addr("93.184.216.34:443");
        let port = nat.lookup(app, site, now).unwrap();
        assert_eq!(port, FIRST_PORT);
        assert_eq!(nat.lookup(app, site, now), Some(port));
        let back = nat.lookup_back(port, now).unwrap();
        assert_eq!((back.source, back.destination), (app, site));
        // Тот же порт приложения к другой цели — другой поток.
        let other = nat.lookup(app, addr("1.1.1.1:443"), now).unwrap();
        assert_ne!(other, port);
        assert_eq!(nat.len(), 2);
        assert!(nat.lookup_back(9999, now).is_none());
    }

    #[test]
    fn expires_idle_flows_and_reuses_ports() {
        let start = Instant::now();
        let mut nat = Nat::new(Duration::from_secs(10));
        let site = addr("1.2.3.4:80");
        let idle = nat.lookup(addr("10.0.0.5:1"), site, start).unwrap();
        let busy = nat.lookup(addr("10.0.0.5:2"), site, start).unwrap();
        nat.lookup_back(busy, start + Duration::from_secs(8));
        nat.expire(start + Duration::from_secs(12));
        assert!(nat.lookup_back(idle, start).is_none());
        assert!(nat.lookup_back(busy, start).is_some());
        assert_eq!(nat.len(), 1);
        // Порты идут по кругу и пропускают занятые.
        nat.next_port = u16::MAX;
        let wrapped = nat.lookup(addr("10.0.0.5:3"), site, start).unwrap();
        assert_eq!(wrapped, u16::MAX);
        let after = nat.lookup(addr("10.0.0.5:4"), site, start).unwrap();
        assert_eq!(after, idle, "freed port is reused, busy one is skipped");
    }
}
