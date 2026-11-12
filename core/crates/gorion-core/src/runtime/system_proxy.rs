//! Системный прокси macOS через `networksetup` с журналом восстановления.
//! Эталон: `macos_system_proxy.dart`, `system_proxy_service.dart`.
//!
//! Гарантии (docs/runtime-audit.md):
//! - журнал пишется до любого изменения системы, атомарно;
//! - откат трогает только то, что всё ещё указывает на наш порт, и не
//!   перезаписывает правки пользователя;
//! - HTTP, HTTPS, SOCKS восстанавливаются независимо; ошибка одного не
//!   останавливает остальные;
//! - неудачный откат сохраняет журнал для следующей попытки;
//! - PAC и автообнаружение выключаются на время подключения и
//!   возвращаются, если пользователь их не трогал.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::error::{CoreError, CoreResult};
use crate::runtime::process::{CommandOutput, run_with_timeout};
use crate::storage::{read_json, write_json};

pub const SYSTEM_PROXY_MARKER_FILE: &str = "system-proxy.json";
const NETWORKSETUP: &str = "/usr/sbin/networksetup";

pub const MANAGED_BYPASS_ENTRIES: &[&str] = &[
    "localhost",
    "127.0.0.1",
    "::1",
    "*.local",
    "169.254/16",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
];

pub const STEAM_BYPASS_ENTRIES: &[&str] = &[
    "steampowered.com",
    "steamcommunity.com",
    "steamstatic.com",
    "steamcontent.com",
    "steamserver.net",
    "steamgames.com",
    "steamusercontent.com",
    "valvesoftware.com",
];

pub fn managed_bypass_domains(existing: &[String], bypass_steam: bool) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut result = Vec::new();
    let extra = MANAGED_BYPASS_ENTRIES
        .iter()
        .chain(if bypass_steam {
            STEAM_BYPASS_ENTRIES
        } else {
            &[]
        })
        .map(|s| (*s).to_owned());
    for entry in existing.iter().cloned().chain(extra) {
        if seen.insert(entry.clone()) {
            result.push(entry);
        }
    }
    result
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EndpointState {
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub server: Option<String>,
    #[serde(default)]
    pub port: Option<i64>,
    #[serde(default)]
    pub authenticated: bool,
}

impl EndpointState {
    pub fn points_to(&self, managed_port: i64) -> bool {
        let server = self.server.as_deref().map(|s| s.trim().to_lowercase());
        matches!(server.as_deref(), Some("127.0.0.1" | "localhost"))
            && self.port == Some(managed_port)
            && managed_port > 0
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceProxyState {
    pub service: String,
    pub web: EndpointState,
    pub secure_web: EndpointState,
    pub socks: EndpointState,
    #[serde(default)]
    pub bypass_domains: Vec<String>,
    #[serde(default)]
    pub auto_config_enabled: bool,
    #[serde(default)]
    pub auto_config_url: Option<String>,
    #[serde(default)]
    pub auto_discovery_enabled: bool,
}

/// Журнал на диске (`system-proxy.json`), формат совместим с Flutter-версией.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyJournal {
    pub platform: String,
    pub managed_port: i64,
    #[serde(default)]
    pub bypass_steam: bool,
    pub services: Vec<ServiceProxyState>,
}

/// Исполнитель команд — подменяется в тестах.
pub trait CommandRunner: Send + Sync {
    fn run<'a>(
        &'a self,
        args: Vec<String>,
    ) -> futures_util::future::BoxFuture<'a, CoreResult<CommandOutput>>;
}

pub struct NetworkSetup;

impl CommandRunner for NetworkSetup {
    fn run<'a>(
        &'a self,
        args: Vec<String>,
    ) -> futures_util::future::BoxFuture<'a, CoreResult<CommandOutput>> {
        Box::pin(async move {
            let refs: Vec<&str> = args.iter().map(String::as_str).collect();
            run_with_timeout(NETWORKSETUP, &refs, Duration::from_secs(10)).await
        })
    }
}

