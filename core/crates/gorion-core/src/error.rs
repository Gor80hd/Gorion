//! Ошибки ядра. Тексты здесь — для журналов и разработчика; интерфейс
//! показывает пользователю свои формулировки по [`ErrorCode`].

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Стабильный код ошибки для интерфейса. Новые варианты добавляются в конец.
/// Сериализуется по имени: так коды передаёт помощник (`helper`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ErrorCode {
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
    /// Сквозная проверка после подключения не прошла.
    InternetUnavailable,
    /// Ядро завершилось само во время работы.
    UnexpectedExit,
    /// Действие требует подписки, а её нет.
    NoProfile,
    /// Режим «Весь компьютер» требует помощника, которого ещё нет.
    TunHelperRequired,
    /// Установленный помощник старее приложения — нужна переустановка.
    HelperOutdated,
    /// Пользователь отменил ввод пароля при установке помощника.
    HelperInstallCancelled,
    /// Установка помощника не удалась.
    HelperInstallFailed,
    /// Свой движок не умеет этот профиль, а sing-box в сборке нет.
    EngineUnsupported,
}

#[derive(Debug, Error)]
pub enum CoreError {
    #[error("адрес подписки должен быть абсолютным URL")]
    InvalidSubscriptionUrl,
    #[error("не удалось загрузить подписку: {0}")]
    SubscriptionFetch(String),
    #[error("поддерживаются только JSON-конфиги sing-box и списки ссылок (обычные или base64)")]
    UnsupportedSubscriptionFormat,
    #[error("в подписке нет серверов, которые можно выбрать")]
    NoSelectableServers,
    #[error("неподдерживаемый транспорт: {0}")]
    UnsupportedTransport(String),
    #[error("некорректная ссылка: {0}")]
    InvalidShareLink(String),
    #[error("сохранённый шаблон подписки повреждён: {0}")]
    InvalidTemplate(String),
    #[error("профиль не найден: {0}")]
    ProfileNotFound(String),
    #[error("ошибка хранилища: {0}")]
    Storage(String),
    #[error("бинарник sing-box не найден: {0}")]
    CoreBinaryMissing(String),
    #[error("sing-box отклонил конфигурацию: {0}")]
    InvalidRuntimeConfig(String),
    #[error("sing-box не запустился: {0}")]
    CoreStartFailed(String),
    #[error("контроллер sing-box недоступен: {0}")]
    ControllerUnavailable(String),
    #[error("системный прокси: {0}")]
    SystemProxy(String),
    #[error("восстановление после прошлой сессии не завершено: {0}")]
    RecoveryPending(String),
    #[error("runtime принадлежит другому экземпляру Gorion")]
    AnotherInstanceRunning,
    #[error("не поддерживается на этой платформе: {0}")]
    Unsupported(String),
    #[error("внутренняя ошибка: {0}")]
    Internal(String),
    #[error("через сервер «{0}» нет доступа в интернет")]
    InternetUnavailable(String),
    #[error("sing-box неожиданно завершился с кодом {0}")]
    UnexpectedExit(i32),
    #[error("нет ни одной подписки")]
    NoProfile,
    #[error("для режима TUN нужен помощник с правами администратора")]
    TunHelperRequired,
    #[error("помощник устарел: протокол {0}")]
    HelperOutdated(u32),
    #[error("установку помощника отменили")]
    HelperInstallCancelled,
    #[error("помощник не установлен: {0}")]
    HelperInstallFailed(String),
    /// Причина отказа движка (`gorion-engine check`): протокол и номер
    /// сервера или настройка — без имён и секретов.
    #[error("ядро Gorion не поддерживает профиль: {0}")]
    EngineUnsupported(String),
    /// Ошибка, которую вернул помощник: код сохраняется как есть.
    #[error("помощник: {detail}")]
    Remote { code: ErrorCode, detail: String },
}

impl CoreError {
    pub fn code(&self) -> ErrorCode {
        match self {
            Self::InvalidSubscriptionUrl => ErrorCode::InvalidSubscriptionUrl,
            Self::SubscriptionFetch(_) => ErrorCode::SubscriptionFetchFailed,
            Self::UnsupportedSubscriptionFormat => ErrorCode::UnsupportedSubscriptionFormat,
            Self::NoSelectableServers => ErrorCode::NoSelectableServers,
            Self::UnsupportedTransport(_) => ErrorCode::UnsupportedTransport,
            Self::InvalidShareLink(_) => ErrorCode::InvalidShareLink,
            Self::InvalidTemplate(_) => ErrorCode::InvalidTemplate,
            Self::ProfileNotFound(_) => ErrorCode::ProfileNotFound,
            Self::Storage(_) => ErrorCode::Storage,
            Self::CoreBinaryMissing(_) => ErrorCode::CoreBinaryMissing,
            Self::InvalidRuntimeConfig(_) => ErrorCode::InvalidRuntimeConfig,
            Self::CoreStartFailed(_) => ErrorCode::CoreStartFailed,
            Self::ControllerUnavailable(_) => ErrorCode::ControllerUnavailable,
            Self::SystemProxy(_) => ErrorCode::SystemProxyFailed,
            Self::RecoveryPending(_) => ErrorCode::RecoveryPending,
            Self::AnotherInstanceRunning => ErrorCode::AnotherInstanceRunning,
            Self::Unsupported(_) => ErrorCode::Unsupported,
            Self::Internal(_) => ErrorCode::Internal,
            Self::InternetUnavailable(_) => ErrorCode::InternetUnavailable,
            Self::UnexpectedExit(_) => ErrorCode::UnexpectedExit,
            Self::NoProfile => ErrorCode::NoProfile,
            Self::TunHelperRequired => ErrorCode::TunHelperRequired,
            Self::HelperOutdated(_) => ErrorCode::HelperOutdated,
            Self::HelperInstallCancelled => ErrorCode::HelperInstallCancelled,
            Self::HelperInstallFailed(_) => ErrorCode::HelperInstallFailed,
            Self::EngineUnsupported(_) => ErrorCode::EngineUnsupported,
            Self::Remote { code, .. } => *code,
        }
    }
}

impl From<std::io::Error> for CoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Storage(error.to_string())
    }
}

pub type CoreResult<T> = Result<T, CoreError>;
