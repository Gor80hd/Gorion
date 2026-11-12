//! Помощник с правами root для режима «Весь компьютер» (TUN), ADR-0005.
//!
//! Помощник — служба launchd (`gorion-helper serve`). Приложение говорит с
//! ним строками JSON через Unix-сокет; подключиться могут только
//! администраторы (права на сокет). После `start` соединение остаётся
//! открытым и служит арендой: закрылось — помощник останавливает ядро.
//!
//! Эталон: `lib/core/privileged_helper/` (Flutter, протокол 2).

use serde::{Deserialize, Serialize};

use crate::error::ErrorCode;
use crate::runtime::RuntimeMode;
use crate::runtime::service::RuntimeSession;

#[cfg(unix)]
pub mod client;
#[cfg(unix)]
mod frame;
#[cfg(target_os = "macos")]
pub mod install;
#[cfg(unix)]
pub mod server;

/// Версия протокола. Во Flutter была 2 (HTTP + токен), здесь — сокет.
/// 4 — помощник ставит свой движок и может работать без sing-box: старый
/// помощник (только sing-box) считается устаревшим и переустанавливается.
pub const PROTOCOL_VERSION: u32 = 4;
/// Метка службы launchd — та же, что у Flutter-версии: новая заменяет старую.
pub const LAUNCHD_LABEL: &str = "app.gorion.privileged-helper";
pub const PLIST_PATH: &str = "/Library/LaunchDaemons/app.gorion.privileged-helper.plist";
pub const SOCKET_PATH: &str = "/var/run/app.gorion.privileged-helper.sock";
pub const SUPPORT_DIR: &str = "/Library/Application Support/Gorion";
/// Предел одной строки протокола: шаблон подписки бывает большим.
pub const MAX_FRAME: usize = 8 * 1024 * 1024;

/// Запуск ядра в помощнике. Шаблон собирается и очищается уже внутри
/// помощника — приложению не доверяем готовый конфиг.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HelperStart {
    pub profile_id: String,
    pub template_config: String,
    pub mode: RuntimeMode,
    pub selected_server_tag: Option<String>,
    pub url_test_url: String,
    /// Только sing-box: свой движок не нашёл рабочего сервера, повтор идёт
    /// через sing-box (ADR-0005). Ложь в провод не пишется — старые
    /// помощники видят прежний формат.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub sing_box_only: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "camelCase")]
pub enum Request {
    Hello,
    Start(HelperStart),
    Stop,
    State,
    Logs,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "camelCase")]
pub enum Response {
    Hello {
        version: u32,
        build: String,
    },
    Started {
        session: RuntimeSession,
    },
    Stopped,
    State {
        running: bool,
    },
    Logs {
        lines: Vec<String>,
    },
    /// Ядро завершилось само; приходит по аренде.
    Exited {
        code: i32,
    },
    Error {
        code: ErrorCode,
        detail: String,
    },
}

impl Response {
    pub fn error(error: &crate::CoreError) -> Self {
        Self::Error {
            code: error.code(),
            detail: error.to_string(),
        }
    }
}

/// Состояние помощника для интерфейса.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum HelperStatus {
    /// Ещё не проверяли.
    #[default]
    Unknown,
    NotInstalled,
    /// Установлен помощник другой версии протокола.
    Outdated,
    Ready,
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    #[test]
    fn wire_format_is_stable() {
        let start = Request::Start(HelperStart {
            profile_id: "p".into(),
            template_config: "{}".into(),
            mode: RuntimeMode::Tun,
            selected_server_tag: None,
            url_test_url: "https://x/".into(),
            sing_box_only: false,
        });
        let json = serde_json::to_string(&start).unwrap();
        assert_eq!(
            json,
            r#"{"op":"start","profileId":"p","templateConfig":"{}","mode":"tun","selectedServerTag":null,"urlTestUrl":"https://x/"}"#
        );
        assert_eq!(serde_json::from_str::<Request>(&json).unwrap(), start);
        let only = r#"{"op":"start","profileId":"p","templateConfig":"{}","mode":"tun","selectedServerTag":null,"urlTestUrl":"https://x/","singBoxOnly":true}"#;
        let Request::Start(parsed) = serde_json::from_str::<Request>(only).unwrap() else {
            panic!("start expected");
        };
        assert!(parsed.sing_box_only);
        assert_eq!(
            serde_json::to_string(&Request::Hello).unwrap(),
            r#"{"op":"hello"}"#
        );

        let error = Response::Error {
            code: ErrorCode::CoreStartFailed,
            detail: "x".into(),
        };
        assert_eq!(
            serde_json::to_string(&error).unwrap(),
            r#"{"event":"error","code":"CoreStartFailed","detail":"x"}"#
        );
        assert_eq!(
            serde_json::to_string(&Response::Exited { code: 1 }).unwrap(),
            r#"{"event":"exited","code":1}"#
        );
    }
}
