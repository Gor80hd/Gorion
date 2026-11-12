//! Жизненный цикл локального ядра: запуск, остановка, восстановление.
//! Эталон: `lib/features/runtime/data/singbox_runtime_service.dart`.
//!
//! Ядро — sing-box или свой движок `gorion-engine` (ADR-0005). Движок
//! понимает ту же конфигурацию и тот же Clash API, поэтому всё остальное
//! (системный прокси, маркеры, watchdog, проверки) общее. Движок берётся,
//! если сам подтвердил, что профиль ему по силам (`gorion-engine check`).
//!
//! Договор надёжности:
//! - любая неудачная попытка запуска убирает за собой всё, что успела
//!   поднять (процесс, прокси, маркеры);
//! - `stop()` идемпотентен и не зависает: у внешних команд жёсткие
//!   тайм-ауты, завершение — SIGTERM, затем SIGKILL;
//! - неожиданный выход ядра восстанавливает системный прокси в той же
//!   очереди, что и запуск, — гонки с новым запуском нет;
//! - маркеры на диске позволяют следующему запуску (или watchdog)
//!   восстановиться после kill -9, сбоя и потери питания.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::{Mutex, watch};

use super::clash::ClashClient;
use super::process::{
    MarkerMatch, ProcessMarker, ReservedPort, Signal, current_pid, delete_marker, inspect_marker,
    is_alive, read_marker, run_with_timeout, send_signal, wait_for_exit, write_marker,
};
use super::system_proxy::{ProxyLease, SystemProxyService};
use super::watchdog;
use super::{CoreKind, RuntimeMode};
use crate::config_builder::{BuildRequest, SplitTunnelRoute, build};
use crate::error::{CoreError, CoreResult};

const MAX_STARTUP_ATTEMPTS: usize = 2;
const MAX_LOG_LINES: usize = 500;
/// Имя движка рядом с sing-box в сборке приложения.
pub const ENGINE_BINARY: &str = "gorion-engine";
/// `GORION_CORE=sing-box` — всегда sing-box (для сравнения и отладки).
const CORE_OVERRIDE_ENV: &str = "GORION_CORE";