pub struct MacosProxyBackend {
    runner: Arc<dyn CommandRunner>,
}

impl MacosProxyBackend {
    pub fn new(runner: Arc<dyn CommandRunner>) -> Self {
        Self { runner }
    }

    async fn run(&self, args: &[&str]) -> CoreResult<String> {
        let output = self
            .runner
            .run(args.iter().map(|s| (*s).to_owned()).collect())
            .await?;
        if output.status != 0 || output.stdout.contains("** Error:") {
            let detail = if output.stderr.trim().is_empty() {
                output.stdout.trim()
            } else {
                output.stderr.trim()
            };
            return Err(CoreError::SystemProxy(format!(
                "networksetup {}: {detail}",
                args.join(" ")
            )));
        }
        Ok(output.stdout)
    }

    /// Включённые сетевые службы; отключённые (`*`) и заголовок пропускаются.
    pub async fn list_active_services(&self) -> CoreResult<Vec<String>> {
        let output = self.run(&["-listallnetworkservices"]).await?;
        Ok(output
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.starts_with('*') && !l.contains("asterisk"))
            .map(str::to_owned)
            .collect())
    }

    pub async fn read_service(&self, service: &str) -> CoreResult<ServiceProxyState> {
        let web = parse_endpoint(&self.run(&["-getwebproxy", service]).await?);
        let secure_web = parse_endpoint(&self.run(&["-getsecurewebproxy", service]).await?);
        let socks = parse_endpoint(&self.run(&["-getsocksfirewallproxy", service]).await?);
        let bypass_domains = self
            .run(&["-getproxybypassdomains", service])
            .await?
            .lines()
            .map(str::trim)
            .filter(|l| !l.is_empty() && !l.contains("aren't any"))
            .map(str::to_owned)
            .collect();
        let auto_config = self.run(&["-getautoproxyurl", service]).await?;
        let auto_discovery = self.run(&["-getproxyautodiscovery", service]).await?;
        let auto_url = auto_config
            .lines()
            .find_map(|l| l.strip_prefix("URL: "))
            .map(str::trim)
            .filter(|u| *u != "(null)")
            .map(str::to_owned);
        Ok(ServiceProxyState {
            service: service.to_owned(),
            web,
            secure_web,
            socks,
            bypass_domains,
            auto_config_enabled: auto_config.lines().any(|l| l == "Enabled: Yes"),
            auto_config_url: auto_url,
            auto_discovery_enabled: auto_discovery.trim().ends_with("On"),
        })
    }

    pub async fn apply_managed(
        &self,
        saved: &ServiceProxyState,
        port: i64,
        bypass_steam: bool,
    ) -> CoreResult<()> {
        let service = saved.service.as_str();
        let port = port.to_string();
        self.run(&["-setwebproxy", service, "127.0.0.1", &port])
            .await?;
        self.run(&["-setsecurewebproxy", service, "127.0.0.1", &port])
            .await?;
        self.run(&["-setsocksfirewallproxy", service, "127.0.0.1", &port])
            .await?;
        let bypass = managed_bypass_domains(&saved.bypass_domains, bypass_steam);
        let mut args = vec!["-setproxybypassdomains", service];
        args.extend(bypass.iter().map(String::as_str));
        self.run(&args).await?;
        self.run(&["-setautoproxystate", service, "off"]).await?;
        self.run(&["-setproxyautodiscovery", service, "off"])
            .await?;
        Ok(())
    }

    /// Возвращает службу к `saved`, трогая только то, что ещё наше.
    pub async fn restore_service(
        &self,
        saved: &ServiceProxyState,
        current: &ServiceProxyState,
        managed_port: i64,
        managed_bypass: &[String],
    ) -> CoreResult<()> {
        let mut first_error = None;
        let service = saved.service.as_str();
        for (command, previous, now) in [
            ("-setwebproxy", &saved.web, &current.web),
            ("-setsecurewebproxy", &saved.secure_web, &current.secure_web),
            ("-setsocksfirewallproxy", &saved.socks, &current.socks),
        ] {
            if now.points_to(managed_port)
                && let Err(e) = self.restore_endpoint(service, command, previous).await
            {
                first_error.get_or_insert(e);
            }
        }
        let current_set: HashSet<&String> = current.bypass_domains.iter().collect();
        let managed_set: HashSet<&String> = managed_bypass.iter().collect();
        if current_set == managed_set {
            let mut args = vec!["-setproxybypassdomains", service];
            if saved.bypass_domains.is_empty() {
                args.push("Empty");
            } else {
                args.extend(saved.bypass_domains.iter().map(String::as_str));
            }
            if let Err(e) = self.run(&args).await {
                first_error.get_or_insert(e);
            }
        }
        if saved.auto_config_enabled
            && !current.auto_config_enabled
            && current.auto_config_url == saved.auto_config_url
            && let Err(e) = self.run(&["-setautoproxystate", service, "on"]).await
        {
            first_error.get_or_insert(e);
        }
        if saved.auto_discovery_enabled
            && !current.auto_discovery_enabled
            && let Err(e) = self.run(&["-setproxyautodiscovery", service, "on"]).await
        {
            first_error.get_or_insert(e);
        }
        first_error.map_or(Ok(()), Err)
    }

    async fn restore_endpoint(
        &self,
        service: &str,
        command: &str,
        saved: &EndpointState,
    ) -> CoreResult<()> {
        // Сначала всегда переписываем сервер и порт: иначе наш адрес остался
        // бы под выключенным переключателем и стал мёртвым прокси, если
        // пользователь включит его вручную. `-set*proxy` заодно включает
        // endpoint, поэтому выключенный раньше — выключаем обратно.
        let server = saved
            .server
            .as_deref()
            .map(str::trim)
            .unwrap_or_default()
            .to_owned();
        let port = saved.port.unwrap_or(0).to_string();
        let restored = self.run(&[command, service, &server, &port]).await;
        if !saved.enabled || restored.is_err() {
            let state_command = format!("{command}state");
            self.run(&[&state_command, service, "off"]).await?;
        }
        restored.map(|_| ())
    }
}

