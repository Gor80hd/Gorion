//! `gorion-helper` — помощник Gorion с правами root (ADR-0005).
//!
//! ```text
//! gorion-helper serve [--socket P] [--runtime-dir D] [--singbox S] [--allow-non-tun]
//! gorion-helper install --singbox S     # от root: ставит службу launchd
//! gorion-helper uninstall               # от root: убирает службу
//! gorion-helper --version
//! ```
//!
//! `serve` запускает launchd. `--allow-non-tun` и пути — для тестов без root.

use std::path::PathBuf;
use std::process::ExitCode;

#[cfg(target_os = "macos")]
mod install;
mod serve;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let result = match args.first().map(String::as_str) {
        Some("serve") => serve::Options::parse(&args[1..]).and_then(serve::run),
        #[cfg(target_os = "macos")]
        Some("install") => flag_value(&args[1..], "--singbox")
            .ok_or_else(|| "install: нужен --singbox".to_owned())
            .and_then(|singbox| install::install(&PathBuf::from(singbox))),
        #[cfg(target_os = "macos")]
        Some("uninstall") => install::uninstall(),
        Some("--version") => {
            println!(
                "gorion-helper {} (protocol {})",
                env!("CARGO_PKG_VERSION"),
                gorion_core::helper::PROTOCOL_VERSION
            );
            Ok(())
        }
        _ => Err("usage: gorion-helper serve|install|uninstall|--version".to_owned()),
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("gorion-helper: {error}");
            ExitCode::FAILURE
        }
    }
}

/// Значение флага `--name value`.
pub(crate) fn flag_value(args: &[String], name: &str) -> Option<String> {
    args.iter()
        .position(|a| a == name)
        .and_then(|i| args.get(i + 1))
        .cloned()
}
