//! Процессы: маркер запущенного ядра, проверка живости и личности
//! процесса, мягкое и жёсткое завершение.
//! Эталон: `singbox_runtime_service.dart` (маркер, осиротевшие процессы).

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::error::{CoreError, CoreResult};
use crate::storage::{read_json, write_json};

pub const PROCESS_MARKER_FILE: &str = "runtime-process.json";

/// Маркер на диске позволяет следующему запуску (или watchdog) найти ядро
/// после kill -9, сбоя или потери питания.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessMarker {
    pub pid: i32,
    #[serde(default)]
    pub binary_path: Option<String>,
    #[serde(default)]
    pub config_path: Option<String>,
    #[serde(default)]
    pub launcher_pid: Option<i32>,
}

pub fn marker_path(runtime_dir: &Path) -> PathBuf {
    runtime_dir.join(PROCESS_MARKER_FILE)
}

pub async fn read_marker(runtime_dir: &Path) -> Option<ProcessMarker> {
    read_json::<ProcessMarker>(&marker_path(runtime_dir))
        .await
        .ok()
        .flatten()
        .filter(|m| m.pid > 0)
}

pub async fn write_marker(runtime_dir: &Path, marker: &ProcessMarker) -> CoreResult<()> {
    write_json(&marker_path(runtime_dir), marker).await
}

/// Удаляет маркер, только если он всё ещё про `expected_pid`.
pub async fn delete_marker(runtime_dir: &Path, expected_pid: Option<i32>) {
    if let Some(expected) = expected_pid
        && let Some(marker) = read_marker(runtime_dir).await
        && marker.pid != expected
    {
        return;
    }
    let _ = tokio::fs::remove_file(marker_path(runtime_dir)).await;
}

pub fn current_pid() -> i32 {
    std::process::id() as i32
}

/// Жив ли процесс. «Нет прав» — тоже жив.
#[cfg(unix)]
pub fn is_alive(pid: i32) -> bool {
    use nix::errno::Errno;
    use nix::sys::signal::kill;
    use nix::unistd::Pid;
    if pid <= 0 {
        return false;
    }
    match kill(Pid::from_raw(pid), None) {
        Ok(()) => true,
        Err(Errno::EPERM) => true,
        Err(_) => false,
    }
}

#[cfg(not(unix))]
pub fn is_alive(_pid: i32) -> bool {
    false
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Signal {
    Terminate,
    Kill,
}

#[cfg(unix)]
pub fn send_signal(pid: i32, signal: Signal) -> bool {
    use nix::sys::signal::{Signal as NixSignal, kill};
    use nix::unistd::Pid;
    let sig = match signal {
        Signal::Terminate => NixSignal::SIGTERM,
        Signal::Kill => NixSignal::SIGKILL,
    };
    pid > 0 && kill(Pid::from_raw(pid), sig).is_ok()
}

#[cfg(not(unix))]
pub fn send_signal(_pid: i32, _signal: Signal) -> bool {
    false
}

/// Командная строка процесса (`ps -o command=`), `None` — процесса нет.
pub async fn command_line(pid: i32) -> CoreResult<Option<String>> {
    if cfg!(not(unix)) {
        return Err(CoreError::Unsupported("проверка процессов".into()));
    }
    let output = run_with_timeout(
        "/bin/ps",
        &["-p", &pid.to_string(), "-o", "command="],
        Duration::from_secs(5),
    )
    .await?;
    let text = output.stdout.trim().to_owned();
    Ok((!text.is_empty()).then_some(text))
}

/// Время запуска и командная строка — «личность» процесса для watchdog.
pub async fn identity(pid: i32) -> String {
    run_with_timeout(
        "/bin/ps",
        &["-p", &pid.to_string(), "-o", "lstart=", "-o", "command="],
        Duration::from_secs(5),
    )
    .await
    .map(|o| o.stdout.trim().to_owned())
    .unwrap_or_default()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkerMatch {
    Matches,
    Mismatches,
    MissingProcess,
    Inconclusive,
}

/// Совпадает ли живой процесс с маркером: имя бинарника и путь конфига в
/// командной строке. Чужой процесс с тем же PID не трогаем.
pub async fn inspect_marker(marker: &ProcessMarker) -> MarkerMatch {
    if !is_alive(marker.pid) {
        return MarkerMatch::MissingProcess;
    }
    let Ok(Some(command)) = command_line(marker.pid).await else {
        return MarkerMatch::Inconclusive;
    };
    let command = command.to_lowercase();
    let Some(binary) = marker
        .binary_path
        .as_deref()
        .filter(|b| !b.trim().is_empty())
    else {
        return MarkerMatch::Inconclusive;
    };
    let base = Path::new(binary.trim())
        .file_name()
        .map(|n| n.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if !command.contains(&base) {
        return MarkerMatch::Mismatches;
    }
    if let Some(config) = marker
        .config_path
        .as_deref()
        .filter(|c| !c.trim().is_empty())
        && !command.contains(&config.trim().to_lowercase())
    {
        return MarkerMatch::Mismatches;
    }
    MarkerMatch::Matches
}

/// Ждёт исчезновения процесса до `timeout`.
pub async fn wait_for_exit(pid: i32, timeout: Duration) -> bool {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        if !is_alive(pid) {
            return true;
        }
        if tokio::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

#[derive(Debug, Clone)]
pub struct CommandOutput {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Внешняя команда с жёстким тайм-аутом на всё, включая чтение вывода.
pub async fn run_with_timeout(
    program: &str,
    args: &[&str],
    timeout: Duration,
) -> CoreResult<CommandOutput> {
    let mut command = tokio::process::Command::new(program);
    command
        .args(args)
        .kill_on_drop(true)
        .stdin(std::process::Stdio::null());
    let output = tokio::time::timeout(timeout, command.output())
        .await
        .map_err(|_| CoreError::Internal(format!("{program}: тайм-аут {} с", timeout.as_secs())))?
        .map_err(|e| CoreError::Internal(format!("{program}: {e}")))?;
    Ok(CommandOutput {
        status: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

/// Резервирует свободный порт на 127.0.0.1. Держите значение, пока не
/// пора отдавать порт ядру, — так его не займёт кто-то ещё.
pub struct ReservedPort {
    listener: std::net::TcpListener,
    pub port: u16,
}

impl ReservedPort {
    pub fn reserve() -> CoreResult<Self> {
        let listener = std::net::TcpListener::bind(("127.0.0.1", 0))?;
        let port = listener.local_addr()?.port();
        Ok(Self { listener, port })
    }

    pub fn release(self) -> u16 {
        drop(self.listener);
        self.port
    }
}
