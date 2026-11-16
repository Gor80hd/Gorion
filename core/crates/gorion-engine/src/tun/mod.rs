//! Свой TUN (ADR-0005): весь трафик компьютера через выбранный сервер.
//!
//! Устройство utun, адреса и маршруты — как у sing-tun на macOS; TCP —
//! системный стек с NAT в ядро (`stack.rs`); DNS приложений — через сервер
//! по DNS-over-HTTPS (`dns.rs`). Сокеты движка к серверам привязаны к
//! физическому интерфейсу (`netbind`), чтобы не уйти в собственный туннель.
//!
//! UDP приложений — через маршрут, если он передаёт UDP (`udp.rs`), иначе
//! «порт недоступен». Пока не передаётся ICMP (ping).

pub mod dns;
pub mod nat;
pub mod packet;
pub mod stack;
pub mod udp;

#[cfg(target_os = "macos")]
mod device;
#[cfg(target_os = "macos")]
mod system;

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::Arc;

use crate::error::Result;
use crate::selector::{Selector, Traffic};

pub use dns::DohServer;

/// MTU туннеля по умолчанию, как у sing-box.
pub const DEFAULT_MTU: u32 = 9000;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TunConfig {
    pub inet4: Option<(Ipv4Addr, u8)>,
    pub inet6: Option<(Ipv6Addr, u8)>,
    pub mtu: u32,
    pub auto_route: bool,
    pub dns: DohServer,
}

/// Следующий адрес после `ip` (второй конец туннеля для NAT).
fn next(ip: IpAddr) -> IpAddr {
    match ip {
        IpAddr::V4(ip) => IpAddr::V4(Ipv4Addr::from(u32::from(ip).wrapping_add(1))),
        IpAddr::V6(ip) => IpAddr::V6(Ipv6Addr::from(u128::from(ip).wrapping_add(1))),
    }
}

fn broadcast_v4(ip: Ipv4Addr, prefix: u8) -> Ipv4Addr {
    let host_bits = u32::MAX.checked_shr(u32::from(prefix.min(32))).unwrap_or(0);
    Ipv4Addr::from(u32::from(ip) | host_bits)
}

/// Работающий туннель. `close` снимает маршруты; простое удаление тоже
/// останавливает его — маршруты уходят вместе с интерфейсом.
pub struct TunHandle {
    name: String,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    routes: Vec<IpAddr>,
}

impl std::fmt::Debug for TunHandle {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TunHandle")
            .field("name", &self.name)
            .finish_non_exhaustive()
    }
}

impl TunHandle {
    pub fn name(&self) -> &str {
        &self.name
    }

    fn stop_tasks(&mut self) {
        for task in self.tasks.drain(..) {
            task.abort();
        }
    }

    pub async fn close(mut self) {
        self.stop_tasks();
        #[cfg(target_os = "macos")]
        for gateway in std::mem::take(&mut self.routes) {
            system::delete_routes(gateway.is_ipv6()).await;
        }
        crate::netbind::reset();
    }
}

impl Drop for TunHandle {
    fn drop(&mut self) {
        self.stop_tasks();
        crate::netbind::reset();
    }
}

#[cfg(not(target_os = "macos"))]
pub async fn start(
    _config: &TunConfig,
    _selector: Arc<Selector>,
    _traffic: Arc<Traffic>,
    _server_hosts: Vec<String>,
) -> Result<TunHandle> {
    Err(crate::error::EngineError::Unsupported(
        "tun on this system".into(),
    ))
}

#[cfg(target_os = "macos")]
pub use macos::start;

#[cfg(target_os = "macos")]
mod macos {
    use std::net::SocketAddr;
    use std::time::{Duration, Instant};

    use tokio::net::{TcpListener, TcpStream};
    use tokio::task::JoinSet;

    use super::device::{Device, PREFIX};
    use super::dns::{DohClient, fit_response};
    use super::nat::SESSION_TIMEOUT;
    use super::stack::{Family, Stack, Verdict, refuse_udp};
    use super::udp::{IDLE_TIMEOUT, UdpRelay};
    use super::*;
    use crate::address::TargetAddr;
    use crate::error::EngineError;
    use crate::outbound::Outbound;

    /// Как часто проверять физический интерфейс (смена Wi-Fi на кабель).
    const INTERFACE_CHECK: Duration = Duration::from_secs(5);
    const NAT_SWEEP: Duration = Duration::from_secs(30);
    /// Сколько ждать, пока адрес IPv6 станет пригоден для слушателя.
    const V6_LISTEN_ATTEMPTS: u32 = 30;
    /// Одновременных запросов DNS, дальше — отбрасываем.
    const MAX_DNS_IN_FLIGHT: usize = 512;
    /// Очередь ответов UDP в туннель.
    const UDP_REPLIES: usize = 4096;

