//! Куда идут исходящие сокеты движка. В режиме TUN маршруты системы ведут
//! весь трафик в туннель, поэтому подключения к серверам привязываются к
//! физическому интерфейсу (`IP_BOUND_IF`, как `auto_detect_interface` в
//! sing-box), а имена серверов разрешаются заранее — пока DNS системы ещё
//! не идёт через туннель, которому эти серверы и нужны.

use std::collections::HashMap;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::num::NonZeroU32;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{LazyLock, RwLock};

use tokio::net::TcpStream;

use crate::address::TargetAddr;

/// Индекс физического интерфейса; 0 — сокеты не привязываются.
static INTERFACE: AtomicU32 = AtomicU32::new(0);
/// Адреса серверов, разрешённые до подъёма туннеля.
static PINNED: LazyLock<RwLock<HashMap<String, Vec<IpAddr>>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

pub fn bind_interface(index: Option<NonZeroU32>) {
    INTERFACE.store(index.map_or(0, NonZeroU32::get), Ordering::Relaxed);
}

pub fn bound_interface() -> Option<NonZeroU32> {
    NonZeroU32::new(INTERFACE.load(Ordering::Relaxed))
}

/// Запоминает адреса имени: `connect` возьмёт их вместо резолвера.
pub fn pin(host: &str, addresses: Vec<IpAddr>) {
    let mut pinned = PINNED.write().unwrap_or_else(|p| p.into_inner());
    pinned.insert(host.to_ascii_lowercase(), addresses);
}

fn pinned(host: &str) -> Option<Vec<IpAddr>> {
    let pinned = PINNED.read().unwrap_or_else(|p| p.into_inner());
    pinned.get(host).cloned()
}

/// Туннель снят: обычные сокеты и обычный резолвер.
pub fn reset() {
    bind_interface(None);
    PINNED.write().unwrap_or_else(|p| p.into_inner()).clear();
}

/// Разрешает имена заранее; неразрешённые останутся системному резолверу.
pub async fn pin_hosts<'a>(hosts: impl IntoIterator<Item = &'a str>) {
    for host in hosts {
        match tokio::net::lookup_host((host, 0)).await {
            Ok(found) => {
                let mut addresses: Vec<IpAddr> = Vec::new();
                for addr in found {
                    if !addresses.contains(&addr.ip()) {
                        addresses.push(addr.ip());
                    }
                }
                if !addresses.is_empty() {
                    pin(host, addresses);
                }
            }
            // Имя сервера — не для журнала.
            Err(error) => tracing::warn!(%error, "server name did not resolve before tun"),
        }
    }
}

/// TCP-подключение: адреса по очереди, пока одно не удастся.
pub async fn connect(target: &TargetAddr) -> io::Result<TcpStream> {
    let addresses: Vec<SocketAddr> = match target {
        TargetAddr::Ip(addr) => vec![*addr],
        TargetAddr::Domain(host, port) => match pinned(host) {
            Some(ips) => ips
                .into_iter()
                .map(|ip| SocketAddr::new(ip, *port))
                .collect(),
            None => tokio::net::lookup_host((host.as_str(), *port))
                .await?
                .collect(),
        },
    };
    let mut last = None;
    for addr in addresses {
        match connect_addr(addr).await {
            Ok(stream) => return Ok(stream),
            Err(error) => last = Some(error),
        }
    }
    Err(last.unwrap_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no addresses")))
}

async fn connect_addr(addr: SocketAddr) -> io::Result<TcpStream> {
    // Петля не уходит в туннель и к интерфейсу не привязывается.
    match bound_interface().filter(|_| !addr.ip().is_loopback()) {
        Some(interface) => connect_bound(addr, interface).await,
        None => TcpStream::connect(addr).await,
    }
}

#[cfg(any(target_os = "macos", target_os = "linux"))]
async fn connect_bound(addr: SocketAddr, interface: NonZeroU32) -> io::Result<TcpStream> {
    use socket2::{Domain, Protocol, Socket, Type};
    let socket = Socket::new(Domain::for_address(addr), Type::STREAM, Some(Protocol::TCP))?;
    if addr.is_ipv4() {
        socket.bind_device_by_index_v4(Some(interface))?;
    } else {
        socket.bind_device_by_index_v6(Some(interface))?;
    }
    socket.set_nonblocking(true)?;
    let socket = tokio::net::TcpSocket::from_std_stream(socket.into());
    socket.connect(addr).await
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
async fn connect_bound(addr: SocketAddr, _interface: NonZeroU32) -> io::Result<TcpStream> {
    TcpStream::connect(addr).await
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[tokio::test]
    async fn pinned_names_skip_the_resolver() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        // Имя, которого нет ни в одном DNS: сработает только закреплённый адрес.
        pin("pinned.gorion.invalid", vec!["127.0.0.1".parse().unwrap()]);
        let target = TargetAddr::Domain("pinned.gorion.invalid".into(), port);
        let stream = connect(&target).await.unwrap();
        assert_eq!(stream.peer_addr().unwrap().port(), port);
    }
}
