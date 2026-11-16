//! Движок приложения: состояние и команды, общие для macOS и Windows.
//! Эталон: `lib/features/home/application/dashboard_*.dart`.
//!
//! Интерфейс подписывается на снимки состояния ([`EngineSnapshot`]) и
//! вызывает команды. Текстов здесь нет: интерфейс сам подбирает слова по
//! [`Notice`] и [`ErrorCode`].
//!
//! Перенесено не целиком (см. parity.md):
//! - автовыбор — один проход «лучший сервер» при подключении и по команде,
//!   без фонового обслуживания, кулдаунов и кэша успешных подключений;
//! - тонкая настройка соединения и раздельное туннелирование — позже;
//! - «Весь компьютер» (TUN) идёт через помощника с правами root (ADR-0005);
//!   без помощника `connect` возвращает `TunHelperRequired`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::task::JoinHandle;

use crate::display::{extract_country_code, normalize_server_display_text, strip_country_prefix};
use crate::error::{CoreError, CoreResult, ErrorCode};
use crate::geo::{self, GeoPoint};
pub use crate::helper::HelperStatus;
#[cfg(unix)]
use crate::helper::client::{HelperClient, TunRuntime};
use crate::ipinfo::{self, IpInfo};
use crate::model::{
    AUTO_SELECT_SERVER_TAG, ProxyProfile, ServerEntry, StoredProfilesState, SubscriptionInfo,
    is_auto_select_tag,
};
use crate::probe::{self, ProbeResult, ProbeSettings};
use crate::runtime::RuntimeMode;
use crate::runtime::clash::ClashClient;
use crate::runtime::service::{RuntimeEvent, RuntimeService, RuntimeSession, StartRequest};
use crate::storage::{ProfileStore, RemovedProfile, read_json, write_json};
use crate::subscription;

/// Сколько кандидатов проверяет проход автовыбора.
const AUTO_SELECT_CANDIDATES: usize = 6;
/// Кандидат с такой задержкой и полным здоровьем принимается сразу.
const FAST_ACCEPT_DELAY_MS: i64 = 250;
/// Пауза после переключения сервера, прежде чем проверять его.
const PROXY_SETTLE_DELAY: Duration = Duration::from_millis(700);
const DELAY_TIMEOUT_MS: u64 = 5000;
/// Сколько серверов проверяется одновременно.
const DELAY_CONCURRENCY: usize = 16;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum ConnectionStage {
    #[default]
    Disconnected,
    Starting,
    Connected,
    Stopping,
    Failed,
}

/// Что сообщить пользователю после действия. Слова подбирает интерфейс.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Notice {
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EngineFailure {
    pub code: ErrorCode,
    /// Технические подробности для «Подробнее» и журнала.
    pub detail: String,
}

