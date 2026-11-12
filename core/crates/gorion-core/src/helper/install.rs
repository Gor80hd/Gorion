//! Установка помощника на macOS: один запрос пароля администратора.
//!
//! macOS сама показывает окно с паролем (`osascript … with administrator
//! privileges`) и запускает от root `gorion-helper install` из приложения.
//! Дальше помощник ставит себя сам (крейт `gorion-helper`). Эталон:
//! `lib/core/privileged_helper/macos_helper_installer.dart`.

use std::path::Path;
use std::time::Duration;

use crate::error::{CoreError, CoreResult};
use crate::runtime::process::run_with_timeout;
use crate::runtime::service::ENGINE_BINARY;

/// Окно с паролем ждёт человека — времени с запасом.
const INSTALL_TIMEOUT: Duration = Duration::from_secs(600);

/// `prompt` — текст в окне macOS; он от интерфейса (в ядре текстов нет).
/// Движок лежит рядом с местом sing-box; sing-box ставится, только если
/// он есть в сборке.
pub async fn install(helper_binary: &Path, singbox: &Path, prompt: &str) -> CoreResult<()> {
    let engine = singbox.with_file_name(ENGINE_BINARY);
    for path in [helper_binary, engine.as_path()] {
        if !path.is_file() {
            return Err(CoreError::HelperInstallFailed(format!(
                "file not found: {}",
                path.display()
            )));
        }
    }
    let mut command = format!(
        "{} install --engine {}",
        shell_quote(&helper_binary.to_string_lossy()),
        shell_quote(&engine.to_string_lossy()),
    );
    if singbox.is_file() {
        command.push_str(&format!(
            " --singbox {}",
            shell_quote(&singbox.to_string_lossy())
        ));
    }
    let script = format!(
        "do shell script {} with prompt {} with administrator privileges",
        applescript_string(&command),
        applescript_string(prompt),
    );
    let output = run_with_timeout("/usr/bin/osascript", &["-e", &script], INSTALL_TIMEOUT)
        .await
        .map_err(|e| CoreError::HelperInstallFailed(e.to_string()))?;
    if output.status == 0 {
        return Ok(());
    }
    if is_user_cancel(&output.stderr) {
        return Err(CoreError::HelperInstallCancelled);
    }
    Err(CoreError::HelperInstallFailed(
        output.stderr.trim().to_owned(),
    ))
}

/// Отмена окна пароля: ошибка AppleScript -128.
fn is_user_cancel(stderr: &str) -> bool {
    stderr.contains("(-128)") || stderr.to_ascii_lowercase().contains("user canceled")
}

/// Аргумент для `/bin/sh` в одинарных кавычках.
fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// Строковый литерал AppleScript.
fn applescript_string(value: &str) -> String {
    format!("\"{}\"", value.replace('\\', r"\\").replace('"', "\\\""))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_paths_with_spaces_and_quotes() {
        assert_eq!(shell_quote("/A b/c'd"), r"'/A b/c'\''d'");
        assert_eq!(
            applescript_string(r#"say "hi" \ ok"#),
            r#""say \"hi\" \\ ok""#
        );
    }

    #[test]
    fn detects_cancel() {
        assert!(is_user_cancel(
            "0:157: execution error: User canceled. (-128)"
        ));
        assert!(!is_user_cancel(
            "execution error: The command exited with a non-zero status. (1)"
        ));
    }
}
