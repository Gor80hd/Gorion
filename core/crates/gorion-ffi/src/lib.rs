//! Привязки ядра Gorion для Swift (и других языков) через UniFFI.
//!
//! Это единственная граница между интерфейсом и логикой: интерфейс создаёт
//! [`GorionCore`], подписывается через [`CoreObserver`] и вызывает команды.
//! Типы здесь — зеркало `gorion_core::engine` в виде, понятном UniFFI.

use std::path::PathBuf;
use std::sync::Arc;

use gorion_core::ErrorCode;
use gorion_core::engine::{self, Engine, EngineObserver};
use gorion_core::model::AUTO_SELECT_SERVER_TAG;
use gorion_core::runtime::RuntimeMode;

uniffi::setup_scaffolding!();

// ---- типы ----

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionMode {
    /// «Вручную»: только локальный прокси.
    Manual,
    /// «Приложения»: системный прокси.
    SystemProxy,
    /// «Весь компьютер»: TUN.
    WholeComputer,
}

impl From<RuntimeMode> for ConnectionMode {
    fn from(mode: RuntimeMode) -> Self {
        match mode {
            RuntimeMode::Mixed => Self::Manual,
            RuntimeMode::SystemProxy => Self::SystemProxy,
            RuntimeMode::Tun => Self::WholeComputer,
        }
    }
}