fn parse_endpoint(output: &str) -> EndpointState {
    let mut state = EndpointState::default();
    for line in output.lines() {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        if key.is_empty() {
            continue;
        }
        let value = value.trim();
        match key.trim().to_lowercase().as_str() {
            "enabled" => state.enabled = value.eq_ignore_ascii_case("yes"),
            "authenticated proxy enabled" => {
                state.authenticated = value == "1" || value.eq_ignore_ascii_case("yes")
            }
            "server" => state.server = (!value.is_empty()).then(|| value.to_owned()),
            "port" => state.port = value.parse().ok(),
            _ => {}
        }
    }
    state
}

/// Активный системный прокси (журнал в памяти).
#[derive(Debug, Clone)]
pub struct ProxyLease {
    pub journal: ProxyJournal,
}

pub struct SystemProxyService {
    backend: MacosProxyBackend,
}

impl SystemProxyService {
    pub fn new(runner: Arc<dyn CommandRunner>) -> Self {
        Self {
            backend: MacosProxyBackend::new(runner),
        }
    }

    pub fn system() -> Self {
        Self::new(Arc::new(NetworkSetup))
    }

    pub fn journal_path(runtime_dir: &Path) -> PathBuf {
        runtime_dir.join(SYSTEM_PROXY_MARKER_FILE)
    }

    pub async fn journal_exists(runtime_dir: &Path) -> bool {
        tokio::fs::try_exists(Self::journal_path(runtime_dir))
            .await
            .unwrap_or(false)
    }

