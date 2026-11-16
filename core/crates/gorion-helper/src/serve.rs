//! Служба: сокет, восстановление после сбоя, остановка по сигналу.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use gorion_core::helper::server::HelperServer;
use gorion_core::helper::{SOCKET_PATH, SUPPORT_DIR};
use gorion_core::runtime::service::ENGINE_BINARY;
use tokio::net::UnixListener;
use tokio::signal::unix::{SignalKind, signal};

use crate::flag_value;

pub struct Options {
    socket: PathBuf,
    runtime_dir: PathBuf,
    engine: PathBuf,
    allow_non_tun: bool,
}

impl Options {
    pub fn parse(args: &[String]) -> Result<Self, String> {
        let support = Path::new(SUPPORT_DIR);
        Ok(Self {
            socket: flag_value(args, "--socket").map_or_else(|| SOCKET_PATH.into(), PathBuf::from),
            runtime_dir: flag_value(args, "--runtime-dir")
                .map_or_else(|| support.join("runtime"), PathBuf::from),
            engine: flag_value(args, "--engine")
                .map_or_else(|| support.join("bin").join(ENGINE_BINARY), PathBuf::from),
            allow_non_tun: args.iter().any(|a| a == "--allow-non-tun"),
        })
    }
}

pub fn run(options: Options) -> Result<(), String> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_env("GORION_LOG")
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .map_err(|e| e.to_string())?;
    runtime.block_on(serve(options))
}

async fn serve(options: Options) -> Result<(), String> {
    std::fs::create_dir_all(&options.runtime_dir).map_err(|e| e.to_string())?;
    std::fs::set_permissions(&options.runtime_dir, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| e.to_string())?;
    let listener = bind(&options.socket)?;
    let server = HelperServer::new(
        options.runtime_dir.clone(),
        options.engine.clone(),
        options.allow_non_tun,
    );
    server.recover().await;
    tracing::info!(socket = %options.socket.display(), "helper ready");

    let mut terminate = signal(SignalKind::terminate()).map_err(|e| e.to_string())?;
    let mut interrupt = signal(SignalKind::interrupt()).map_err(|e| e.to_string())?;
    tokio::select! {
        () = server.clone().serve(listener) => {}
        _ = terminate.recv() => {}
        _ = interrupt.recv() => {}
    }
    tracing::info!("helper stopping");
    server.shutdown().await;
    let _ = std::fs::remove_file(&options.socket);
    Ok(())
}

/// Сокет доступен только администраторам (root:admin 0660). Без root —
/// только владельцу: так работают тесты.
fn bind(socket: &Path) -> Result<UnixListener, String> {
    if let Some(parent) = socket.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    match std::fs::remove_file(socket) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(format!("{}: {e}", socket.display())),
    }
    // Пока права не выставлены, сокет не должен быть доступен никому.
    let previous = nix::sys::stat::umask(nix::sys::stat::Mode::from_bits_truncate(0o077));
    let listener = UnixListener::bind(socket);
    nix::sys::stat::umask(previous);
    let listener = listener.map_err(|e| format!("{}: {e}", socket.display()))?;
    let mode = if nix::unistd::geteuid().is_root() {
        let admin = nix::unistd::Group::from_name("admin")
            .ok()
            .flatten()
            .ok_or("group admin not found")?;
        std::os::unix::fs::chown(socket, Some(0), Some(admin.gid.as_raw()))
            .map_err(|e| e.to_string())?;
        0o660
    } else {
        0o600
    };
    std::fs::set_permissions(socket, std::fs::Permissions::from_mode(mode))
        .map_err(|e| e.to_string())?;
    Ok(listener)
}
