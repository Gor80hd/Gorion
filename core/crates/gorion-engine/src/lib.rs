//! Движок подключения Gorion (ADR-0005): локальный вход, маршрутизатор и
//! исходящие протоколы на своём коде. Входы — локальный SOCKS5/HTTP и TUN
//! (macOS); протоколы — Shadowsocks (AEAD и 2022), Trojan, VLESS (REALITY,
//! Vision) поверх TCP, TLS, WebSocket, HTTPUpgrade, gRPC и XHTTP; Hysteria2
//! поверх QUIC, с UDP и сменой портов.

pub mod address;
pub mod config;
pub mod control;
pub mod error;
pub mod grpc;
pub mod hysteria2;
pub mod inbound;
pub mod netbind;
pub mod outbound;
pub mod reality;
pub mod relay;
pub mod salamander;
pub mod selector;
pub mod shadowsocks;
pub mod shadowsocks2022;
pub mod stream;
pub mod tls;
pub mod transport;
pub mod trojan;
pub mod tun;
pub mod udp;
pub mod udphop;
pub mod urltest;
pub mod vision;
pub mod vless;
pub mod xhttp;

use std::net::SocketAddr;
use std::sync::Arc;

use tokio::net::TcpListener;
use tokio::task::JoinHandle;

pub use address::TargetAddr;
pub use error::{EngineError, Result};
pub use hysteria2::Hysteria2Config;
pub use outbound::Outbound;
pub use reality::RealityConfig;
pub use selector::{Selector, Traffic};
pub use shadowsocks::{Method, ShadowsocksConfig};
pub use shadowsocks2022::{Method as Ss2022Method, Ss2022Config};
pub use tls::TlsConfig;
pub use transport::{GrpcConfig, Transport, UpgradeConfig, WsConfig, XhttpConfig};
pub use trojan::TrojanConfig;
pub use vless::{Flow, Security, VlessConfig};

#[derive(Debug, Clone)]
pub struct EngineConfig {
    /// Адрес локального входа; порт 0 — выбрать свободный.
    pub listen: SocketAddr,
    pub outbound: Outbound,
}

/// Работающий движок. Остановка — `stop()` или просто удаление значения.
pub struct EngineHandle {
    local_addr: SocketAddr,
    selector: Arc<Selector>,
    traffic: Arc<Traffic>,
    task: JoinHandle<()>,
}

impl EngineHandle {
    pub fn local_addr(&self) -> SocketAddr {
        self.local_addr
    }

    /// Смена сервера для новых подключений (старые рвутся).
    pub fn selector(&self) -> &Arc<Selector> {
        &self.selector
    }

    pub fn traffic(&self) -> &Arc<Traffic> {
        &self.traffic
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
    serve(listener, Arc::new(config.outbound))
}

/// Запуск на уже открытом сокете — без гонки за порт.
pub fn serve(listener: TcpListener, outbound: Arc<Outbound>) -> Result<EngineHandle> {
    let local_addr = listener.local_addr()?;
    let selector = Arc::new(Selector::new(outbound));
    let traffic = Arc::new(Traffic::default());
    tracing::info!(%local_addr, "engine listening");
    let task = tokio::spawn(inbound::serve(
        listener,
        Arc::clone(&selector),
        Arc::clone(&traffic),
    ));
    Ok(EngineHandle {
        local_addr,
        selector,
        traffic,
        task,
    })
}

/// Движок по настройкам в формате sing-box: вход, управление, выбранный
/// сервер. Живёт, пока жив возвращённый `Running`.
pub struct Running {
    engine: EngineHandle,
    control: Option<(SocketAddr, JoinHandle<()>)>,
    tun: Option<tun::TunHandle>,
}

impl Running {
    pub fn local_addr(&self) -> SocketAddr {
        self.engine.local_addr()
    }

    pub fn controller_addr(&self) -> Option<SocketAddr> {
        self.control.as_ref().map(|(addr, _)| *addr)
    }

    /// Имя интерфейса туннеля (`utunN`), если он поднят.
    pub fn tun_name(&self) -> Option<&str> {
        self.tun.as_ref().map(tun::TunHandle::name)
    }

    /// Обычная остановка: туннель снимает свои маршруты.
    pub async fn shutdown(mut self) {
        if let Some(tun) = self.tun.take() {
            tun.close().await;
        }
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        if let Some((_, task)) = &self.control {
            task.abort();
        }
    }
}

pub async fn run(plan: &config::Plan) -> Result<Running> {
    let selected = plan
        .outbound(&plan.selected)
        .cloned()
        .ok_or_else(|| EngineError::Unsupported("selected server missing".into()))?;
    let listener = TcpListener::bind(plan.listen).await?;
    let engine = serve(listener, selected)?;
    let control = match &plan.controller {
        Some(settings) => {
            let listener = TcpListener::bind(settings.listen).await?;
            let addr = listener.local_addr()?;
            let control = Arc::new(control::Control::new(
                plan,
                settings.secret.clone(),
                Arc::clone(engine.selector()),
                Arc::clone(engine.traffic()),
            ));
            Some((addr, tokio::spawn(control::serve(listener, control))))
        }
        None => None,
    };
    let tun = match &plan.tun {
        Some(settings) => Some(
            tun::start(
                settings,
                Arc::clone(engine.selector()),
                Arc::clone(engine.traffic()),
                config::server_hosts(plan),
            )
            .await?,
        ),
        None => None,
    };
    Ok(Running {
        engine,
        control,
        tun,
    })
}
