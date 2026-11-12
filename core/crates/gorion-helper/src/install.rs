//! Установка и удаление службы launchd (выполняется от root).
//! Эталон: `lib/core/privileged_helper/macos_helper_installer.dart`.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use gorion_core::helper::client::HelperClient;
use gorion_core::helper::{HelperStatus, LAUNCHD_LABEL, PLIST_PATH, SOCKET_PATH, SUPPORT_DIR};

const READY_TIMEOUT: Duration = Duration::from_secs(15);

fn require_root() -> Result<(), String> {
    if nix::unistd::geteuid().is_root() {
        Ok(())
    } else {
        Err("нужны права root".into())
    }
}

pub fn install(singbox: &Path) -> Result<(), String> {
    require_root()?;
    let helper = std::env::current_exe().map_err(|e| e.to_string())?;
    if !singbox.is_file() {
        return Err(format!("нет sing-box: {}", singbox.display()));
    }
    // Старая служба (в том числе Flutter-версии) останавливается первой:
    // при остановке она гасит своё ядро и возвращает маршруты.
    bootout();
    let support = Path::new(SUPPORT_DIR);
    let bin = support.join("bin");
    for dir in [support, bin.as_path()] {
        std::fs::create_dir_all(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        secure(dir, 0o755)?;
    }
    copy_secure(&helper, &bin.join("gorion-helper"))?;
    copy_secure(singbox, &bin.join("sing-box"))?;
    remove_legacy(support);

    let plist = Path::new(PLIST_PATH);
    std::fs::write(plist, plist_contents(&bin.join("gorion-helper")))
        .map_err(|e| format!("{}: {e}", plist.display()))?;
    secure(plist, 0o644)?;
    launchctl(&["bootstrap", "system", PLIST_PATH])?;
    let _ = launchctl(&["kickstart", "-k", &format!("system/{LAUNCHD_LABEL}")]);
    wait_until_ready()
}

pub fn uninstall() -> Result<(), String> {
    require_root()?;
    bootout();
    for path in [PathBuf::from(PLIST_PATH), PathBuf::from(SOCKET_PATH)] {
        let _ = std::fs::remove_file(path);
    }
    let _ = std::fs::remove_dir_all(Path::new(SUPPORT_DIR).join("bin"));
    Ok(())
}

fn bootout() {
    // Нет службы — не ошибка.
    let _ = Command::new("/bin/launchctl")
        .args(["bootout", &format!("system/{LAUNCHD_LABEL}")])
        .output();
}

fn launchctl(args: &[&str]) -> Result<(), String> {
    let output = Command::new("/bin/launchctl")
        .args(args)
        .output()
        .map_err(|e| e.to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        Err(format!(
            "launchctl {}: {}",
            args.join(" "),
            String::from_utf8_lossy(&output.stderr).trim()
        ))
    }
}

/// Файл root:wheel: подменить бинарник, который запустит launchd от root,
/// может только root.
fn secure(path: &Path, mode: u32) -> Result<(), String> {
    std::os::unix::fs::chown(path, Some(0), Some(0))
        .and_then(|()| std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)))
        .map_err(|e| format!("{}: {e}", path.display()))
}

/// Копия через временный файл и переименование: работающий процесс не
/// увидит наполовину записанный бинарник.
fn copy_secure(from: &Path, to: &Path) -> Result<(), String> {
    let temporary = to.with_extension("new");
    std::fs::copy(from, &temporary).map_err(|e| format!("{}: {e}", from.display()))?;
    secure(&temporary, 0o755)?;
    std::fs::rename(&temporary, to).map_err(|e| format!("{}: {e}", to.display()))
}

/// Остатки Flutter-помощника: копия приложения и файл с токеном.
fn remove_legacy(support: &Path) {
    let _ = std::fs::remove_dir_all(support.join("Helper.app"));
    let _ = std::fs::remove_file(support.join("privileged-helper.json"));
}

fn plist_contents(program: &Path) -> String {
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{LAUNCHD_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{}</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
"#,
        xml_escape(&program.to_string_lossy())
    )
}

fn xml_escape(value: &str) -> String {
    value
        .replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// Установка закончена, когда служба ответила на `hello`.
fn wait_until_ready() -> Result<(), String> {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    let client = HelperClient::new(SOCKET_PATH);
    let started = Instant::now();
    runtime.block_on(async {
        loop {
            if client.status().await == HelperStatus::Ready {
                return Ok(());
            }
            if started.elapsed() > READY_TIMEOUT {
                return Err("служба не ответила после установки".to_owned());
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plist_runs_serve_from_support_dir() {
        let plist = plist_contents(&Path::new(SUPPORT_DIR).join("bin/gorion-helper"));
        assert!(plist.contains("<string>app.gorion.privileged-helper</string>"));
        assert!(plist.contains(
            "<string>/Library/Application Support/Gorion/bin/gorion-helper</string>\n    <string>serve</string>"
        ));
        assert!(plist.contains("<key>KeepAlive</key>"));
    }
}