impl From<ConnectionMode> for RuntimeMode {
    fn from(mode: ConnectionMode) -> Self {
        match mode {
            ConnectionMode::Manual => Self::Mixed,
            ConnectionMode::SystemProxy => Self::SystemProxy,
            ConnectionMode::WholeComputer => Self::Tun,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionStage {
    Disconnected,
    Starting,
    Connected,
    Stopping,
    Failed,
}

impl From<engine::ConnectionStage> for ConnectionStage {
    fn from(stage: engine::ConnectionStage) -> Self {
        match stage {
            engine::ConnectionStage::Disconnected => Self::Disconnected,
            engine::ConnectionStage::Starting => Self::Starting,
            engine::ConnectionStage::Connected => Self::Connected,
            engine::ConnectionStage::Stopping => Self::Stopping,
            engine::ConnectionStage::Failed => Self::Failed,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CoreErrorCode {
    InvalidSubscriptionUrl,
    SubscriptionFetchFailed,
    UnsupportedSubscriptionFormat,
    NoSelectableServers,
    UnsupportedTransport,
    InvalidShareLink,
    InvalidTemplate,
    ProfileNotFound,
    Storage,
    CoreBinaryMissing,
    InvalidRuntimeConfig,
    CoreStartFailed,
    ControllerUnavailable,
    SystemProxyFailed,
    RecoveryPending,
    AnotherInstanceRunning,
    Unsupported,
    Internal,
    InternetUnavailable,
    UnexpectedExit,
    NoProfile,
    TunHelperRequired,
    HelperOutdated,
    HelperInstallCancelled,
    HelperInstallFailed,
    EngineUnsupported,
}

impl From<ErrorCode> for CoreErrorCode {
    fn from(code: ErrorCode) -> Self {
        match code {
            ErrorCode::InvalidSubscriptionUrl => Self::InvalidSubscriptionUrl,
            ErrorCode::SubscriptionFetchFailed => Self::SubscriptionFetchFailed,
            ErrorCode::UnsupportedSubscriptionFormat => Self::UnsupportedSubscriptionFormat,
            ErrorCode::NoSelectableServers => Self::NoSelectableServers,
            ErrorCode::UnsupportedTransport => Self::UnsupportedTransport,
            ErrorCode::InvalidShareLink => Self::InvalidShareLink,
            ErrorCode::InvalidTemplate => Self::InvalidTemplate,
            ErrorCode::ProfileNotFound => Self::ProfileNotFound,
            ErrorCode::Storage => Self::Storage,
            ErrorCode::CoreBinaryMissing => Self::CoreBinaryMissing,
            ErrorCode::InvalidRuntimeConfig => Self::InvalidRuntimeConfig,
            ErrorCode::CoreStartFailed => Self::CoreStartFailed,
            ErrorCode::ControllerUnavailable => Self::ControllerUnavailable,
            ErrorCode::SystemProxyFailed => Self::SystemProxyFailed,
            ErrorCode::RecoveryPending => Self::RecoveryPending,
            ErrorCode::AnotherInstanceRunning => Self::AnotherInstanceRunning,
            ErrorCode::Unsupported => Self::Unsupported,
            ErrorCode::Internal => Self::Internal,
            ErrorCode::InternetUnavailable => Self::InternetUnavailable,
            ErrorCode::UnexpectedExit => Self::UnexpectedExit,
            ErrorCode::NoProfile => Self::NoProfile,
            ErrorCode::TunHelperRequired => Self::TunHelperRequired,
            ErrorCode::HelperOutdated => Self::HelperOutdated,
            ErrorCode::HelperInstallCancelled => Self::HelperInstallCancelled,
            ErrorCode::HelperInstallFailed => Self::HelperInstallFailed,
            ErrorCode::EngineUnsupported => Self::EngineUnsupported,
        }
    }
}

/// Помощник для режима «Весь компьютер».
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum HelperStatus {
    Unknown,
    NotInstalled,
    Outdated,
    Ready,
}

impl From<engine::HelperStatus> for HelperStatus {
    fn from(status: engine::HelperStatus) -> Self {
        match status {
            engine::HelperStatus::Unknown => Self::Unknown,
            engine::HelperStatus::NotInstalled => Self::NotInstalled,
            engine::HelperStatus::Outdated => Self::Outdated,
            engine::HelperStatus::Ready => Self::Ready,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreFailure {
    pub code: CoreErrorCode,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CoreNotice {
    SubscriptionAdded { profile_name: String },
    ProfileUpdated { reconnected: bool },
    ProfileRemoved { profile_name: String },
    ProfileRestored { profile_name: String },
    ServerSavedForNextConnection,
    ServerSwitched { server_name: String },
    AutoSelectSaved,
    AutoSelectChose { server_name: String },
    Connected { server_name: Option<String> },
    Disconnected,
    ModeSaved,
}

impl From<engine::Notice> for CoreNotice {
    fn from(notice: engine::Notice) -> Self {
        use engine::Notice as N;
        match notice {
            N::SubscriptionAdded { profile_name } => Self::SubscriptionAdded { profile_name },
            N::ProfileUpdated { reconnected } => Self::ProfileUpdated { reconnected },
            N::ProfileRemoved { profile_name } => Self::ProfileRemoved { profile_name },
            N::ProfileRestored { profile_name } => Self::ProfileRestored { profile_name },
            N::ServerSavedForNextConnection => Self::ServerSavedForNextConnection,
            N::ServerSwitched { server_name } => Self::ServerSwitched { server_name },
            N::AutoSelectSaved => Self::AutoSelectSaved,
            N::AutoSelectChose { server_name } => Self::AutoSelectChose { server_name },
            N::Connected { server_name } => Self::Connected { server_name },
            N::Disconnected => Self::Disconnected,
            N::ModeSaved => Self::ModeSaved,
        }
    }
}

/// Точка на планете, градусы.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct CoreGeoPoint {
    pub lat: f64,
    pub lon: f64,
}

impl From<gorion_core::geo::GeoPoint> for CoreGeoPoint {
    fn from(p: gorion_core::geo::GeoPoint) -> Self {
        Self {
            lat: p.lat,
            lon: p.lon,
        }
    }
}

/// Внешний адрес и его место.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreIpInfo {
    pub ip: String,
    pub country_code: String,
    pub country: Option<String>,
    pub region: Option<String>,
    pub city: Option<String>,
    pub org: Option<String>,
    /// «Город, регион» и т. п. — данные, а не текст интерфейса.
    pub location: Option<String>,
}

impl From<gorion_core::ipinfo::IpInfo> for CoreIpInfo {
    fn from(i: gorion_core::ipinfo::IpInfo) -> Self {
        let location = gorion_core::ipinfo::best_location(&i);
        Self {
            ip: i.ip,
            country_code: i.country_code,
            country: i.country,
            region: i.region,
            city: i.city,
            org: i.org,
            location,
        }
    }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreServer {
    pub tag: String,
    pub name: String,
    pub country_code: Option<String>,
    pub kind: String,
    pub host: Option<String>,
    pub port: Option<i64>,
    /// `None` — не измеряли, `0` и меньше — не ответил.
    pub delay_ms: Option<i64>,
    /// Страна для планеты.
    pub map_country_code: Option<String>,
    pub location: CoreGeoPoint,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreSubscriptionUsage {
    pub upload: i64,
    pub download: i64,
    pub total: i64,
    pub expire_at: Option<String>,
    pub web_page_url: Option<String>,
    pub support_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CoreProfile {
    pub id: String,
    pub name: String,
    pub server_count: u32,
    pub updated_at: String,
    pub usage: Option<CoreSubscriptionUsage>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CoreSnapshot {
    /// Порядковый номер снимка; более старые надо отбрасывать.
    pub revision: u64,
    pub bootstrapping: bool,
    pub busy: bool,
    pub measuring_delays: bool,
    pub mode: ConnectionMode,
    pub stage: ConnectionStage,
    pub profiles: Vec<CoreProfile>,
    pub active_profile_id: Option<String>,
    pub servers: Vec<CoreServer>,
    pub selected_tag: Option<String>,
    pub auto_selected: bool,
    pub active_tag: Option<String>,
    pub connected_at_ms: Option<i64>,
    pub local_proxy_port: Option<u16>,
    pub notice: Option<CoreNotice>,
    pub notice_id: u64,
    pub error: Option<CoreFailure>,
    pub can_undo_remove: bool,
    pub direct_ip: Option<CoreIpInfo>,
    pub routed_ip: Option<CoreIpInfo>,
    pub source_location: CoreGeoPoint,
    pub destination_location: CoreGeoPoint,
    pub destination_country: Option<String>,
    pub helper: HelperStatus,
}

impl From<engine::EngineSnapshot> for CoreSnapshot {
    fn from(s: engine::EngineSnapshot) -> Self {
        Self {
            revision: s.revision,
            bootstrapping: s.bootstrapping,
            busy: s.busy,
            measuring_delays: s.measuring_delays,
            mode: s.mode.into(),
            stage: s.stage.into(),
            profiles: s
                .profiles
                .into_iter()
                .map(|p| CoreProfile {
                    id: p.id,
                    name: p.name,
                    server_count: p.server_count,
                    updated_at: p.updated_at,
                    usage: p.subscription.map(|u| CoreSubscriptionUsage {
                        upload: u.upload,
                        download: u.download,
                        total: u.total,
                        expire_at: u.expire_at,
                        web_page_url: u.web_page_url,
                        support_url: u.support_url,
                    }),
                })
                .collect(),
            active_profile_id: s.active_profile_id,
            servers: s
                .servers
                .into_iter()
                .map(|v| CoreServer {
                    tag: v.tag,
                    name: v.name,
                    country_code: v.country_code,
                    kind: v.kind,
                    host: v.host,
                    port: v.port,
                    delay_ms: v.delay_ms,
                    map_country_code: v.map_country_code,
                    location: v.location.into(),
                })
                .collect(),
            auto_selected: s.selected_tag.as_deref() == Some(AUTO_SELECT_SERVER_TAG),
            selected_tag: s.selected_tag,
            active_tag: s.active_tag,
            connected_at_ms: s.connected_at_ms,
            local_proxy_port: s.local_proxy_port,
            notice: s.notice.map(Into::into),
            notice_id: s.notice_id,
            error: s.error.map(|e| CoreFailure {
                code: e.code.into(),
                detail: e.detail,
            }),
            can_undo_remove: s.can_undo_remove,
            direct_ip: s.direct_ip.map(Into::into),
            routed_ip: s.routed_ip.map(Into::into),
            source_location: s.source_location.into(),
            destination_location: s.destination_location.into(),
            destination_country: s.destination_country,
            helper: s.helper.into(),
        }
    }
}

// ---- планета ----

/// Коды стран карты планеты: индекс пикселя карты − 1.
#[uniffi::export]
pub fn globe_country_codes() -> Vec<String> {
    gorion_core::geo::globe_country_codes()
        .iter()
        .map(|c| (*c).to_owned())
        .collect()
}

/// Центр страны по коду ISO (с синонимами), если известен.
#[uniffi::export]
pub fn country_location(code: String) -> Option<CoreGeoPoint> {
    gorion_core::geo::country_location(&code).map(Into::into)
}

// ---- наблюдатель ----

/// Реализуется интерфейсом. Вызывается с фоновых потоков: интерфейс сам
/// переносит обновление на главный поток.
#[uniffi::export(with_foreign)]
pub trait CoreObserver: Send + Sync {
    fn on_snapshot(&self, snapshot: CoreSnapshot);
    fn on_traffic(&self, up_bytes_per_second: u64, down_bytes_per_second: u64);
}

struct ObserverBridge(Arc<dyn CoreObserver>);

impl EngineObserver for ObserverBridge {
    fn on_snapshot(&self, snapshot: engine::EngineSnapshot) {
        self.0.on_snapshot(snapshot.into());
    }
    fn on_traffic(&self, up: u64, down: u64) {
        self.0.on_traffic(up, down);
    }
}

// ---- ядро ----

#[derive(uniffi::Object)]
pub struct GorionCore {
    engine: Arc<Engine>,
}

#[uniffi::export(async_runtime = "tokio")]
impl GorionCore {
    /// `data_dir` — `…/Application Support/app.gorion.client/gorion`,
    /// `singbox_path` — бинарник sing-box внутри приложения.
    #[uniffi::constructor]
    pub fn new(
        data_dir: String,
        singbox_path: String,
        observer: Arc<dyn CoreObserver>,
    ) -> Arc<Self> {
        let engine = Engine::new(
            PathBuf::from(data_dir),
            PathBuf::from(singbox_path),
            Arc::new(ObserverBridge(observer)),
        );
        Arc::new(Self { engine })
    }

    /// Константа тега «Авто» — чтобы интерфейс не держал свою копию.
    pub fn auto_select_tag(&self) -> String {
        AUTO_SELECT_SERVER_TAG.to_owned()
    }

    pub fn snapshot(&self) -> CoreSnapshot {
        self.engine.snapshot().into()
    }

    pub fn logs(&self) -> Vec<String> {
        self.engine.logs()
    }

    pub fn dismiss_message(&self) {
        self.engine.dismiss_message();
    }

    pub async fn bootstrap(&self) {
        self.engine.bootstrap().await;
    }

    pub async fn add_subscription(&self, url: String) {
        self.engine.add_subscription(&url).await;
    }

    pub async fn choose_profile(&self, profile_id: String) {
        self.engine.choose_profile(&profile_id).await;
    }

    pub async fn refresh_profile(&self, profile_id: String) {
        self.engine.refresh_profile(&profile_id).await;
    }

    pub async fn remove_profile(&self, profile_id: String) {
        self.engine.remove_profile(&profile_id).await;
    }

    pub async fn undo_remove(&self) {
        self.engine.undo_remove().await;
    }

    pub async fn rename_profile(&self, profile_id: String, name: String) {
        self.engine.rename_profile(&profile_id, &name).await;
    }

    pub async fn select_server(&self, tag: String) {
        self.engine.select_server(&tag).await;
    }

    pub async fn measure_delays(&self) {
        self.engine.measure_delays().await;
    }

    pub async fn set_mode(&self, mode: ConnectionMode) {
        self.engine.set_mode(mode.into()).await;
    }

    pub async fn connect(&self) {
        self.engine.connect().await;
    }

    pub async fn disconnect(&self) {
        self.engine.disconnect().await;
    }

    pub async fn refresh_helper(&self) {
        self.engine.refresh_helper().await;
    }

    /// Ставит помощника: macOS спросит пароль администратора, `prompt` —
    /// текст этого окна. После установки сразу подключает.
    /// `helper_path` — `Gorion.app/Contents/Helpers/gorion-helper`.
    #[cfg(target_os = "macos")]
    pub async fn install_helper(&self, helper_path: String, prompt: String) {
        self.engine
            .install_helper(std::path::Path::new(&helper_path), &prompt)
            .await;
    }

    /// Вызывается при выходе из приложения; ждёт не дольше 30 с.
    pub async fn shutdown(&self) {
        self.engine.shutdown().await;
    }
}
