//! Процесс движка: `gorion-engine run -c config.json` — как `sing-box run`.
//! Ядро Gorion запускает его вместо sing-box, когда профиль ему по силам
//! (`gorion-engine check -c …` завершился успешно).

use std::process::ExitCode;

use gorion_engine::config;

fn usage() -> ExitCode {
    eprintln!("usage: gorion-engine (run|check) -c <config.json> | version");
    ExitCode::from(2)
}

fn load(path: &str) -> Result<config::Plan, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("read config: {e}"))?;
    let value: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("parse config: {e}"))?;
    config::from_singbox(&value).map_err(|e| e.to_string())
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let command = args.first().map(String::as_str);
    if command == Some("version") {
        println!("gorion-engine {}", env!("CARGO_PKG_VERSION"));
        return ExitCode::SUCCESS;
    }
    let path = match args
        .iter()
        .position(|a| a == "-c")
        .and_then(|i| args.get(i + 1))
    {
        Some(path) => path.clone(),
        None => return usage(),
    };
    let plan = match load(&path) {
        Ok(plan) => plan,
        Err(error) => {
            eprintln!("{error}");
            return ExitCode::FAILURE;
        }
    };
    match command {
        Some("check") => ExitCode::SUCCESS,
        Some("run") => {
            let runtime = match tokio::runtime::Runtime::new() {
                Ok(runtime) => runtime,
                Err(error) => {
                    eprintln!("runtime: {error}");
                    return ExitCode::FAILURE;
                }
            };
            runtime.block_on(run(plan))
        }
        _ => usage(),
    }
}

async fn run(plan: config::Plan) -> ExitCode {
    let running = match gorion_engine::run(&plan).await {
        Ok(running) => running,
        Err(error) => {
            eprintln!("start: {error}");
            return ExitCode::FAILURE;
        }
    };
    println!(
        "gorion-engine {}: {} servers, proxy {}",
        env!("CARGO_PKG_VERSION"),
        plan.members.len(),
        running.local_addr()
    );
    if let Err(error) = shutdown_signal().await {
        eprintln!("signal: {error}");
        return ExitCode::FAILURE;
    }
    println!("gorion-engine stopped");
    drop(running);
    ExitCode::SUCCESS
}

/// SIGTERM от ядра Gorion или Ctrl+C.
#[cfg(unix)]
async fn shutdown_signal() -> std::io::Result<()> {
    use tokio::signal::unix::{SignalKind, signal};
    let mut terminate = signal(SignalKind::terminate())?;
    tokio::select! {
        _ = terminate.recv() => Ok(()),
        result = tokio::signal::ctrl_c() => result,
    }
}

#[cfg(not(unix))]
async fn shutdown_signal() -> std::io::Result<()> {
    tokio::signal::ctrl_c().await
}
