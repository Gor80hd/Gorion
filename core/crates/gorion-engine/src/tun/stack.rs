//! Системный стек (как `stack: system` в sing-tun): TCP приложений не
//! разбирается движком, а заворачивается в ядро. Сегмент от приложения к
//! цели D перезаписывается в сегмент от второго адреса туннеля (порт NAT) к
//! нашему слушателю; ответы слушателя — обратно, от D к приложению. Ядро
//! само держит TCP с обеих сторон, движку остаётся принятый сокет и
//! настоящая цель из таблицы NAT.
//!
//! UDP: запросы на порт 53 уходят в DNS движка, остальное — пересылке
//! UDP (`udp.rs`), а если маршрут UDP не передаёт, — «порт недоступен».

use std::net::{IpAddr, SocketAddr};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::dns;
use super::nat::{Nat, Session};
use super::packet::{self, PROTO_TCP, PROTO_UDP};

const DNS_PORT: u16 = 53;

/// Адреса одного семейства в туннеле.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Family {
    /// Адрес интерфейса; на нём слушает движок.
    pub address: IpAddr,
    /// Следующий адрес: от его имени приходят перезаписанные сегменты.
    pub next: IpAddr,
    /// Широковещательный адрес подсети (только IPv4).
    pub broadcast: Option<IpAddr>,
    /// Порт слушателя; 0 — слушателя нет, TCP этого семейства отклоняется.
    pub port: u16,
}

/// Что сделать с прочитанным пакетом.
#[derive(Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Пакет перезаписан на месте: вернуть в систему первые `n` байт.
    Forward(usize),
    /// Ответить своим пакетом (RST, ICMP).
    Reply(Vec<u8>),
    /// Запрос DNS от `client` к `server`.
    Dns {
        client: SocketAddr,
        server: SocketAddr,
        query: Vec<u8>,
    },
    /// Датаграмма UDP от `client` к `server`.
    Udp {
        client: SocketAddr,
        server: SocketAddr,
        payload: Vec<u8>,
    },
    Drop,
}

#[derive(Debug)]
pub struct Stack {
    v4: Option<Family>,
    v6: Option<Family>,
    nat: Mutex<Nat>,
}

impl Stack {
    pub fn new(v4: Option<Family>, v6: Option<Family>, session_timeout: Duration) -> Self {
        Self {
            v4,
            v6,
            nat: Mutex::new(Nat::new(session_timeout)),
        }
    }

    fn nat(&self) -> std::sync::MutexGuard<'_, Nat> {
        self.nat.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// Поток принятого слушателем подключения (по порту собеседника).
    pub fn session(&self, nat_port: u16, now: Instant) -> Option<Session> {
        self.nat().lookup_back(nat_port, now)
    }

    pub fn expire(&self, now: Instant) {
        self.nat().expire(now);
    }

    pub fn process(&self, packet: &mut [u8], now: Instant) -> Verdict {
        let Some(header) = packet::parse(packet) else {
            return Verdict::Drop;
        };
        let family = if header.source.is_ipv4() {
            self.v4
        } else {
            self.v6
        };
        let Some(family) = family else {
            return Verdict::Drop;
        };
        if !packet::is_routable(header.destination) || Some(header.destination) == family.broadcast
        {
            return Verdict::Drop;
        }
        let Some((source_port, destination_port)) = header.ports(packet) else {
            return Verdict::Drop;
        };
        let source = SocketAddr::new(header.source, source_port);
        let destination = SocketAddr::new(header.destination, destination_port);
        match header.protocol {
            PROTO_TCP => {
                if family.port != 0 && header.source == family.address && source_port == family.port
                {
                    // Ответ нашего слушателя приложению.
                    let Some(session) = self.nat().lookup_back(destination_port, now) else {
                        return Verdict::Drop;
                    };
                    return if packet::rewrite_tcp(
                        packet,
                        &header,
                        session.destination,
                        session.source,
                    ) {
                        Verdict::Forward(header.end)
                    } else {
                        Verdict::Drop
                    };
                }
                let reset =
                    || packet::tcp_reset(packet, &header).map_or(Verdict::Drop, Verdict::Reply);
                if family.port == 0 {
                    return reset();
                }
                let Some(nat_port) = self.nat().lookup(source, destination, now) else {
                    return reset();
                };
                let from = SocketAddr::new(family.next, nat_port);
                let to = SocketAddr::new(family.address, family.port);
                if packet::rewrite_tcp(packet, &header, from, to) {
                    Verdict::Forward(header.end)
                } else {
                    Verdict::Drop
                }
            }
            PROTO_UDP => {
                let payload = header.udp_payload(packet).unwrap_or_default();
                if destination_port == DNS_PORT && dns::is_query(payload) {
                    return Verdict::Dns {
                        client: source,
                        server: destination,
                        query: payload.to_vec(),
                    };
                }
                Verdict::Udp {
                    client: source,
                    server: destination,
                    payload: payload.to_vec(),
                }
            }
            _ => Verdict::Drop,
        }
    }
}

