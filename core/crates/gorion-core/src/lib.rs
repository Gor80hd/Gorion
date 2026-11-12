//! Ядро Gorion: всё, кроме интерфейса. Используется macOS-приложением
//! (через `gorion-ffi` / UniFFI) и Windows-приложением.
//!
//! Правила (AGENTS.md): текстов для пользователя здесь нет — только коды
//! ошибок и данные; поведение сверяется с Flutter-эталоном фикстурами из
//! `core/fixtures`.

pub mod candidates;
pub mod config_builder;
pub mod display;
pub mod engine;
pub mod error;
pub mod geo;
mod geo_data;
pub mod helper;
pub mod ipinfo;
mod json_util;
pub mod model;
pub mod parser;
pub mod probe;
pub mod runtime;
pub mod storage;
pub mod subscription;

pub use error::{CoreError, CoreResult, ErrorCode};