#[derive(Debug, Clone)]
pub struct StartRequest {
    pub profile_id: String,
    pub template_config: String,
    pub mode: RuntimeMode,
    pub selected_server_tag: Option<String>,
    pub url_test_url: String,
    pub bypass_steam: bool,
    pub split_tunnel: Option<SplitTunnelRoute>,
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeSession {
    pub profile_id: String,
    pub mode: RuntimeMode,
    pub pid: i32,
    pub controller_port: u16,
    pub mixed_port: u16,
    pub secret: String,
    pub manual_selector_tag: String,
    pub auto_group_tag: String,
    pub config_path: PathBuf,
    #[serde(default)]
    pub core: CoreKind,
}

impl RuntimeSession {
    pub fn clash(&self) -> CoreResult<ClashClient> {
        ClashClient::new(self.controller_port, &self.secret)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeEvent {
    /// Ядро завершилось само, не по `stop()`.
    UnexpectedExit { code: i32 },
}

pub type EventSink = Arc<dyn Fn(RuntimeEvent) + Send + Sync>;

struct Running {
    session: RuntimeSession,
    exit: watch::Receiver<Option<i32>>,
    lease: Option<ProxyLease>,
    stopping: Arc<AtomicBool>,
    generation: u64,
}

#[derive(Default)]
struct Inner {
    running: Option<Running>,
}

pub struct RuntimeService {
    runtime_dir: PathBuf,
    singbox_path: PathBuf,
    proxy: SystemProxyService,
    inner: Mutex<Inner>,
    generation: AtomicU64,
    logs: Arc<StdMutex<VecDeque<String>>>,
    events: EventSink,
    install_login_recovery: bool,
}

impl RuntimeService {
    pub fn new(runtime_dir: PathBuf, singbox_path: PathBuf, events: EventSink) -> Arc<Self> {
        Arc::new(Self {
            runtime_dir,
            singbox_path,
            proxy: SystemProxyService::system(),
            inner: Mutex::new(Inner::default()),
            generation: AtomicU64::new(0),
            logs: Arc::new(StdMutex::new(VecDeque::new())),
            events,
            install_login_recovery: true,
        })
    }

    pub fn runtime_dir(&self) -> &Path {
        &self.runtime_dir
    }

    pub fn logs(&self) -> Vec<String> {
        self.logs
            .lock()
            .map(|l| l.iter().cloned().collect())
            .unwrap_or_default()
    }

    fn log(&self, line: impl Into<String>) {
        push_log(&self.logs, line.into());
    }

    fn log_sink(&self) -> impl Fn(String) + Send + Sync + use<> {
        let logs = self.logs.clone();
        move |line| push_log(&logs, line)
    }

    pub async fn session(&self) -> Option<RuntimeSession> {
        self.inner
            .lock()
            .await
            .running
            .as_ref()
            .map(|r| r.session.clone())
    }

    pub async fn start(self: &Arc<Self>, request: StartRequest) -> CoreResult<RuntimeSession> {
        self.start_with(request, true).await
    }

    /// `allow_engine: false` — только sing-box (запасной путь, если свой
    /// движок не смог подключиться).
    pub async fn start_with(
        self: &Arc<Self>,
        request: StartRequest,
        allow_engine: bool,
    ) -> CoreResult<RuntimeSession> {
        let mut inner = self.inner.lock().await;
        tokio::fs::create_dir_all(&self.runtime_dir).await?;
        self.stop_locked(&mut inner).await?;
        self.cleanup_orphaned_process().await;
        if let Some(marker) = read_marker(&self.runtime_dir).await {
            return Err(CoreError::RecoveryPending(format!(
                "не удалось проверить прошлое ядро (PID {}); второй запуск заблокирован, чтобы не было конфликта портов и прокси",
                marker.pid
            )));
        }
        let sink = self.log_sink();
        self.proxy.cleanup_orphaned(&self.runtime_dir, &sink).await;
        if !self.singbox_path.is_file() {
            return Err(CoreError::CoreBinaryMissing(
                self.singbox_path.display().to_string(),
            ));
        }
        let mut last_error = None;
        for attempt in 1..=MAX_STARTUP_ATTEMPTS {
            match self
                .try_start_once(&mut inner, &request, allow_engine)
                .await
            {
                Ok(session) => return Ok(session),
                Err(error) => {
                    let retry = matches!(error, CoreError::ControllerUnavailable(_))
                        && attempt < MAX_STARTUP_ATTEMPTS;
                    self.log(format!("попытка запуска {attempt}: {error}"));
                    last_error = Some(error);
                    if !retry {
                        break;
                    }
                }
            }
        }
        Err(last_error.unwrap_or_else(|| CoreError::CoreStartFailed("неизвестная ошибка".into())))
    }

    async fn try_start_once(
        self: &Arc<Self>,
        inner: &mut Inner,
        request: &StartRequest,
        allow_engine: bool,
    ) -> CoreResult<RuntimeSession> {
        let result = self.try_start_inner(inner, request, allow_engine).await;
        if result.is_err() {
            // Всё, что успела поднять попытка, уходит вместе с ней.
            let _ = self.stop_locked(inner).await;
        }
        result
    }

    async fn try_start_inner(
        self: &Arc<Self>,
        inner: &mut Inner,
        request: &StartRequest,
        allow_engine: bool,
    ) -> CoreResult<RuntimeSession> {
        let controller = ReservedPort::reserve()?;
        let mixed = ReservedPort::reserve()?;
        let secret = uuid::Uuid::new_v4().to_string();
        let built = build(&BuildRequest {
            template_config: &request.template_config,
            mode: request.mode,
            mixed_port: mixed.port,
            controller_port: controller.port,
            controller_secret: &secret,
            url_test_url: &request.url_test_url,
            selected_server_tag: request.selected_server_tag.as_deref(),
            selectable_tags_override: None,
            split_tunnel: request.split_tunnel.clone(),
        })?;
        let config_path = self.runtime_dir.join("current-config.json");
        tokio::fs::write(&config_path, &built.config_json).await?;

        let config = config_path.to_string_lossy().into_owned();
        let core = if allow_engine && self.engine_accepts(request.mode, &config).await {
            CoreKind::Engine
        } else {
            CoreKind::SingBox
        };
        let binary_path = match core {
            CoreKind::Engine => self.engine_path(),
            CoreKind::SingBox => self.singbox_path.clone(),
        };
        let binary = binary_path.to_string_lossy().into_owned();
        if core == CoreKind::SingBox {
            let check =
                run_with_timeout(&binary, &["check", "-c", &config], Duration::from_secs(20))
                    .await?;
            if check.status != 0 {
                return Err(CoreError::InvalidRuntimeConfig(
                    check.stderr.trim().to_owned(),
                ));
            }
        }
        let core_name = core.name();
        self.log(format!(
            "запуск {core_name}: профиль {}, режим {}, контроллер {}, прокси {}",
            request.profile_id,
            request.mode.as_str(),
            controller.port,
            mixed.port
        ));
        let controller_port = controller.release();
        let mixed_port = mixed.release();

        let mut child = tokio::process::Command::new(&binary_path)
            .args(["run", "-c", &config])
            .current_dir(&self.runtime_dir)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| CoreError::CoreStartFailed(e.to_string()))?;
        let pid = child.id().map(|p| p as i32).unwrap_or(0);
        self.pipe_output(child.stdout.take(), "");
        self.pipe_output(child.stderr.take(), "! ");

        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        let (exit_tx, exit_rx) = watch::channel(None);
        let stopping = Arc::new(AtomicBool::new(false));
        let session = RuntimeSession {
            profile_id: request.profile_id.clone(),
            mode: request.mode,
            pid,
            controller_port,
            mixed_port,
            secret,
            manual_selector_tag: built.manual_selector_tag,
            auto_group_tag: built.auto_group_tag,
            config_path: config_path.clone(),
            core,
        };
        inner.running = Some(Running {
            session: session.clone(),
            exit: exit_rx.clone(),
            lease: None,
            stopping: stopping.clone(),
            generation,
        });
        {
            let service = Arc::clone(self);
            tokio::spawn(async move {
                let code = child.wait().await.ok().and_then(|s| s.code()).unwrap_or(-1);
                let _ = exit_tx.send(Some(code));
                service.handle_exit(generation, code).await;
            });
        }
        self.log(format!("{core_name} запущен, PID {pid}"));
        write_marker(
            &self.runtime_dir,
            &ProcessMarker {
                pid,
                binary_path: Some(binary),
                config_path: Some(config),
                launcher_pid: Some(current_pid()),
            },
        )
        .await?;
        let proxy_port = request.mode.uses_system_proxy().then_some(mixed_port);
        if let Err(e) = watchdog::arm(
            &self.runtime_dir,
            current_pid(),
            pid,
            proxy_port,
            self.install_login_recovery,
        )
        .await
        {
            self.log(format!("watchdog не запущен: {e}"));
        }

        let clash = session.clash()?;
        let exit_probe = exit_rx.clone();
        clash
            .wait_until_ready(Duration::from_secs(12), move || *exit_probe.borrow())
            .await?;

        if request.mode.uses_system_proxy() {
            let sink = self.log_sink();
            let lease = self
                .proxy
                .enable(&self.runtime_dir, mixed_port, request.bypass_steam, &sink)
                .await?;
            if let Some(running) = inner.running.as_mut() {
                running.lease = Some(lease);
            }
        }
        if exit_rx.borrow().is_some() {
            return Err(CoreError::CoreStartFailed(
                "ядро завершилось во время включения системного прокси".into(),
            ));
        }
        self.log(format!("контроллер {core_name} готов"));
        Ok(session)
    }

    fn engine_path(&self) -> PathBuf {
        self.singbox_path.with_file_name(ENGINE_BINARY)
    }

    /// Свой движок подходит: режим без TUN, движок есть в сборке и сам
    /// принял конфигурацию. Причина отказа — в журнал (без секретов: движок
    /// называет только протокол и номер сервера).
    async fn engine_accepts(&self, mode: RuntimeMode, config: &str) -> bool {
        if mode.uses_tun()
            || std::env::var(CORE_OVERRIDE_ENV).is_ok_and(|core| core == CoreKind::SingBox.name())
        {
            return false;
        }
        let engine = self.engine_path();
        if !engine.is_file() {
            return false;
        }
        let engine = engine.to_string_lossy().into_owned();
        match run_with_timeout(&engine, &["check", "-c", config], Duration::from_secs(10)).await {
            Ok(check) if check.status == 0 => true,
            Ok(check) => {
                self.log(format!(
                    "свой движок не подходит, нужен sing-box: {}",
                    check.stderr.trim()
                ));
                false
            }
            Err(error) => {
                self.log(format!("проверка своего движка не удалась: {error}"));
                false
            }
        }
    }

    fn pipe_output<R>(&self, reader: Option<R>, prefix: &'static str)
    where
        R: tokio::io::AsyncRead + Unpin + Send + 'static,
    {
        let Some(reader) = reader else { return };
        let logs = self.logs.clone();
        tokio::spawn(async move {
            let mut lines = BufReader::new(reader).lines();
            while let Ok(Some(line)) = lines.next_line().await {
                push_log(&logs, format!("{prefix}{line}"));
            }
        });
    }

    /// Неожиданный выход ядра. Идёт через ту же блокировку, что и запуск.
    async fn handle_exit(&self, generation: u64, code: i32) {
        let mut inner = self.inner.lock().await;
        let Some(running) = inner.running.as_ref() else {
            return;
        };
        self.log(format!(
            "{} завершился с кодом {code}",
            running.session.core.name()
        ));
        if running.generation != generation || running.stopping.load(Ordering::SeqCst) {
            return;
        }
        let Some(running) = inner.running.take() else {
            return;
        };
        if running.lease.is_some() || running.session.mode.uses_system_proxy() {
            let sink = self.log_sink();
            if let Err(e) = self
                .proxy
                .restore(&self.runtime_dir, running.lease.as_ref(), &sink)
                .await
            {
                self.log(format!("не удалось вернуть системный прокси: {e}"));
            }
        }
        if !SystemProxyService::journal_exists(&self.runtime_dir).await {
            delete_marker(&self.runtime_dir, Some(running.session.pid)).await;
        }
        (self.events)(RuntimeEvent::UnexpectedExit { code });
    }

    pub async fn stop(&self) -> CoreResult<()> {
        let mut inner = self.inner.lock().await;
        self.stop_locked(&mut inner).await
    }

    async fn stop_locked(&self, inner: &mut Inner) -> CoreResult<()> {
        let running = inner.running.take();
        if running.is_none()
            && let Some(marker) = read_marker(&self.runtime_dir).await
            && marker
                .launcher_pid
                .is_some_and(|p| p != current_pid() && is_alive(p))
        {
            return Ok(());
        }
        let mut cleanup_error = None;
        // Сначала прокси, потом ядро: пока идёт восстановление, старое ядро
        // ещё обслуживает порт, и система не смотрит в мёртвую точку.
        let has_journal = SystemProxyService::journal_exists(&self.runtime_dir).await;
        let lease = running.as_ref().and_then(|r| r.lease.as_ref());
        if lease.is_some()
            || has_journal
            || running
                .as_ref()
                .is_some_and(|r| r.session.mode.uses_system_proxy())
        {
            let sink = self.log_sink();
            if let Err(e) = self.proxy.restore(&self.runtime_dir, lease, &sink).await {
                self.log(format!("не удалось вернуть системный прокси: {e}"));
                cleanup_error = Some(e);
            }
        }
        let Some(running) = running else {
            return cleanup_error.map_or(Ok(()), Err);
        };
        running.stopping.store(true, Ordering::SeqCst);
        let pid = running.session.pid;
        let core_name = running.session.core.name();
        self.log(format!("остановка {core_name}, PID {pid}"));
        // SIGTERM: sing-box сам закрывает TUN и убирает маршруты.
        send_signal(pid, Signal::Terminate);
        if !wait_exit(running.exit.clone(), Duration::from_secs(4)).await {
            self.log(format!(
                "{core_name} не завершился сам, завершаем принудительно"
            ));
            send_signal(pid, Signal::Kill);
            if !wait_exit(running.exit.clone(), Duration::from_secs(2)).await {
                // Маркер остаётся: следующая очистка найдёт процесс.
                self.log(format!(
                    "PID {pid} не завершился после SIGKILL; маркер сохранён"
                ));
                return cleanup_error.map_or(Ok(()), Err);
            }
        }
        if !SystemProxyService::journal_exists(&self.runtime_dir).await {
            delete_marker(&self.runtime_dir, Some(pid)).await;
        }
        cleanup_error.map_or(Ok(()), Err)
    }

    /// Остановка при выходе из приложения с ограничением по времени.
    pub async fn stop_for_app_exit(&self) {
        if tokio::time::timeout(Duration::from_secs(30), self.stop())
            .await
            .is_err()
        {
            self.log(
                "остановка не уложилась во время выхода; доделают watchdog и следующий запуск",
            );
        }
    }

    /// Восстановление после прошлой сессии. Вызывается при каждом старте
    /// приложения: сбой или перезагрузка не должны оставить машину без сети.
    pub async fn recover_previous_session(&self) {
        let _inner = self.inner.lock().await;
        let marker = read_marker(&self.runtime_dir).await;
        let launcher_alive = marker
            .as_ref()
            .and_then(|m| m.launcher_pid)
            .is_some_and(|p| p != current_pid() && is_alive(p));
        if launcher_alive {
            return;
        }
        let sink = self.log_sink();
        self.proxy.cleanup_orphaned(&self.runtime_dir, &sink).await;
        if marker.is_some() {
            self.cleanup_orphaned_process().await;
        }
    }

    async fn cleanup_orphaned_process(&self) {
        let Some(marker) = read_marker(&self.runtime_dir).await else {
            return;
        };
        if marker
            .launcher_pid
            .is_some_and(|p| p != current_pid() && is_alive(p))
        {
            self.log("runtime принадлежит другому экземпляру Gorion — не трогаем");
            return;
        }
        match inspect_marker(&marker).await {
            MarkerMatch::Matches => {}
            MarkerMatch::Mismatches | MarkerMatch::MissingProcess => {
                delete_marker(&self.runtime_dir, Some(marker.pid)).await;
                return;
            }
            MarkerMatch::Inconclusive => {
                self.log(format!(
                    "не удалось безопасно проверить PID {}; маркер сохранён",
                    marker.pid
                ));
                return;
            }
        }
        send_signal(marker.pid, Signal::Terminate);
        // Отправленный сигнал — ещё не доказательство остановки.
        if wait_for_exit(marker.pid, Duration::from_secs(4)).await {
            delete_marker(&self.runtime_dir, Some(marker.pid)).await;
        } else {
            self.log(format!(
                "осиротевшее ядро PID {} не остановилось; маркер сохранён",
                marker.pid
            ));
        }
    }
}

async fn wait_exit(mut exit: watch::Receiver<Option<i32>>, timeout: Duration) -> bool {
    tokio::time::timeout(timeout, exit.wait_for(Option::is_some))
        .await
        .is_ok()
}

fn push_log(logs: &StdMutex<VecDeque<String>>, line: String) {
    tracing::debug!(target: "gorion::runtime", "{line}");
    if let Ok(mut logs) = logs.lock() {
        if logs.len() >= MAX_LOG_LINES {
            logs.pop_front();
        }
        logs.push_back(line);
    }
}
