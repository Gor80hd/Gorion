//! Движок подключения Gorion (ADR-0005): локальный вход, маршрутизатор и
//! исходящие протоколы на своём коде. Пока — локальный SOCKS5/HTTP-вход,
//! прямое подключение и Shadowsocks AEAD.

pub mod address;
pub mod error;
pub mod inbound;
pub mod outbound;
pub mod shadowsocks;

use std::net::SocketAddr;
use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::task::JoinHandle;

pub use address::TargetAddr;
pub use error::{EngineError, Result};
pub use outbound::Outbound;
pub use shadowsocks::{Method, ShadowsocksConfig};

#[derive(Debug, Clone)]
pub struct EngineConfig {
    /// Адрес локального входа; порт 0 — выбрать свободный.
    pub listen: SocketAddr,
    pub outbound: Outbound,
}

/// Работающий движок. Остановка — `stop()` или просто удаление значения.
pub struct EngineHandle {
    local_addr: SocketAddr,
    task: JoinHandle<()>,
}

impl EngineHandle {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    pub fn stop(self) {}
}

impl Drop for EngineHandle {
    fn drop(&mut self) {
        // Вместе с задачей приёма отменяются и все подключения (JoinSet).
        self.task.abort();
    }
}

pub async fn start(config: EngineConfig) -> Result<EngineHandle> {
    let listener = TcpListener::bind(config.listen).await?;
    let local_addr = listener.local_addr()?;
    let outbound = Arc::new(config.outbound);
    tracing::info!(%local_addr, "engine listening");
    let task = tokio::spawn(inbound::serve(listener, outbound));
    Ok(EngineHandle { local_addr, task })
}