    pub async fn start(
        config: &TunConfig,
        selector: Arc<Selector>,
        traffic: Arc<Traffic>,
        server_hosts: Vec<String>,
    ) -> Result<TunHandle> {
        // До маршрутов: имена серверов ещё разрешаются мимо туннеля.
        crate::netbind::pin_hosts(server_hosts.iter().map(String::as_str)).await;
        let Some((interface, index)) = system::default_interface().await else {
            return Err(EngineError::Unsupported("no default interface".into()));
        };
        crate::netbind::bind_interface(Some(index));
        tracing::info!(%interface, "outbound sockets bound to interface");

        let device = Arc::new(Device::open()?);
        let name = device.name().to_owned();
        let mut handle = TunHandle {
            name: name.clone(),
            tasks: Vec::new(),
            routes: Vec::new(),
        };

        let mut v4 = None;
        if let Some((address, prefix)) = config.inet4 {
            system::configure_v4(&name, address, prefix, config.mtu).await?;
            let listener = TcpListener::bind((address, 0)).await?;
            v4 = Some((
                Family {
                    address: IpAddr::V4(address),
                    next: next(IpAddr::V4(address)),
                    broadcast: Some(IpAddr::V4(broadcast_v4(address, prefix))),
                    port: listener.local_addr()?.port(),
                },
                listener,
            ));
        }
        let mut v6 = None;
        if let Some((address, prefix)) = config.inet6 {
            system::configure_v6(&name, address, prefix).await?;
            let listener = listen_v6(address).await;
            let port = match &listener {
                Some(listener) => listener.local_addr()?.port(),
                None => 0,
            };
            v6 = Some((
                Family {
                    address: IpAddr::V6(address),
                    next: next(IpAddr::V6(address)),
                    broadcast: None,
                    port,
                },
                listener,
            ));
        }

        let stack = Arc::new(Stack::new(
            v4.as_ref().map(|(f, _)| *f),
            v6.as_ref().map(|(f, _)| *f),
            SESSION_TIMEOUT,
        ));
        let listeners = [v4.map(|(_, l)| l), v6.and_then(|(_, l)| l)];
        for listener in listeners.into_iter().flatten() {
            handle.tasks.push(tokio::spawn(accept_loop(
                listener,
                Arc::clone(&stack),
                Arc::clone(&selector),
                Arc::clone(&traffic),
            )));
        }
        let doh = Arc::new(DohClient::new(config.dns.clone(), Arc::clone(&selector)));
        let (replies, udp_replies) = tokio::sync::mpsc::channel(UDP_REPLIES);
        let udp = UdpRelay::new(
            Arc::clone(&selector),
            Arc::clone(&traffic),
            replies,
            IDLE_TIMEOUT,
        );
        handle.tasks.push(tokio::spawn(packet_loop(
            Arc::clone(&device),
            stack,
            doh,
            udp,
            udp_replies,
        )));
        handle.tasks.push(tokio::spawn(watch_interface(index)));

        if config.auto_route {
            let gateways = [
                config.inet4.map(|(a, _)| IpAddr::V4(a)),
                config.inet6.map(|(a, _)| IpAddr::V6(a)),
            ];
            for gateway in gateways.into_iter().flatten() {
                // Маршрут добавлен — значит, его надо снять при остановке.
                handle.routes.push(gateway);
                system::add_routes(gateway).await?;
            }
            system::flush_dns_cache().await;
        }
        tracing::info!(%name, mtu = config.mtu, "tun started");
        Ok(handle)
    }

    /// Новый адрес IPv6 какое-то время «предварительный» (проверка
    /// дубликатов), и слушать на нём нельзя. Без слушателя TCP по IPv6
    /// отклоняется, и приложения переходят на IPv4.
    async fn listen_v6(address: Ipv6Addr) -> Option<TcpListener> {
        for _ in 0..V6_LISTEN_ATTEMPTS {
            match TcpListener::bind((address, 0)).await {
                Ok(listener) => return Some(listener),
                Err(_) => tokio::time::sleep(Duration::from_millis(100)).await,
            }
        }
        tracing::warn!("tun: ipv6 listener unavailable, ipv6 tcp is refused");
        None
    }

    async fn watch_interface(mut current: std::num::NonZeroU32) {
        let mut tick = tokio::time::interval(INTERFACE_CHECK);
        loop {
            tick.tick().await;
            if let Some((interface, index)) = system::default_interface().await
                && index != current
            {
                tracing::info!(%interface, "default interface changed");
                crate::netbind::bind_interface(Some(index));
                current = index;
            }
        }
    }