/// «Порт недоступен» в ответ на датаграмму UDP, которую некуда передать.
pub fn refuse_udp(packet: &[u8]) -> Verdict {
    packet::parse(packet)
        .and_then(|header| packet::port_unreachable(packet, &header))
        .map_or(Verdict::Drop, Verdict::Reply)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::tun::nat::SESSION_TIMEOUT;
    use crate::tun::packet::tests::{checksums_valid, tcp_packet};

    fn addr(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    fn stack(v6_port: u16) -> Stack {
        Stack::new(
            Some(Family {
                address: "172.19.0.1".parse().unwrap(),
                next: "172.19.0.2".parse().unwrap(),
                broadcast: Some("172.19.0.3".parse().unwrap()),
                port: 41000,
            }),
            Some(Family {
                address: "fdfe:dcba:9876::1".parse().unwrap(),
                next: "fdfe:dcba:9876::2".parse().unwrap(),
                broadcast: None,
                port: v6_port,
            }),
            SESSION_TIMEOUT,
        )
    }

    #[test]
    fn tcp_goes_to_the_listener_and_back() {
        let stack = stack(42000);
        let now = Instant::now();
        let app = addr("172.19.0.1:51000");
        let site = addr("93.184.216.34:443");
        let mut syn = tcp_packet(app, site, 0x02, 1, 0, &[]);
        let Verdict::Forward(end) = stack.process(&mut syn, now) else {
            panic!("syn must be forwarded");
        };
        let header = packet::parse(&syn[..end]).unwrap();
        assert_eq!(header.destination, "172.19.0.1".parse::<IpAddr>().unwrap());
        assert_eq!(header.source, "172.19.0.2".parse::<IpAddr>().unwrap());
        let (nat_port, listener_port) = header.ports(&syn).unwrap();
        assert_eq!(listener_port, 41000);
        assert!(checksums_valid(&syn));
        // Принятое подключение узнаёт настоящую цель.
        assert_eq!(stack.session(nat_port, now).unwrap().destination, site);

        // Ответ слушателя возвращается приложению от имени сайта.
        let mut reply = tcp_packet(
            addr("172.19.0.1:41000"),
            SocketAddr::new("172.19.0.2".parse().unwrap(), nat_port),
            0x12,
            9,
            2,
            &[],
        );
        assert!(matches!(
            stack.process(&mut reply, now),
            Verdict::Forward(_)
        ));
        let header = packet::parse(&reply).unwrap();
        assert_eq!(SocketAddr::new(header.source, 443), site);
        assert_eq!(header.ports(&reply), Some((443, 51000)));
        assert_eq!(header.destination, app.ip());
        assert!(checksums_valid(&reply));

        // Ответ для неизвестного порта NAT отбрасывается.
        let mut stray = tcp_packet(
            addr("172.19.0.1:41000"),
            addr("172.19.0.2:9"),
            0x10,
            0,
            0,
            &[],
        );
        assert_eq!(stack.process(&mut stray, now), Verdict::Drop);
    }

    #[test]
    fn ipv6_without_listener_is_reset() {
        let stack = stack(0);
        let mut syn = tcp_packet(
            addr("[fdfe:dcba:9876::1]:5000"),
            addr("[2606:4700::1]:443"),
            0x02,
            1,
            0,
            &[],
        );
        let Verdict::Reply(reset) = stack.process(&mut syn, Instant::now()) else {
            panic!("expected RST");
        };
        assert!(checksums_valid(&reset));
    }

    #[test]
    fn dns_is_hijacked_other_udp_relayed_and_noise_dropped() {
        let stack = stack(42000);
        let now = Instant::now();
        let query = crate::tun::dns::tests::query("example.com", None);
        let client = addr("172.19.0.1:6000");
        let mut packet = packet::udp(client, addr("8.8.8.8:53"), &query).unwrap();
        // UDP-пакет строится «от сервера»: здесь он идёт от приложения.
        assert_eq!(
            stack.process(&mut packet, now),
            Verdict::Dns {
                client,
                server: addr("8.8.8.8:53"),
                query: query.clone()
            }
        );
        let mut quic = packet::udp(client, addr("142.250.1.1:443"), b"quic").unwrap();
        assert_eq!(
            stack.process(&mut quic, now),
            Verdict::Udp {
                client,
                server: addr("142.250.1.1:443"),
                payload: b"quic".to_vec()
            }
        );
        // Маршрут без UDP — «порт недоступен».
        let Verdict::Reply(refused) = refuse_udp(&quic) else {
            panic!("expected ICMP");
        };
        assert!(checksums_valid(&refused));
        let mut mdns = packet::udp(client, addr("224.0.0.251:5353"), b"x").unwrap();
        assert_eq!(stack.process(&mut mdns, now), Verdict::Drop);
        let mut broadcast = packet::udp(client, addr("172.19.0.3:9"), b"x").unwrap();
        assert_eq!(stack.process(&mut broadcast, now), Verdict::Drop);
    }
}