    pub async fn enable(
        &self,
        runtime_dir: &Path,
        port: u16,
        bypass_steam: bool,
        log: &(dyn Fn(String) + Send + Sync),
    ) -> CoreResult<ProxyLease> {
        if !cfg!(target_os = "macos") {
            return Err(CoreError::Unsupported(
                "системный прокси на этой ОС пока не перенесён".into(),
            ));
        }
        if Self::journal_exists(runtime_dir).await {
            return Err(CoreError::RecoveryPending(
                "прошлое восстановление системного прокси не завершено".into(),
            ));
        }
        let services = self.backend.list_active_services().await?;
        if services.is_empty() {
            return Err(CoreError::SystemProxy("нет активных сетевых служб".into()));
        }
        // Сначала снимок всех служб, потом журнал, потом изменения.
        let mut saved = Vec::new();
        for service in &services {
            let state = self.backend.read_service(service).await?;
            if [&state.web, &state.secure_web, &state.socks]
                .iter()
                .any(|e| e.authenticated)
            {
                return Err(CoreError::SystemProxy(format!(
                    "у службы «{service}» прокси с паролем — используйте ручной режим, чтобы не потерять его"
                )));
            }
            saved.push(state);
        }
        let journal = ProxyJournal {
            platform: "macos".into(),
            managed_port: i64::from(port),
            bypass_steam,
            services: saved,
        };
        write_json(&Self::journal_path(runtime_dir), &journal).await?;
        let mut first_error = None;
        for state in &journal.services {
            if let Err(e) = self
                .backend
                .apply_managed(state, i64::from(port), bypass_steam)
                .await
            {
                log(format!(
                    "не удалось включить прокси для «{}»: {e}",
                    state.service
                ));
                first_error.get_or_insert(e);
            }
        }
        if let Some(error) = first_error {
            // Служба могла упасть, поменяв только один endpoint — откатываем все.
            let _ = self.restore_journal(runtime_dir, &journal, log).await;
            return Err(CoreError::SystemProxy(format!(
                "не удалось включить системный прокси: {error}"
            )));
        }
        log(format!(
            "системный прокси macOS включён на 127.0.0.1:{port} для {} служб",
            journal.services.len()
        ));
        Ok(ProxyLease { journal })
    }

    /// Восстановление по аренде или по журналу на диске.
    pub async fn restore(
        &self,
        runtime_dir: &Path,
        lease: Option<&ProxyLease>,
        log: &(dyn Fn(String) + Send + Sync),
    ) -> CoreResult<()> {
        let journal = match lease {
            Some(lease) => lease.journal.clone(),
            None => match read_json::<Value>(&Self::journal_path(runtime_dir)).await {
                Ok(None) => return Ok(()),
                Ok(Some(value)) => serde_json::from_value::<ProxyJournal>(value).map_err(|_| {
                    CoreError::RecoveryPending(
                        "журнал восстановления прокси повреждён — не удаляем его".into(),
                    )
                })?,
                Err(_) => {
                    return Err(CoreError::RecoveryPending(
                        "журнал восстановления прокси не читается".into(),
                    ));
                }
            },
        };
        self.restore_journal(runtime_dir, &journal, log).await
    }

    async fn restore_journal(
        &self,
        runtime_dir: &Path,
        journal: &ProxyJournal,
        log: &(dyn Fn(String) + Send + Sync),
    ) -> CoreResult<()> {
        if journal.managed_port <= 0 || journal.services.is_empty() {
            return Err(CoreError::RecoveryPending(
                "журнал восстановления некорректен — не удаляем его".into(),
            ));
        }
        let mut failed = false;
        for saved in &journal.services {
            let result = async {
                let current = self.backend.read_service(&saved.service).await?;
                let managed = managed_bypass_domains(&saved.bypass_domains, journal.bypass_steam);
                self.backend
                    .restore_service(saved, &current, journal.managed_port, &managed)
                    .await
            }
            .await;
            if let Err(e) = result {
                failed = true;
                log(format!(
                    "не удалось вернуть прокси для «{}»: {e}",
                    saved.service
                ));
            }
        }
        if failed {
            return Err(CoreError::RecoveryPending(
                "часть настроек прокси не восстановлена; журнал сохранён".into(),
            ));
        }
        let _ = tokio::fs::remove_file(Self::journal_path(runtime_dir)).await;
        log("системный прокси macOS возвращён в исходное состояние".into());
        Ok(())
    }

