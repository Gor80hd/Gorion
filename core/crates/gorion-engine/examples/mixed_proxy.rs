//! Локальный прокси SOCKS5/HTTP на движке Gorion — для проверок на стенде.
//!
//! GORION_SS_SERVER=host:port GORION_SS_METHOD=aes-128-gcm GORION_SS_PASSWORD=… \
//!   cargo run -p gorion-engine --example mixed_proxy -- 127.0.0.1:2080
//!
//! VLESS (TCP или REALITY, с Vision или без) — ссылкой из подписки:
//!
//!   read -rs GORION_VLESS && export GORION_VLESS   # вставить vless://…
//!   cargo run -p gorion-engine --example mixed_proxy
//!   curl -x socks5h://127.0.0.1:2080 https://cloudflare.com/cdn-cgi/trace
//!
//! Без настроек подключается напрямую. Пароль и ссылка берутся только из
//! окружения, чтобы не попасть в историю команд и журнал (правило 6).

use base64::Engine as _;
use gorion_engine::{
    EngineConfig, Flow, Method, Outbound, RealityConfig, Security, ShadowsocksConfig, TargetAddr,
    VlessConfig,
};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listen = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "127.0.0.1:2080".into())
        .parse()?;
    let outbound = if let Ok(link) = std::env::var("GORION_VLESS") {
        Outbound::Vless(Box::new(parse_vless(link.trim())?))
    } else {
        match std::env::var("GORION_SS_SERVER") {
            Ok(server) => {
                let method = Method::parse(
                    &std::env::var("GORION_SS_METHOD").unwrap_or_else(|_| "aes-128-gcm".into()),
                )?;
                let password = std::env::var("GORION_SS_PASSWORD")?;
                Outbound::Shadowsocks(ShadowsocksConfig::new(
                    TargetAddr::parse_authority(&server, 8388)?,
                    method,
                    &password,
                ))
            }
            Err(_) => Outbound::Direct,
        }
    };
    let engine = gorion_engine::start(EngineConfig { listen, outbound }).await?;
    println!("listening on {}", engine.local_addr());
    tokio::signal::ctrl_c().await?;
    Ok(())
}

/// Разбор ссылки `vless://uuid@host:port?security=…&sni=…&pbk=…&sid=…&flow=…`.
/// В приложении ссылки разбирает ядро; здесь — только для проверки.
fn parse_vless(link: &str) -> Result<VlessConfig, Box<dyn std::error::Error>> {
    let rest = link.strip_prefix("vless://").ok_or("not a vless:// link")?;
    let rest = rest.split('#').next().unwrap_or_default();
    let (main, query) = rest.split_once('?').unwrap_or((rest, ""));
    let (user, authority) = main.rsplit_once('@').ok_or("missing user id")?;
    let authority = authority.trim_end_matches('/');
    let param = |name: &str| {
        query
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .find(|(key, _)| *key == name)
            .map(|(_, value)| percent_decode(value))
    };
    let transport = param("type").unwrap_or_else(|| "tcp".into());
    if !matches!(transport.as_str(), "tcp" | "raw") {
        return Err(format!("transport {transport} is not supported yet").into());
    }
    let security = match param("security").as_deref().unwrap_or("none") {
        "none" | "" => Security::None,
        "reality" => {
            let key = base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(param("pbk").ok_or("missing pbk")?.trim_end_matches('='))?;
            let key: [u8; 32] = key.try_into().map_err(|_| "pbk must be 32 bytes")?;
            Security::Reality(RealityConfig::new(
                param("sni").ok_or("missing sni")?,
                key,
                &param("sid").unwrap_or_default(),
            )?)
        }
        other => return Err(format!("security {other} is not supported yet").into()),
    };
    let flow = Flow::parse(&param("flow").unwrap_or_default())?;
    Ok(VlessConfig::new(
        TargetAddr::parse_authority(authority, 443)?,
        &percent_decode(user),
        flow,
        security,
    ))
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(byte) = value
                .get(i + 1..i + 3)
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            out.push(byte);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}
