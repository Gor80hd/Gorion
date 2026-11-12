//! Выбранный сервер и счётчики трафика — общие для входа и управления.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, RwLock};

use tokio::sync::watch;

use crate::outbound::Outbound;

/// Текущий исходящий маршрут. Смена рвёт уже открытые через вход
/// подключения — как селектор sing-box с `interrupt_exist_connections`.
pub struct Selector {
    current: RwLock<Arc<Outbound>>,
    changed: watch::Sender<u64>,
}

impl Selector {
    pub fn new(outbound: Arc<Outbound>) -> Self {
        Self {
            current: RwLock::new(outbound),
            changed: watch::Sender::new(0),
        }
    }

    pub fn current(&self) -> Arc<Outbound> {
        let guard = self
            .current
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        Arc::clone(&guard)
    }

    pub fn set(&self, outbound: Arc<Outbound>) {
        *self
            .current
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = outbound;
        self.changed.send_modify(|generation| *generation += 1);
    }

    /// Подписка до чтения `current()`: смена после неё не потеряется.
    pub fn subscribe(&self) -> watch::Receiver<u64> {
        self.changed.subscribe()
    }
}

/// Байты через вход с начала работы.
#[derive(Debug, Default)]
pub struct Traffic {
    up: AtomicU64,
    down: AtomicU64,
}

impl Traffic {
    pub fn add_up(&self, bytes: usize) {
        self.up.fetch_add(bytes as u64, Ordering::Relaxed);
    }

    pub fn add_down(&self, bytes: usize) {
        self.down.fetch_add(bytes as u64, Ordering::Relaxed);
    }

    /// (отправлено, получено).
    pub fn totals(&self) -> (u64, u64) {
        (
            self.up.load(Ordering::Relaxed),
            self.down.load(Ordering::Relaxed),
        )
    }
}
