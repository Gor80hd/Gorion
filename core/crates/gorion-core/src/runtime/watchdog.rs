//! Страж на случай падения приложения (macOS/Linux).
//! Эталон: `posix_runtime_cleanup_watchdog.dart`; скрипт перенесён дословно.
//!
//! Отдельный процесс следит за приложением: если оно исчезло, выключает
//! endpoint'ы прокси на нашем порту и завершает ядро. Журналы остаются —
//! исходные настройки вернёт следующий запуск. После потери питания
//! LaunchAgent выполняет ту же очистку при входе в систему.

use std::path::Path;

use crate::error::{CoreError, CoreResult};
use crate::runtime::process::identity;

pub const SCRIPT_FILE: &str = "runtime-watchdog.sh";
pub const LOGIN_RECOVERY_LABEL: &str = "app.gorion.proxy-recovery";
const SCRIPT: &str = include_str!("watchdog.sh");

pub async fn arm(
    runtime_dir: &Path,
    parent_pid: i32,
    child_pid: i32,
    managed_proxy_port: Option<u16>,
    install_login_recovery: bool,
) -> CoreResult<()> {
    if !cfg!(unix) {
        return Ok(());
    }
    let script = runtime_dir.join(SCRIPT_FILE);
    tokio::fs::write(&script, SCRIPT).await?;
    set_mode(&script, 0o700).await?;
    let arguments = vec![
        script.to_string_lossy().into_owned(),
        parent_pid.to_string(),
        child_pid.to_string(),
        runtime_dir.to_string_lossy().into_owned(),
        managed_proxy_port
            .map(|p| p.to_string())
            .unwrap_or_default(),
        identity(parent_pid).await,
        identity(child_pid).await,
    ];
    if cfg!(target_os = "macos") && managed_proxy_port.is_some() && install_login_recovery {
        install_login_agent(&arguments).await?;
    }
    std::process::Command::new("/bin/bash")
        .args(&arguments)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| CoreError::Internal(format!("watchdog: {e}")))?;
    Ok(())
}

/// LaunchAgent загружается при входе, в том числе после потери питания.
/// Те же проверки владельца делают старое задание безвредным.
async fn install_login_agent(arguments: &[String]) -> CoreResult<()> {
    let home = std::env::var("HOME").map_err(|_| CoreError::Internal("нет HOME".into()))?;
    let agent = Path::new(&home)
        .join("Library/LaunchAgents")
        .join(format!("{LOGIN_RECOVERY_LABEL}.plist"));
    let xml = |v: &str| {
        v.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    };
    let args: Vec<String> = arguments
        .iter()
        .map(|a| format!("<string>{}</string>", xml(a)))
        .collect();
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{LOGIN_RECOVERY_LABEL}</string>
<key>ProgramArguments</key><array>
<string>/bin/bash</string>
{}
</array><key>RunAtLoad</key><true/>
</dict></plist>
"#,
        args.join("\n")
    );
    crate::storage::write_atomic(&agent, plist.as_bytes()).await
}

#[cfg(unix)]
async fn set_mode(path: &Path, mode: u32) -> CoreResult<()> {
    use std::os::unix::fs::PermissionsExt;
    tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).await?;
    Ok(())
}

#[cfg(not(unix))]
async fn set_mode(_path: &Path, _mode: u32) -> CoreResult<()> {
    Ok(())
}