    /// Чинит состояние после прошлой сессии (сбой, kill -9, потеря питания).
    pub async fn cleanup_orphaned(&self, runtime_dir: &Path, log: &(dyn Fn(String) + Send + Sync)) {
        if !Self::journal_exists(runtime_dir).await {
            return;
        }
        if let Err(e) = self.restore(runtime_dir, None, log).await {
            log(format!(
                "не удалось убрать оставшийся системный прокси: {e}"
            ));
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use std::collections::HashMap;
    use std::sync::Mutex;

    use super::*;

    /// Поддельный networksetup: хранит состояние одной-двух служб.
    #[derive(Default)]
    struct FakeNetworkSetup {
        services: Mutex<HashMap<String, ServiceProxyState>>,
        fail_on: Mutex<Option<String>>,
        calls: Mutex<Vec<String>>,
    }

    impl FakeNetworkSetup {
        fn with(services: &[ServiceProxyState]) -> Arc<Self> {
            let fake = Self::default();
            for s in services {
                fake.services
                    .lock()
                    .unwrap()
                    .insert(s.service.clone(), s.clone());
            }
            Arc::new(fake)
        }

        fn state(&self, service: &str) -> ServiceProxyState {
            self.services.lock().unwrap()[service].clone()
        }

        fn endpoint_text(e: &EndpointState) -> String {
            format!(
                "Enabled: {}\nServer: {}\nPort: {}\nAuthenticated Proxy Enabled: {}\n",
                if e.enabled { "Yes" } else { "No" },
                e.server.clone().unwrap_or_default(),
                e.port.unwrap_or(0),
                i32::from(e.authenticated)
            )
        }
    }

    impl CommandRunner for FakeNetworkSetup {
        fn run<'a>(
            &'a self,
            args: Vec<String>,
        ) -> futures_util::future::BoxFuture<'a, CoreResult<CommandOutput>> {
            Box::pin(async move {
                self.calls.lock().unwrap().push(args.join(" "));
                if let Some(fail) = self.fail_on.lock().unwrap().as_deref()
                    && args.join(" ").starts_with(fail)
                {
                    return Ok(CommandOutput {
                        status: 1,
                        stdout: String::new(),
                        stderr: "boom".into(),
                    });
                }
                let mut services = self.services.lock().unwrap();
                let ok = |stdout: String| {
                    Ok(CommandOutput {
                        status: 0,
                        stdout,
                        stderr: String::new(),
                    })
                };
                let command = args[0].as_str();
                if command == "-listallnetworkservices" {
                    let mut names: Vec<_> = services.keys().cloned().collect();
                    names.sort();
                    return ok(format!(
                        "An asterisk (*) denotes that a network service is disabled.\n{}\n",
                        names.join("\n")
                    ));
                }
                let service = services.get_mut(&args[1]).unwrap();
                let pick = |s: &mut ServiceProxyState, kind: &str| match kind {
                    "web" => s.web.clone(),
                    "secureweb" => s.secure_web.clone(),
                    _ => s.socks.clone(),
                };
                let put = |s: &mut ServiceProxyState, kind: &str, e: EndpointState| match kind {
                    "web" => s.web = e,
                    "secureweb" => s.secure_web = e,
                    _ => s.socks = e,
                };
                let kind_of = |c: &str, prefix: &str, suffix: &str| {
                    c.strip_prefix(prefix)
                        .and_then(|r| r.strip_suffix(suffix))
                        .map(|k| match k {
                            "webproxy" => "web",
                            "securewebproxy" => "secureweb",
                            _ => "socks",
                        })
                };
                let is_endpoint = !command.contains("bypass") && !command.contains("auto");
                if let Some(kind) = kind_of(command, "-get", "")
                    .filter(|_| command.ends_with("proxy") && is_endpoint)
                {
                    return ok(Self::endpoint_text(&pick(service, kind)));
                }
                if let Some(kind) = kind_of(command, "-set", "state").filter(|_| is_endpoint) {
                    let mut e = pick(service, kind);
                    e.enabled = args[2] == "on";
                    put(service, kind, e);
                    return ok(String::new());
                }
                if let Some(kind) = kind_of(command, "-set", "")
                    .filter(|_| command.ends_with("proxy") && is_endpoint)
                {
                    // Как настоящий networksetup: пустой сервер читается как «нет».
                    let server = (!args[2].is_empty()).then(|| args[2].clone());
                    let e = EndpointState {
                        enabled: true,
                        server,
                        port: args[3].parse().ok(),
                        authenticated: false,
                    };
                    put(service, kind, e);
                    return ok(String::new());
                }
                match command {
                    "-getproxybypassdomains" => ok(if service.bypass_domains.is_empty() {
                        "There aren't any bypass domains set on Wi-Fi.\n".into()
                    } else {
                        service.bypass_domains.join("\n")
                    }),
                    "-setproxybypassdomains" => {
                        service.bypass_domains = if args[2] == "Empty" {
                            Vec::new()
                        } else {
                            args[2..].to_vec()
                        };
                        ok(String::new())
                    }
                    "-getautoproxyurl" => ok(format!(
                        "URL: {}\nEnabled: {}\n",
                        service
                            .auto_config_url
                            .clone()
                            .unwrap_or_else(|| "(null)".into()),
                        if service.auto_config_enabled {
                            "Yes"
                        } else {
                            "No"
                        }
                    )),
                    "-getproxyautodiscovery" => ok(format!(
                        "Auto Proxy Discovery: {}\n",
                        if service.auto_discovery_enabled {
                            "On"
                        } else {
                            "Off"
                        }
                    )),
                    "-setautoproxystate" => {
                        service.auto_config_enabled = args[2] == "on";
                        ok(String::new())
                    }
                    "-setproxyautodiscovery" => {
                        service.auto_discovery_enabled = args[2] == "on";
                        ok(String::new())
                    }
                    other => panic!("unexpected networksetup {other}"),
                }
            })
        }
    }

