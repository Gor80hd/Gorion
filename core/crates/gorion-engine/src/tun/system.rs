//! Настройка системы для туннеля на macOS: адреса и MTU интерфейса,
//! маршруты, физический интерфейс по умолчанию. Через системные утилиты по
//! абсолютным путям — без своего unsafe и без зависимости от PATH.
//!
//! Маршруты — как `auto_route` sing-tun на darwin: восемь поддиапазонов
//! вместо 0.0.0.0/0 (маршрут по умолчанию системы остаётся, и его видно для
//! привязки сокетов), шлюз — адрес самого туннеля. Маршруты живут, пока
//! жив интерфейс: закрытие utun (в том числе при падении процесса)
//! убирает их вместе с ним.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::num::NonZeroU32;
use std::process::Stdio;

use tokio::process::Command;

const IFCONFIG: &str = "/sbin/ifconfig";
const ROUTE: &str = "/sbin/route";
const DSCACHEUTIL: &str = "/usr/bin/dscacheutil";

async fn run(program: &str, args: &[&str]) -> io::Result<String> {
    let output = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .output()
        .await?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(io::Error::other(format!(
            "{program}: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )))
    }
}

fn mask_v4(prefix: u8) -> Ipv4Addr {
    let bits = u32::MAX
        .checked_shl(32 - u32::from(prefix.min(32)))
        .unwrap_or(0);
    Ipv4Addr::from(bits)
}

/// Адрес IPv4 точка-точка (адрес и адрес назначения совпадают, как в
/// sing-tun), MTU и «включить».
pub async fn configure_v4(name: &str, address: Ipv4Addr, prefix: u8, mtu: u32) -> io::Result<()> {
    let address = address.to_string();
    let mask = mask_v4(prefix).to_string();
    let mtu = mtu.to_string();
    run(
        IFCONFIG,
        &[
            name, "inet", &address, &address, "netmask", &mask, "mtu", &mtu, "up",
        ],
    )
    .await
    .map(|_| ())
}

pub async fn configure_v6(name: &str, address: Ipv6Addr, prefix: u8) -> io::Result<()> {
    run(
        IFCONFIG,
        &[
            name,
            "inet6",
            &address.to_string(),
            "prefixlen",
            &prefix.to_string(),
        ],
    )
    .await
    .map(|_| ())
}

/// Восемь поддиапазонов на всё адресное пространство семейства.
pub fn route_ranges(v6: bool) -> Vec<String> {
    (0..8u32)
        .map(|i| {
            let first = 1u32 << i;
            let prefix = 8 - i;
            if v6 {
                format!("{:x}::/{prefix}", first << 8)
            } else {
                format!("{first}.0.0.0/{prefix}")
            }
        })
        .collect()
}

async fn add_route(range: &str, gateway: &str, family: &str) -> io::Result<()> {
    let add = ["-n", "add", family, "-net", range, gateway];
    if run(ROUTE, &add).await.is_ok() {
        return Ok(());
    }
    // Такой маршрут уже есть (например, от прошлого запуска): заменить.
    let _ = run(ROUTE, &["-n", "delete", family, "-net", range]).await;
    run(ROUTE, &add).await.map(|_| ())
}

/// Ведёт весь трафик семейства в туннель через адрес `gateway`.
pub async fn add_routes(gateway: IpAddr) -> io::Result<()> {
    let (family, v6) = match gateway {
        IpAddr::V4(_) => ("-inet", false),
        IpAddr::V6(_) => ("-inet6", true),
    };
    let gateway = gateway.to_string();
    for range in route_ranges(v6) {
        add_route(&range, &gateway, family).await?;
    }
    Ok(())
}

/// Снимает маршруты туннеля (при обычной остановке; при падении их убирает
/// закрытие интерфейса).
pub async fn delete_routes(v6: bool) {
    let family = if v6 { "-inet6" } else { "-inet" };
    for range in route_ranges(v6) {
        let _ = run(ROUTE, &["-n", "delete", family, "-net", &range]).await;
    }
}

/// Кэш DNS системы помнит ответы, полученные мимо туннеля.
pub async fn flush_dns_cache() {
    let _ = run(DSCACHEUTIL, &["-flushcache"]).await;
}

/// Имя интерфейса из вывода `route get`.
fn parse_interface(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let value = line.trim().strip_prefix("interface:")?.trim();
        (!value.is_empty()).then(|| value.to_owned())
    })
}

/// Физический интерфейс маршрута по умолчанию (`en0` и т. п.). Туннель не
/// занимает 0.0.0.0/0, поэтому ответ верен и при поднятом туннеле.
pub async fn default_interface() -> Option<(String, NonZeroU32)> {
    for family in ["-inet", "-inet6"] {
        let Ok(output) = run(ROUTE, &["-n", "get", family, "default"]).await else {
            continue;
        };
        let Some(name) = parse_interface(&output) else {
            continue;
        };
        if name.starts_with("utun") {
            continue;
        }
        if let Ok(index) = nix::net::if_::if_nametoindex(name.as_str())
            && let Some(index) = NonZeroU32::new(index)
        {
            return Some((name, index));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn ranges_cover_everything_but_zero_slash_eight() {
        assert_eq!(
            route_ranges(false),
            [
                "1.0.0.0/8",
                "2.0.0.0/7",
                "4.0.0.0/6",
                "8.0.0.0/5",
                "16.0.0.0/4",
                "32.0.0.0/3",
                "64.0.0.0/2",
                "128.0.0.0/1"
            ]
        );
        assert_eq!(route_ranges(true)[0], "100::/8");
        assert_eq!(route_ranges(true)[7], "8000::/1");
        assert_eq!(mask_v4(30), Ipv4Addr::new(255, 255, 255, 252));
        assert_eq!(mask_v4(0), Ipv4Addr::UNSPECIFIED);
    }

    #[test]
    fn reads_interface_from_route_get() {
        let output = "   route to: default\ndestination: default\n       mask: default\n    gateway: 192.168.1.1\n  interface: en0\n      flags: <UP,GATEWAY,DONE,STATIC,PRCLONING>\n";
        assert_eq!(parse_interface(output).as_deref(), Some("en0"));
        assert_eq!(parse_interface("route: not in table"), None);
    }
}