    async fn packet_loop(
        device: Arc<Device>,
        stack: Arc<Stack>,
        doh: Arc<DohClient>,
        mut udp: UdpRelay,
        mut udp_replies: tokio::sync::mpsc::Receiver<Vec<u8>>,
    ) {
        let mut buf = vec![0u8; PREFIX + usize::from(u16::MAX)];
        let mut sweep = tokio::time::interval(NAT_SWEEP);
        let mut dns_tasks = JoinSet::new();
        loop {
            tokio::select! {
                read = device.recv(&mut buf) => {
                    let n = match read {
                        Ok(n) => n,
                        Err(error) => {
                            tracing::warn!(%error, "tun: read failed");
                            if error.raw_os_error() == Some(nix::libc::EBADF) {
                                return;
                            }
                            tokio::time::sleep(Duration::from_millis(10)).await;
                            continue;
                        }
                    };
                    if n <= PREFIX {
                        continue;
                    }
                    let packet = &mut buf[PREFIX..n];
                    let verdict = match stack.process(packet, Instant::now()) {
                        Verdict::Udp { client, server, payload } => {
                            if udp.send(client, server, payload) {
                                Verdict::Drop
                            } else {
                                refuse_udp(packet)
                            }
                        }
                        other => other,
                    };
                    let sent = match verdict {
                        Verdict::Forward(end) => device.send(&packet[..end]).await,
                        Verdict::Reply(reply) => device.send(&reply).await,
                        Verdict::Dns { client, server, query } => {
                            if dns_tasks.len() < MAX_DNS_IN_FLIGHT {
                                dns_tasks.spawn(answer_dns(
                                    Arc::clone(&device),
                                    Arc::clone(&doh),
                                    client,
                                    server,
                                    query,
                                ));
                            }
                            Ok(())
                        }
                        Verdict::Udp { .. } | Verdict::Drop => Ok(()),
                    };
                    if let Err(error) = sent {
                        tracing::debug!(%error, "tun: write failed");
                    }
                }
                Some(reply) = udp_replies.recv() => {
                    if let Err(error) = device.send(&reply).await {
                        tracing::debug!(%error, "tun: udp reply failed");
                    }
                }
                _ = sweep.tick() => {
                    stack.expire(Instant::now());
                    udp.sweep();
                }
                () = udp.reap() => {}
                Some(_) = dns_tasks.join_next(), if !dns_tasks.is_empty() => {}
            }
        }
    }

    async fn answer_dns(
        device: Arc<Device>,
        doh: Arc<DohClient>,
        client: SocketAddr,
        server: SocketAddr,
        query: Vec<u8>,
    ) {
        match doh.exchange(&query).await {
            Ok(answer) => {
                let answer = fit_response(&query, answer);
                if let Some(reply) = packet::udp(server, client, &answer)
                    && let Err(error) = device.send(&reply).await
                {
                    tracing::debug!(%error, "tun: dns reply failed");
                }
            }
            // Без ответа клиент повторит запрос сам.
            Err(error) => tracing::debug!(%error, "tun: dns query failed"),
        }
    }

    async fn accept_loop(
        listener: TcpListener,
        stack: Arc<Stack>,
        selector: Arc<Selector>,
        traffic: Arc<Traffic>,
    ) {
        let mut tasks = JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => match accepted {
                    Ok((stream, peer)) => {
                        let Some(session) = stack.session(peer.port(), Instant::now()) else {
                            continue;
                        };
                        let mut changed = selector.subscribe();
                        let outbound = selector.current();
                        let traffic = Arc::clone(&traffic);
                        tasks.spawn(async move {
                            tokio::select! {
                                result = handle(stream, &outbound, session.destination, &traffic) => {
                                    if let Err(error) = result {
                                        tracing::debug!(%error, "tun connection ended with error");
                                    }
                                }
                                // Сервер сменили: подключение через старый рвётся.
                                _ = changed.changed() => {}
                            }
                        });
                    }
                    Err(error) => {
                        tracing::warn!(%error, "tun: accept failed");
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                },
                Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
            }
        }
    }

    async fn handle(
        stream: TcpStream,
        outbound: &Outbound,
        destination: SocketAddr,
        traffic: &Traffic,
    ) -> Result<()> {
        stream.set_nodelay(true)?;
        // Без разбора SNI: цель — адрес, который приложение получило от DNS.
        let connection = outbound.connect(&TargetAddr::Ip(destination), &[]).await?;
        connection.relay(stream, traffic).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn addresses_of_the_managed_tunnel() {
        let v4: Ipv4Addr = "172.19.0.1".parse().unwrap();
        assert_eq!(
            next(IpAddr::V4(v4)),
            "172.19.0.2".parse::<IpAddr>().unwrap()
        );
        assert_eq!(
            broadcast_v4(v4, 30),
            "172.19.0.3".parse::<Ipv4Addr>().unwrap()
        );
        let v6: IpAddr = "fdfe:dcba:9876::1".parse().unwrap();
        assert_eq!(next(v6), "fdfe:dcba:9876::2".parse::<IpAddr>().unwrap());
    }

    /// Без root utun не открыть: запуск честно падает, а не делает вид.
    #[cfg(target_os = "macos")]
    #[tokio::test]
    async fn opening_utun_needs_root() {
        if nix::unistd::Uid::effective().is_root() {
            return;
        }
        assert!(device::Device::open().is_err());
    }
}