    fn user_state(name: &str) -> ServiceProxyState {
        ServiceProxyState {
            service: name.into(),
            web: EndpointState {
                enabled: true,
                server: Some("corp.proxy".into()),
                port: Some(3128),
                authenticated: false,
            },
            secure_web: EndpointState {
                enabled: false,
                server: Some("old.proxy".into()),
                port: Some(8080),
                authenticated: false,
            },
            // Ненастроенный endpoint networksetup отдаёт как «Server: / Port: 0».
            socks: EndpointState {
                port: Some(0),
                ..EndpointState::default()
            },
            bypass_domains: vec!["intranet.local".into()],
            auto_config_enabled: true,
            auto_config_url: Some("http://pac/x.pac".into()),
            auto_discovery_enabled: true,
        }
    }

    fn quiet() -> impl Fn(String) + Send + Sync {
        |_| {}
    }

    fn enabled_on_macos() -> bool {
        cfg!(target_os = "macos")
    }

    #[tokio::test]
    async fn enable_then_restore_returns_exact_user_state() {
        if !enabled_on_macos() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeNetworkSetup::with(&[user_state("Wi-Fi")]);
        let service = SystemProxyService::new(fake.clone());
        let lease = service
            .enable(dir.path(), 2080, false, &quiet())
            .await
            .unwrap();
        let applied = fake.state("Wi-Fi");
        assert!(
            applied.web.points_to(2080)
                && applied.secure_web.points_to(2080)
                && applied.socks.points_to(2080)
        );
        assert!(!applied.auto_config_enabled && !applied.auto_discovery_enabled);
        assert!(SystemProxyService::journal_exists(dir.path()).await);

        service
            .restore(dir.path(), Some(&lease), &quiet())
            .await
            .unwrap();
        assert_eq!(fake.state("Wi-Fi"), user_state("Wi-Fi"));
        assert!(!SystemProxyService::journal_exists(dir.path()).await);
    }

