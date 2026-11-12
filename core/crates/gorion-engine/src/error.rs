//! Ошибки движка. Тексты — для журнала, не для пользователя (правило 9).

use std::io;

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("io: {0}")]
    Io(#[from] io::Error),
    #[error("unsupported cipher: {0}")]
    UnsupportedCipher(String),
    #[error("bad address")]
    BadAddress,
    #[error("authentication failed: decryption error")]
    Decrypt,
    #[error("protocol violation: {0}")]
    Protocol(&'static str),
    #[error("tls alert {0}")]
    TlsAlert(u8),
    #[error("reality: server did not prove the key (wrong public key or short id?)")]
    RealityRejected,
}

pub type Result<T> = std::result::Result<T, EngineError>;