impl From<&CoreError> for EngineFailure {
    fn from(error: &CoreError) -> Self {
        Self {
            code: error.code(),
            detail: error.to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct ServerView {
    pub tag: String,
    /// Имя без флага и кода страны.
    pub name: String,
    pub country_code: Option<String>,
    pub kind: String,
    pub host: Option<String>,
    pub port: Option<i64>,
    pub delay_ms: Option<i64>,
    /// Страна для планеты (шире, чем `country_code`: ищет код по всему имени).
    pub map_country_code: Option<String>,
    /// Точка сервера на планете.
    pub location: GeoPoint,
}

#[derive(Debug, Clone, PartialEq)]
pub struct ProfileView {
    pub id: String,
    pub name: String,
    pub server_count: u32,
    pub updated_at: String,
    pub subscription: Option<SubscriptionInfo>,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct EngineSnapshot {
    /// Растёт с каждым изменением: наблюдатель отбрасывает снимки, пришедшие
    /// не по порядку (обратные вызовы идут с разных потоков).
    pub revision: u64,
    pub bootstrapping: bool,
    pub busy: bool,
    pub measuring_delays: bool,
    pub mode: RuntimeMode,
    pub stage: ConnectionStage,
    pub profiles: Vec<ProfileView>,
    pub active_profile_id: Option<String>,
    pub servers: Vec<ServerView>,
    /// Выбор пользователя; может быть [`AUTO_SELECT_SERVER_TAG`].
    pub selected_tag: Option<String>,
    /// Сервер, через который идёт (или пойдёт) трафик.
    pub active_tag: Option<String>,
    pub connected_at_ms: Option<i64>,
    pub local_proxy_port: Option<u16>,
    pub notice: Option<Notice>,
    /// Растёт с каждым новым уведомлением, чтобы интерфейс не показал одно
    /// и то же дважды.
    pub notice_id: u64,
    pub error: Option<EngineFailure>,
    pub can_undo_remove: bool,
    /// Внешний адрес без прокси.
    pub direct_ip: Option<IpInfo>,
    /// Адрес выхода через подключение.
    pub routed_ip: Option<IpInfo>,
    /// Откуда идёт трафик (по прямому IP).
    pub source_location: GeoPoint,
    /// Куда идёт трафик: выбранный или активный сервер.
    pub destination_location: GeoPoint,
    pub destination_country: Option<String>,
    /// Помощник для режима «Весь компьютер».
    pub helper: HelperStatus,
}

pub trait EngineObserver: Send + Sync {
    fn on_snapshot(&self, snapshot: EngineSnapshot);
    fn on_traffic(&self, up: u64, down: u64);
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct AppSettings {
    /// Режим подключения. Прежний ключ `runtimeMode` писал экран с
    /// переключателем «Приложения / Вручную» — он больше не читается: по
    /// умолчанию теперь VPN для всего компьютера.
    connection_mode: Option<RuntimeMode>,
}

/// Режим без сохранённого выбора: VPN для всего компьютера (ADR-0005).
const DEFAULT_MODE: RuntimeMode = RuntimeMode::Tun;

#[derive(Default)]
struct State {
    revision: u64,
    bootstrapping: bool,
    busy: bool,
    measuring_delays: bool,
    mode: RuntimeMode,
    stage: ConnectionStage,
    storage: StoredProfilesState,
    session: Option<RuntimeSession>,
    connected_at_ms: Option<i64>,
    delay_by_tag: HashMap<String, i64>,
    active_tag: Option<String>,
    notice: Option<Notice>,
    notice_id: u64,
    error: Option<EngineFailure>,
    removed: Option<RemovedProfile>,
    direct_ip: Option<IpInfo>,
    routed_ip: Option<IpInfo>,
    /// Растёт с каждой новой проверкой IP: старые ответы отбрасываются.
    ip_generation: u64,
    helper: HelperStatus,
}

impl State {
    fn active_profile(&self) -> Option<&ProxyProfile> {
        self.storage.active_profile()
    }

    fn set_notice(&mut self, notice: Notice) {
        self.notice = Some(notice);
        self.notice_id += 1;
        self.error = None;
    }

    fn set_error(&mut self, error: &CoreError) {
        self.error = Some(error.into());
        self.notice = None;
    }

    fn clear_messages(&mut self) {
        self.notice = None;
        self.error = None;
    }

    fn reset_connection_view(&mut self) {
        self.session = None;
        self.connected_at_ms = None;
        self.active_tag = self
            .active_profile()
            .and_then(|p| p.startup_server_tag())
            .map(str::to_owned);
    }

    fn server_name(&self, tag: &str) -> String {
        self.active_profile()
            .and_then(|p| p.servers.iter().find(|s| s.tag == tag))
            .map(|s| display_name(s).0)
            .unwrap_or_else(|| tag.to_owned())
    }
}

pub struct Engine {
    store: ProfileStore,
    runtime: Arc<RuntimeService>,
    /// Ядро режима TUN, которое держит помощник.
    #[cfg(unix)]
    tun: Arc<TunRuntime>,
    /// Бинарник `gorion-engine` в сборке приложения.
    engine_path: PathBuf,
    settings_path: PathBuf,
    probe_settings: ProbeSettings,
    state: Mutex<State>,
    /// Последовательность команд, меняющих профили.
    ops: tokio::sync::Mutex<()>,
    connect_generation: AtomicU64,
    traffic_task: Mutex<Option<JoinHandle<()>>>,
    observer: Arc<dyn EngineObserver>,
    this: Weak<Engine>,
}

impl Engine {
    /// `data_dir` — `…/Application Support/app.gorion.client/gorion`.
    pub fn new(
        data_dir: PathBuf,
        engine_path: PathBuf,
        observer: Arc<dyn EngineObserver>,
    ) -> Arc<Self> {
        Arc::new_cyclic(|weak: &Weak<Engine>| {
            let this = weak.clone();
            let weak = weak.clone();
            let events: crate::runtime::service::EventSink = Arc::new(move |event| {
                if let Some(engine) = weak.upgrade() {
                    engine.handle_runtime_event(event);
                }
            });
            let runtime = RuntimeService::new(
                data_dir.join("runtime"),
                engine_path.clone(),
                events.clone(),
            );
            #[cfg(unix)]
            let tun = TunRuntime::new(HelperClient::new(helper_socket()), events);
            Self {
                store: ProfileStore::new(&data_dir),
                runtime,
                #[cfg(unix)]
                tun,
                engine_path,
                settings_path: data_dir.join("native-settings.json"),
                probe_settings: ProbeSettings::default(),
                state: Mutex::new(State {
                    bootstrapping: true,
                    ..State::default()
                }),
                ops: tokio::sync::Mutex::new(()),
                connect_generation: AtomicU64::new(0),
                traffic_task: Mutex::new(None),
                observer,
                this,
            }
        })
    }

    pub fn snapshot(&self) -> EngineSnapshot {
        let state = self.lock();
        build_snapshot(&state)
    }

    pub fn logs(&self) -> Vec<String> {
        self.runtime.logs()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn update(&self, change: impl FnOnce(&mut State)) {
        let snapshot = {
            let mut state = self.lock();
            change(&mut state);
            state.revision += 1;
            build_snapshot(&state)
        };
        self.observer.on_snapshot(snapshot);
    }

    // ---- запуск ----

    pub async fn bootstrap(&self) {
        self.runtime.recover_previous_session().await;
        let settings: AppSettings = read_json(&self.settings_path)
            .await
            .ok()
            .flatten()
            .unwrap_or_default();
        let loaded = self.store.load_state().await;
        self.update(|state| {
            state.bootstrapping = false;
            state.mode = settings.connection_mode.unwrap_or(DEFAULT_MODE);
            match loaded {
                Ok(storage) => {
                    state.storage = storage;
                    state.reset_connection_view();
                }
                Err(e) => state.set_error(&e),
            }
        });
        self.refresh_ip(false);
        self.refresh_helper().await;
    }

    pub fn dismiss_message(&self) {
        self.update(State::clear_messages);
    }

    // ---- подписки ----

    pub async fn add_subscription(&self, url: &str) {
        let _op = self.ops.lock().await;
        self.update(|s| {
            s.busy = true;
            s.clear_messages();
        });
        let result = async {
            let trimmed = url.trim();
            subscription::validate_subscription_url(trimmed)?;
            let parsed = subscription::fetch_and_parse(trimmed).await?;
            self.store.add_subscription(trimmed, parsed).await
        }
        .await;
        self.update(|s| {
            s.busy = false;
            match result {
                Ok(storage) => {
                    let name = storage
                        .active_profile()
                        .map(|p| p.name.clone())
                        .unwrap_or_default();
                    s.storage = storage;
                    s.delay_by_tag.clear();
                    if s.session.is_none() {
                        s.reset_connection_view();
                    }
                    s.set_notice(Notice::SubscriptionAdded { profile_name: name });
                }
                Err(e) => s.set_error(&e),
            }
        });
    }

    pub async fn choose_profile(&self, profile_id: &str) {
        if self
            .lock()
            .active_profile()
            .is_some_and(|p| p.id == profile_id)
        {
            return;
        }
        if self.is_running() {
            self.disconnect().await;
        }
        let _op = self.ops.lock().await;
        let result = self.store.set_active_profile(profile_id).await;
        self.update(|s| match result {
            Ok(storage) => {
                s.storage = storage;
                s.delay_by_tag.clear();
                s.reset_connection_view();
                s.clear_messages();
            }
            Err(e) => s.set_error(&e),
        });
    }

    pub async fn refresh_profile(&self, profile_id: &str) {
        let (is_active, was_connected) = {
            let s = self.lock();
            let is_active = s.active_profile().is_some_and(|p| p.id == profile_id);
            (
                is_active,
                is_active && s.stage == ConnectionStage::Connected,
            )
        };
        if is_active && self.is_running() {
            self.disconnect().await;
        }
        let _op = self.ops.lock().await;
        self.update(|s| {
            s.busy = true;
            s.clear_messages();
        });
        let result = async {
            let state = self.store.load_state().await?;
            let profile = state
                .profile(profile_id)
                .ok_or_else(|| CoreError::ProfileNotFound(profile_id.into()))?;
            let parsed = subscription::fetch_and_parse(&profile.subscription_url).await?;
            self.store.apply_refresh(profile_id, parsed).await
        }
        .await;
        let ok = result.is_ok();
        self.update(|s| {
            s.busy = false;
            match result {
                Ok(storage) => {
                    s.storage = storage;
                    if is_active {
                        s.delay_by_tag.clear();
                        s.reset_connection_view();
                    }
                    s.set_notice(Notice::ProfileUpdated {
                        reconnected: was_connected,
                    });
                }
                Err(e) => s.set_error(&e),
            }
        });
        drop(_op);
        if ok && was_connected {
            self.connect().await;
        }
    }

    pub async fn remove_profile(&self, profile_id: &str) {
        let is_active = self
            .lock()
            .active_profile()
            .is_some_and(|p| p.id == profile_id);
        if is_active && self.is_running() {
            self.disconnect().await;
        }
        let _op = self.ops.lock().await;
        let result = self.store.remove_profile(profile_id).await;
        self.update(|s| match result {
            Ok((storage, removed)) => {
                let name = removed.profile.name.clone();
                s.storage = storage;
                s.removed = Some(removed);
                if is_active {
                    s.delay_by_tag.clear();
                    s.reset_connection_view();
                }
                s.set_notice(Notice::ProfileRemoved { profile_name: name });
            }
            Err(e) => s.set_error(&e),
        });
    }

    /// Отмена последнего удаления (кнопка «Вернуть» в уведомлении).
    pub async fn undo_remove(&self) {
        let _op = self.ops.lock().await;
        let Some(removed) = self.lock().removed.take() else {
            return;
        };
        let name = removed.profile.name.clone();
        let result = self.store.restore_profile(removed).await;
        self.update(|s| match result {
            Ok(storage) => {
                s.storage = storage;
                if s.session.is_none() {
                    s.reset_connection_view();
                }
                s.set_notice(Notice::ProfileRestored { profile_name: name });
            }
            Err(e) => s.set_error(&e),
        });
    }

    pub async fn rename_profile(&self, profile_id: &str, name: &str) {
        let _op = self.ops.lock().await;
        let result = self.store.rename_profile(profile_id, name).await;
        self.update(|s| match result {
            Ok(storage) => s.storage = storage,
            Err(e) => s.set_error(&e),
        });
    }

    // ---- серверы ----

    pub async fn select_server(&self, tag: &str) {
        let Some(profile) = self.lock().active_profile().cloned() else {
            return;
        };
        let _op = self.ops.lock().await;
        if is_auto_select_tag(Some(tag)) {
            let result = self
                .store
                .update_selected_server(&profile.id, AUTO_SELECT_SERVER_TAG)
                .await;
            let session = self.connected_session();
            self.update(|s| match result {
                Ok(storage) => {
                    s.storage = storage;
                    if s.session.is_none() {
                        s.reset_connection_view();
                    }
                    s.set_notice(Notice::AutoSelectSaved);
                }
                Err(e) => s.set_error(&e),
            });
            drop(_op);
            if let Some(session) = session {
                self.run_auto_select_pass(&session).await;
            }
            return;
        }
        let result = async {
            if let Some(session) = self.connected_session() {
                let clash = session.clash()?;
                clash
                    .select_proxy(&session.manual_selector_tag, tag)
                    .await?;
                let snapshot = clash.snapshot(&session.manual_selector_tag).await?;
                let selected = snapshot.selected_tag.unwrap_or_else(|| tag.to_owned());
                let storage = self
                    .store
                    .update_selected_server(&profile.id, &selected)
                    .await?;
                Ok((storage, Some(selected)))
            } else {
                Ok((
                    self.store.update_selected_server(&profile.id, tag).await?,
                    None,
                ))
            }
        }
        .await;
        self.update(|s| match result {
            Ok((storage, live)) => {
                s.storage = storage;
                match live {
                    Some(selected) => {
                        let name = s.server_name(&selected);
                        s.active_tag = Some(selected);
                        s.set_notice(Notice::ServerSwitched { server_name: name });
                    }
                    None => {
                        s.reset_connection_view();
                        s.set_notice(Notice::ServerSavedForNextConnection);
                    }
                }
            }
            Err(e) => s.set_error(&e),
        });
        if self.is_running() {
            self.refresh_ip(true);
        }
    }

    /// Задержки серверов. При подключении — URLTest работающего ядра;
    /// без подключения — временное ядро только с локальным прокси
    /// (системные настройки не трогаются).
    pub async fn measure_delays(&self) {
        let profile = {
            let mut s = self.lock();
            if s.measuring_delays {
                return;
            }
            let Some(profile) = s.active_profile().cloned() else {
                return;
            };
            s.measuring_delays = true;
            profile
        };
        self.update(|_| {});
        let result = match self.connected_session() {
            Some(session) => self.load_delays(&session, &server_tags(&profile)).await,
            None => self.measure_detached(&profile).await,
        };
        self.update(|s| {
            s.measuring_delays = false;
            if s.active_profile().is_some_and(|p| p.id == profile.id) {
                match result {
                    Ok(delays) => s.delay_by_tag = delays,
                    Err(e) => s.set_error(&e),
                }
            }
        });
    }

    async fn measure_detached(&self, profile: &ProxyProfile) -> CoreResult<HashMap<String, i64>> {
        let template = self.store.load_template(profile).await?;
        let dir = self.store.root().join("runtime-probe");
        let probe_runtime = RuntimeService::new(dir, self.engine_path.clone(), Arc::new(|_| {}));
        probe_runtime.recover_previous_session().await;
        let session = probe_runtime
            .start(StartRequest {
                profile_id: profile.id.clone(),
                template_config: template,
                mode: RuntimeMode::Mixed,
                selected_server_tag: None,
                url_test_url: probe::url_test_url(
                    &self.probe_settings.domain_probe_url,
                    &format!("{}::probe::urltest", profile.id),
                ),
                bypass_steam: false,
                split_tunnel: None,
            })
            .await?;
        let result = self.load_delays(&session, &server_tags(profile)).await;
        let _ = probe_runtime.stop().await;
        result
    }

    /// Задержки серверов: URL-тест каждого сервера через ядро, по
    /// [`DELAY_CONCURRENCY`] одновременно. Не ответивший получает 0.
    ///
    /// Δ к эталону: эталон спрашивал задержки у группы urltest целиком, но
    /// во время стартового теста группы ответ был пустым — и все серверы
    /// выглядели мёртвыми.
    async fn load_delays(
        &self,
        session: &RuntimeSession,
        tags: &[String],
    ) -> CoreResult<HashMap<String, i64>> {
        use futures_util::StreamExt;
        let clash = session.clash()?;
        let url = probe::url_test_url(
            &self.probe_settings.domain_probe_url,
            &format!("{}::refresh::urltest", session.profile_id),
        );
        let results: Vec<(String, i64)> = futures_util::stream::iter(tags.iter().cloned())
            .map(|tag| {
                let clash = clash.clone();
                let url = url.clone();
                async move {
                    let delay = clash
                        .proxy_delay(&tag, &url, DELAY_TIMEOUT_MS)
                        .await
                        .unwrap_or(0);
                    (tag, delay)
                }
            })
            .buffer_unordered(DELAY_CONCURRENCY)
            .collect()
            .await;
        Ok(results.into_iter().collect())
    }

    // ---- режим ----

    pub async fn set_mode(&self, mode: RuntimeMode) {
        let (changed, reconnect) = {
            let s = self.lock();
            (s.mode != mode, s.stage == ConnectionStage::Connected)
        };
        if !changed {
            return;
        }
        let _ = write_json(
            &self.settings_path,
            &AppSettings {
                connection_mode: Some(mode),
            },
        )
        .await;
        self.update(|s| {
            s.mode = mode;
            if !reconnect {
                s.set_notice(Notice::ModeSaved);
            }
        });
        if reconnect {
            self.disconnect().await;
            self.connect().await;
        }
    }

    // ---- подключение ----

    fn is_running(&self) -> bool {
        matches!(
            self.lock().stage,
            ConnectionStage::Connected | ConnectionStage::Starting
        )
    }

    fn connected_session(&self) -> Option<RuntimeSession> {
        let s = self.lock();
        (s.stage == ConnectionStage::Connected)
            .then(|| s.session.clone())
            .flatten()
    }

    fn is_current(&self, generation: u64) -> bool {
        self.connect_generation.load(Ordering::SeqCst) == generation
    }

    pub async fn connect(&self) {
        let generation = self.connect_generation.fetch_add(1, Ordering::SeqCst) + 1;
        let (profile, mode) = {
            let s = self.lock();
            (s.active_profile().cloned(), s.mode)
        };
        let Some(profile) = profile else {
            self.update(|s| s.set_error(&CoreError::NoProfile));
            return;
        };
        self.update(|s| {
            s.busy = true;
            s.stage = ConnectionStage::Starting;
            s.clear_messages();
            s.connected_at_ms = None;
        });

        match self.connect_inner(&profile, mode, generation).await {
            Ok(Some(outcome)) => {
                self.start_traffic(&outcome.session);
                self.update(|s| {
                    s.busy = false;
                    s.stage = ConnectionStage::Connected;
                    s.storage = outcome.storage;
                    s.delay_by_tag = outcome.delays;
                    s.connected_at_ms = Some(chrono::Utc::now().timestamp_millis());
                    s.active_tag = outcome.active_tag.clone();
                    s.session = Some(outcome.session);
                    let server_name = outcome.active_tag.as_deref().map(|t| s.server_name(t));
                    s.set_notice(match (outcome.auto_chose, server_name.clone()) {
                        (true, Some(name)) => Notice::AutoSelectChose { server_name: name },
                        _ => Notice::Connected { server_name },
                    });
                });
                // В TUN весь трафик приложения идёт через туннель: «прямой»
                // адрес сейчас не узнать, остаётся прежний.
                self.refresh_ip(mode.uses_tun());
            }
            // Подключение отменили (отключение или новое подключение).
            Ok(None) => {}
            Err(error) => {
                if !self.is_current(generation) {
                    return;
                }
                // Ядро могло успеть подняться — ничего не должно гнать
                // трафик за спиной у интерфейса, который покажет «ошибку».
                let _ = self.stop_runtime().await;
                self.update(|s| {
                    s.busy = false;
                    if let Some(helper) = helper_status_for(&error) {
                        s.helper = helper;
                    }
                    s.stage = if matches!(
                        error,
                        CoreError::InternetUnavailable(_)
                            | CoreError::TunHelperRequired
                            | CoreError::HelperOutdated(_)
                    ) {
                        ConnectionStage::Disconnected
                    } else {
                        ConnectionStage::Failed
                    };
                    s.reset_connection_view();
                    s.set_error(&error);
                });
            }
        }
    }

    async fn connect_inner(
        &self,
        profile: &ProxyProfile,
        mode: RuntimeMode,
        generation: u64,
    ) -> CoreResult<Option<ConnectOutcome>> {
        let template = self.store.load_template(profile).await?;
        let session = self
            .start_runtime(StartRequest {
                profile_id: profile.id.clone(),
                template_config: template,
                mode,
                selected_server_tag: profile.startup_server_tag().map(str::to_owned),
                url_test_url: probe::url_test_url(
                    &self.probe_settings.domain_probe_url,
                    &format!("{}::runtime::urltest", profile.id),
                ),
                bypass_steam: false,
                split_tunnel: None,
            })
            .await?;
        if !self.is_current(generation) {
            let _ = self.stop_runtime().await;
            return Ok(None);
        }
        let clash = session.clash()?;
        let snapshot = clash.snapshot(&session.manual_selector_tag).await?;
        let mut delays = self
            .load_delays(&session, &server_tags(profile))
            .await
            .unwrap_or_default();
        let mut active_tag = snapshot
            .selected_tag
            .or_else(|| profile.startup_server_tag().map(str::to_owned));
        let mut auto_chose = false;

        if profile.prefers_auto_selection() {
            let winner = self
                .best_server(&session, &clash, profile, &delays, active_tag.as_deref())
                .await?;
            auto_chose = active_tag.as_deref() != Some(winner.server_tag.as_str());
            if let Some(delay) = winner.url_test_delay {
                delays.insert(winner.server_tag.clone(), delay);
            }
            active_tag = Some(winner.server_tag);
        } else {
            let tag = active_tag
                .clone()
                .ok_or_else(|| CoreError::InternetUnavailable(String::new()))?;
            let result = probe::probe_server(
                session.mixed_port,
                &profile.id,
                &tag,
                delays.get(&tag).copied(),
                &self.probe_settings,
            )
            .await;
            if !result.fully_healthy() {
                let name = profile
                    .servers
                    .iter()
                    .find(|s| s.tag == tag)
                    .map_or(tag.clone(), |s| display_name(s).0);
                return Err(CoreError::InternetUnavailable(name));
            }
        }
        if !self.is_current(generation) {
            let _ = self.stop_runtime().await;
            return Ok(None);
        }
        let storage = match active_tag.as_deref() {
            Some(tag) if profile.prefers_auto_selection() => {
                self.store
                    .update_auto_selected_server(&profile.id, tag)
                    .await?
            }
            Some(tag) => self.store.update_selected_server(&profile.id, tag).await?,
            None => self.store.load_state().await?,
        };
        Ok(Some(ConnectOutcome {
            session,
            storage,
            delays,
            active_tag,
            auto_chose,
        }))
    }

    /// Один проход автовыбора: кандидаты по задержке, проверка каждого
    /// через локальный прокси, выбор лучшего по здоровью.
    async fn best_server(
        &self,
        session: &RuntimeSession,
        clash: &ClashClient,
        profile: &ProxyProfile,
        delays: &HashMap<String, i64>,
        current: Option<&str>,
    ) -> CoreResult<ProbeResult> {
        let mut candidates: Vec<&ServerEntry> = profile.servers.iter().collect();
        candidates.sort_by_key(|s| match delays.get(&s.tag) {
            Some(d) if *d > 0 => *d,
            _ => i64::MAX,
        });
        // Текущий сервер проверяем первым: лишнее переключение хуже.
        if let Some(current) = current
            && let Some(position) = candidates.iter().position(|s| s.tag == current)
        {
            let entry = candidates.remove(position);
            candidates.insert(0, entry);
        }
        let mut probes = Vec::new();
        for server in candidates.into_iter().take(AUTO_SELECT_CANDIDATES) {
            clash
                .select_proxy(&session.manual_selector_tag, &server.tag)
                .await?;
            tokio::time::sleep(PROXY_SETTLE_DELAY).await;
            let delay = delays.get(&server.tag).copied().filter(|d| *d > 0);
            let result = probe::probe_server(
                session.mixed_port,
                &profile.id,
                &server.tag,
                delay,
                &self.probe_settings,
            )
            .await;
            let accept = result.fully_healthy()
                && result.url_test_delay.unwrap_or(i64::MAX) <= FAST_ACCEPT_DELAY_MS;
            probes.push(result);
            if accept {
                break;
            }
        }
        probe::rank_probes(&mut probes);
        let winner = probes
            .into_iter()
            .next()
            .filter(ProbeResult::has_end_to_end_connectivity)
            .ok_or_else(|| CoreError::InternetUnavailable(String::new()))?;
        clash
            .select_proxy(&session.manual_selector_tag, &winner.server_tag)
            .await?;
        Ok(winner)
    }

    /// Проход автовыбора на работающем подключении (выбор «Авто»).
    async fn run_auto_select_pass(&self, session: &RuntimeSession) {
        let Some(profile) = self.lock().active_profile().cloned() else {
            return;
        };
        self.update(|s| s.busy = true);
        let result = async {
            let clash = session.clash()?;
            let delays = self
                .load_delays(session, &server_tags(&profile))
                .await
                .unwrap_or_default();
            let current = clash
                .snapshot(&session.manual_selector_tag)
                .await?
                .selected_tag;
            let winner = self
                .best_server(session, &clash, &profile, &delays, current.as_deref())
                .await?;
            let storage = self
                .store
                .update_auto_selected_server(&profile.id, &winner.server_tag)
                .await?;
            Ok::<_, CoreError>((storage, winner, delays))
        }
        .await;
        self.update(|s| {
            s.busy = false;
            match result {
                Ok((storage, winner, delays)) => {
                    s.storage = storage;
                    s.delay_by_tag = delays;
                    let name = s.server_name(&winner.server_tag);
                    s.active_tag = Some(winner.server_tag);
                    s.set_notice(Notice::AutoSelectChose { server_name: name });
                }
                Err(e) => s.set_error(&e),
            }
        });
        self.refresh_ip(true);
    }

    pub async fn disconnect(&self) {
        // Отменяет идущее подключение.
        self.connect_generation.fetch_add(1, Ordering::SeqCst);
        self.stop_traffic();
        self.update(|s| {
            s.busy = true;
            s.stage = ConnectionStage::Stopping;
            s.clear_messages();
        });
        let result = self.stop_runtime().await;
        self.update(|s| {
            s.busy = false;
            s.reset_connection_view();
            s.delay_by_tag.clear();
            match result {
                Ok(()) => {
                    s.stage = ConnectionStage::Disconnected;
                    s.set_notice(Notice::Disconnected);
                }
                Err(e) => {
                    s.stage = ConnectionStage::Failed;
                    s.set_error(&e);
                }
            }
        });
        self.refresh_ip(false);
    }

    /// Выход из приложения: остановить ядро и вернуть прокси.
    pub async fn shutdown(&self) {
        self.connect_generation.fetch_add(1, Ordering::SeqCst);
        self.stop_traffic();
        #[cfg(unix)]
        if tokio::time::timeout(Duration::from_secs(20), self.tun.stop())
            .await
            .is_err()
        {
            // Закрытие соединения при выходе всё равно остановит ядро в помощнике.
            tracing::warn!("helper stop timed out on exit");
        }
        self.runtime.stop_for_app_exit().await;
    }

    // ---- помощник ----

    /// Запускает ядро там, где ему место: TUN — в помощнике, остальное — здесь.
    /// Другой из двух путей при этом останавливается.
    async fn start_runtime(&self, request: StartRequest) -> CoreResult<RuntimeSession> {
        if request.mode.uses_tun() {
            let _ = self.runtime.stop().await;
            #[cfg(unix)]
            return self.tun.start(&request).await;
            #[cfg(not(unix))]
            return Err(CoreError::TunHelperRequired);
        }
        #[cfg(unix)]
        let _ = self.tun.stop().await;
        self.runtime.start(request).await
    }

    async fn stop_runtime(&self) -> CoreResult<()> {
        #[cfg(unix)]
        let tun = self.tun.stop().await;
        let local = self.runtime.stop().await;
        #[cfg(unix)]
        let local = tun.and(local);
        local
    }

    /// Проверяет, установлен ли помощник и подходит ли его версия.
    pub async fn refresh_helper(&self) {
        #[cfg(unix)]
        let status = self.tun.client().status().await;
        #[cfg(not(unix))]
        let status = HelperStatus::NotInstalled;
        self.update(|s| s.helper = status);
    }

    /// Ставит помощника (macOS спросит пароль администратора) и, если всё
    /// получилось, подключает. `prompt` — текст окна с паролем.
    #[cfg(target_os = "macos")]
    pub async fn install_helper(&self, helper_binary: &Path, prompt: &str) {
        self.update(|s| {
            s.busy = true;
            s.clear_messages();
        });
        let result =
            crate::helper::install::install(helper_binary, &self.engine_path, prompt).await;
        let status = self.tun.client().status().await;
        self.update(|s| {
            s.busy = false;
            s.helper = status;
            match &result {
                Ok(()) if status != HelperStatus::Ready => s.set_error(
                    &CoreError::HelperInstallFailed("helper did not start".into()),
                ),
                // Отмену выбрал сам человек — сообщать нечего.
                Ok(()) | Err(CoreError::HelperInstallCancelled) => {}
                Err(error) => s.set_error(error),
            }
        });
        if result.is_ok() && status == HelperStatus::Ready {
            self.connect().await;
        }
    }

    fn handle_runtime_event(&self, event: RuntimeEvent) {
        match event {
            RuntimeEvent::UnexpectedExit { code } => {
                self.stop_traffic();
                self.update(|s| {
                    if s.session.is_none() {
                        return;
                    }
                    s.busy = false;
                    s.delay_by_tag.clear();
                    s.reset_connection_view();
                    if code == 0 {
                        s.stage = ConnectionStage::Disconnected;
                        s.set_notice(Notice::Disconnected);
                    } else {
                        s.stage = ConnectionStage::Failed;
                        s.set_error(&CoreError::UnexpectedExit(code));
                    }
                });
                self.refresh_ip(false);
            }
        }
    }

    fn start_traffic(&self, session: &RuntimeSession) {
        self.stop_traffic();
        let Ok(clash) = session.clash() else { return };
        let observer = self.observer.clone();
        let handle = tokio::spawn(async move {
            loop {
                let sink = observer.clone();
                let _ = clash
                    .stream_traffic(move |sample| sink.on_traffic(sample.up, sample.down))
                    .await;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        });
        if let Ok(mut task) = self.traffic_task.lock() {
            *task = Some(handle);
        }
    }

    fn stop_traffic(&self) {
        if let Ok(mut task) = self.traffic_task.lock()
            && let Some(handle) = task.take()
        {
            handle.abort();
            self.observer.on_traffic(0, 0);
        }
    }

    /// Проверяет внешний IP в фоне: напрямую и, если есть подключение,
    /// через него. `routed_only` — только адрес выхода (смена сервера).
    fn refresh_ip(&self, routed_only: bool) {
        let (generation, port) = {
            let mut s = self.lock();
            s.ip_generation += 1;
            s.routed_ip = None;
            (s.ip_generation, s.session.as_ref().map(|s| s.mixed_port))
        };
        let weak = self.this.clone();
        tokio::spawn(async move {
            let direct = if routed_only {
                None
            } else {
                ipinfo::lookup(None).await
            };
            let routed = match port {
                Some(port) => ipinfo::lookup(Some(port)).await,
                None => None,
            };
            let Some(engine) = weak.upgrade() else { return };
            engine.update(|s| {
                if s.ip_generation != generation {
                    return;
                }
                if direct.is_some() {
                    s.direct_ip = direct;
                }
                if s.session.as_ref().map(|s| s.mixed_port) == port {
                    s.routed_ip = routed;
                }
            });
        });
    }

    pub fn runtime_dir(&self) -> &Path {
        self.runtime.runtime_dir()
    }
}

struct ConnectOutcome {
    session: RuntimeSession,
    storage: StoredProfilesState,
    delays: HashMap<String, i64>,
    active_tag: Option<String>,
    auto_chose: bool,
}

fn server_tags(profile: &ProxyProfile) -> Vec<String> {
    profile.servers.iter().map(|s| s.tag.clone()).collect()
}

fn raw_name(server: &ServerEntry) -> &str {
    if server.display_name.trim().is_empty() {
        &server.tag
    } else {
        &server.display_name
    }
}

/// Имя и код страны для списка серверов.
pub fn display_name(server: &ServerEntry) -> (String, Option<String>) {
    let raw = raw_name(server);
    let normalized = normalize_server_display_text(raw, true);
    let country = extract_country_code(&normalized);
    let name = strip_country_prefix(&normalized);
    let name = if name.trim().is_empty() {
        normalized
    } else {
        name
    };
    (name, country)
}

/// Что ошибка подключения говорит о помощнике.
fn helper_status_for(error: &CoreError) -> Option<HelperStatus> {
    match error {
        CoreError::TunHelperRequired => Some(HelperStatus::NotInstalled),
        CoreError::HelperOutdated(_) => Some(HelperStatus::Outdated),
        _ => None,
    }
}

/// Сокет помощника. `GORION_HELPER_SOCKET` — для проверок с тестовым
/// помощником без root.
#[cfg(unix)]
fn helper_socket() -> PathBuf {
    std::env::var_os("GORION_HELPER_SOCKET")
        .map_or_else(|| PathBuf::from(crate::helper::SOCKET_PATH), PathBuf::from)
}

fn build_snapshot(state: &State) -> EngineSnapshot {
    let active = state.active_profile();
    // Как в эталоне (map_view.dart): страна выхода — по IP через подключение,
    // иначе по прямому IP; точка — по имени сервера, если оно что-то говорит.
    let route_country = state
        .routed_ip
        .as_ref()
        .or(state.direct_ip.as_ref())
        .map(|ip| ip.country_code.clone());
    let display_server = active.and_then(|p| {
        let tag = state.active_tag.as_deref().or(p.selected_server_tag())?;
        p.servers.iter().find(|s| s.tag == tag)
    });
    let display_raw = display_server.map(raw_name);
    let showing_route =
        matches!(state.stage, ConnectionStage::Connected) || state.session.is_some();
    EngineSnapshot {
        revision: state.revision,
        bootstrapping: state.bootstrapping,
        busy: state.busy,
        measuring_delays: state.measuring_delays,
        mode: state.mode,
        stage: state.stage,
        profiles: state
            .storage
            .profiles
            .iter()
            .map(|p| ProfileView {
                id: p.id.clone(),
                name: p.name.clone(),
                server_count: p.servers.len() as u32,
                updated_at: p.updated_at.clone(),
                subscription: p.subscription_info.clone(),
            })
            .collect(),
        active_profile_id: active.map(|p| p.id.clone()),
        servers: active
            .map(|p| {
                p.servers
                    .iter()
                    .map(|s| {
                        let (name, country_code) = display_name(s);
                        let raw = raw_name(s);
                        ServerView {
                            tag: s.tag.clone(),
                            name,
                            country_code,
                            kind: s.kind.clone(),
                            host: s.host.clone(),
                            port: s.port,
                            delay_ms: state.delay_by_tag.get(&s.tag).copied(),
                            map_country_code: geo::extract_mappable_country_code(raw),
                            location: geo::resolve_destination(Some(raw), None),
                        }
                    })
                    .collect()
            })
            .unwrap_or_default(),
        selected_tag: active
            .and_then(|p| p.selected_server_tag())
            .map(str::to_owned),
        active_tag: state.active_tag.clone(),
        connected_at_ms: state.connected_at_ms,
        local_proxy_port: state.session.as_ref().map(|s| s.mixed_port),
        notice: state.notice.clone(),
        notice_id: state.notice_id,
        error: state.error.clone(),
        can_undo_remove: state.removed.is_some(),
        direct_ip: state.direct_ip.clone(),
        routed_ip: state.routed_ip.clone(),
        source_location: geo::resolve_source(state.direct_ip.as_ref()),
        destination_location: geo::resolve_destination(display_raw, route_country.as_deref()),
        destination_country: display_raw
            .and_then(geo::extract_mappable_country_code)
            .or_else(|| route_country.filter(|_| showing_route)),
        helper: state.helper,
    }
}