    #[tokio::test]
    async fn restore_keeps_endpoints_the_user_changed() {
        if !enabled_on_macos() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeNetworkSetup::with(&[user_state("Wi-Fi")]);
        let service = SystemProxyService::new(fake.clone());
        service
            .enable(dir.path(), 2080, false, &quiet())
            .await
            .unwrap();
        {
            let mut services = fake.services.lock().unwrap();
            let wifi = services.get_mut("Wi-Fi").unwrap();
            wifi.web = EndpointState {
                enabled: true,
                server: Some("new.proxy".into()),
                port: Some(1),
                authenticated: false,
            };
        }
        // Восстановление по журналу на диске, как после сбоя.
        service.restore(dir.path(), None, &quiet()).await.unwrap();
        let state = fake.state("Wi-Fi");
        assert_eq!(state.web.server.as_deref(), Some("new.proxy"));
        assert_eq!(state.secure_web, user_state("Wi-Fi").secure_web);
    }

    #[tokio::test]
    async fn failed_restore_keeps_journal() {
        if !enabled_on_macos() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let fake = FakeNetworkSetup::with(&[user_state("Wi-Fi")]);
        let service = SystemProxyService::new(fake.clone());
        service
            .enable(dir.path(), 2080, false, &quiet())
            .await
            .unwrap();
        *fake.fail_on.lock().unwrap() = Some("-setwebproxy Wi-Fi".into());
        assert!(service.restore(dir.path(), None, &quiet()).await.is_err());
        assert!(SystemProxyService::journal_exists(dir.path()).await);
        // Упавший endpoint аварийно выключен, остальные восстановлены.
        let state = fake.state("Wi-Fi");
        assert!(!state.web.enabled);
        assert_eq!(state.secure_web, user_state("Wi-Fi").secure_web);
    }

    #[tokio::test]
    async fn refuses_authenticated_proxy_and_existing_journal() {
        if !enabled_on_macos() {
            return;
        }
        let dir = tempfile::tempdir().unwrap();
        let mut auth = user_state("Wi-Fi");
        auth.web.authenticated = true;
        let service = SystemProxyService::new(FakeNetworkSetup::with(&[auth]));
        assert!(
            service
                .enable(dir.path(), 2080, false, &quiet())
                .await
                .is_err()
        );
        assert!(!SystemProxyService::journal_exists(dir.path()).await);

        tokio::fs::write(SystemProxyService::journal_path(dir.path()), "{}")
            .await
            .unwrap();
        let service = SystemProxyService::new(FakeNetworkSetup::with(&[user_state("Wi-Fi")]));
        assert!(matches!(
            service.enable(dir.path(), 2080, false, &quiet()).await,
            Err(CoreError::RecoveryPending(_))
        ));
        // Повреждённый журнал не удаляется.
        assert!(service.restore(dir.path(), None, &quiet()).await.is_err());
        assert!(SystemProxyService::journal_exists(dir.path()).await);
    }

    #[test]
    fn bypass_list_is_deduplicated_and_keeps_user_entries_first() {
        let list = managed_bypass_domains(&["localhost".into(), "corp".into()], true);
        assert_eq!(list[0], "localhost");
        assert_eq!(list[1], "corp");
        assert_eq!(list.iter().filter(|e| *e == "localhost").count(), 1);
        assert!(list.contains(&"steampowered.com".to_owned()));
    }
}
