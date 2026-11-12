//! Локальный прокси SOCKS5/HTTP на движке Gorion — для проверок на стенде.
//!
//! GORION_SS_SERVER=host:port GORION_SS_METHOD=aes-128-gcm GORION_SS_PASSWORD=… \
//!   cargo run -p gorion-engine --example mixed_proxy -- 127.0.0.1:2080
//!
//! Без GORION_SS_SERVER подключается напрямую. Пароль берётся только из
//! окружения, чтобы не попасть в историю команд и журнал (правило 6).

use gorion_engine::{EngineConfig, Method, Outbound, ShadowsocksConfig, TargetAddr};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let listen = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "127.0.0.1:2080".into())
        .parse()?;
    let outbound = match std::env::var("GORION_SS_SERVER") {
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
    };
    let engine = gorion_engine::start(EngineConfig { listen, outbound }).await?;
    println!("listening on {}", engine.local_addr());
    tokio::signal::ctrl_c().await?;
    Ok(())
}
