//! Запуск sing-box и всё, что к нему привязано.

use serde::{Deserialize, Serialize};

/// Режим подключения. В интерфейсе: «Вручную», «Приложения», «Весь компьютер».
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum RuntimeMode {
    /// Только локальный прокси; программы настраиваются вручную.
    Mixed,
    /// Системный прокси указывает на локальный прокси.
    #[default]
    SystemProxy,
    /// Весь трафик через TUN (нужен помощник с правами администратора).
    Tun,
}

impl RuntimeMode {
    pub fn uses_system_proxy(self) -> bool {
        self == Self::SystemProxy
    }

    pub fn uses_tun(self) -> bool {
        self == Self::Tun
    }

    /// Имя как в Dart (`RuntimeMode.name`).
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mixed => "mixed",
            Self::SystemProxy => "systemProxy",
            Self::Tun => "tun",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        match name {
            "mixed" => Some(Self::Mixed),
            "systemProxy" => Some(Self::SystemProxy),
            "tun" => Some(Self::Tun),
            _ => None,
        }
    }
}

pub mod clash;
pub mod process;
pub mod service;
pub mod system_proxy;
pub mod watchdog;
