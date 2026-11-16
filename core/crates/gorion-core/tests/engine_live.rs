//! Движок целиком, без внешней сети: подписка с локального HTTP-сервера,
//! серверы в ней мёртвые. Режим «Вручную» — системный прокси не трогается.
#![allow(clippy::unwrap_used)]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use gorion_core::ErrorCode;
use gorion_core::engine::{ConnectionStage, Engine, EngineObserver, EngineSnapshot, Notice};
use gorion_core::runtime::RuntimeMode;
use gorion_core::runtime::process::read_marker;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// `gorion-engine` из той же сборки, что и тест (`target/<профиль>/`).
fn engine_binary() -> Option<PathBuf> {
    let path = std::env::current_exe()
        .ok()?
        .parent()?
        .parent()?
        .join("gorion-engine");
    if !path.is_file() {
        eprintln!("gorion-engine не собран — тест пропущен");
        return None;
    }
    cfg!(unix).then_some(path)
}

/// Ссылки Shadowsocks на мёртвые порты (`aes-128-gcm:test-password`).
const SS_A: &str = "ss://YWVzLTEyOC1nY206dGVzdC1wYXNzd29yZA==@127.0.0.1:9#%5BDE%5D%20Dead%20One";
const SS_B: &str = "ss://YWVzLTEyOC1nY206dGVzdC1wYXNzd29yZA==@127.0.0.1:10#Dead%20Two";
/// VMess движок не умеет.
const VMESS: &str = "vmess://eyJ2IjogIjIiLCAicHMiOiAiVk0iLCAiYWRkIjogIjEyNy4wLjAuMSIsICJwb3J0IjogIjEwIiwgImlkIjogImI4MzEzODFkLTYzMjQtNGQ1My1hZDRmLThjZGE0OGIzMDgxMSIsICJhaWQiOiAiMCIsICJuZXQiOiAidGNwIiwgInR5cGUiOiAibm9uZSIsICJ0bHMiOiAiIn0=";

/// HTTP-сервер на 127.0.0.1, отдаёт подписку `body` (список ссылок).
async fn serve(body: String) -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let mut buffer = [0u8; 2048];
            let _ = socket.read(&mut buffer).await;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nprofile-title: Test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            let _ = socket.write_all(response.as_bytes()).await;
        }
    });
    format!("http://127.0.0.1:{port}/sub")
}

#[derive(Default)]
struct Recorder {
    snapshots: Mutex<Vec<EngineSnapshot>>,
}

impl EngineObserver for Recorder {
    fn on_snapshot(&self, snapshot: EngineSnapshot) {
        self.snapshots.lock().unwrap().push(snapshot);
    }
    fn on_traffic(&self, _up: u64, _down: u64) {}
}

#[tokio::test(flavor = "multi_thread")]
async fn add_connect_fails_honestly_and_cleans_up() {
    let Some(binary) = engine_binary() else {
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let recorder = Arc::new(Recorder::default());
    let engine = Engine::new(dir.path().to_path_buf(), binary.clone(), recorder.clone());
    engine.bootstrap().await;
    assert!(!engine.snapshot().bootstrapping);

    engine.set_mode(RuntimeMode::Mixed).await;
    engine
        .add_subscription(&serve(format!("{SS_A}\n{SS_B}\n")).await)
        .await;
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.error, None, "{:?}", snapshot.error);
    assert!(matches!(
        snapshot.notice,
        Some(Notice::SubscriptionAdded { .. })
    ));
    assert_eq!(snapshot.servers.len(), 2);
    assert_eq!(snapshot.servers[0].country_code.as_deref(), Some("DE"));
    assert_eq!(snapshot.servers[0].name, "Dead One");

    engine.measure_delays().await;
    let snapshot = engine.snapshot();
    assert!(!snapshot.measuring_delays);
    assert!(
        snapshot
            .servers
            .iter()
            .all(|s| s.delay_ms.unwrap_or(0) <= 0)
    );

    engine.select_server(&snapshot.servers[1].tag).await;
    assert_eq!(
        engine.snapshot().notice,
        Some(Notice::ServerSavedForNextConnection)
    );
    assert_eq!(engine.snapshot().selected_tag.as_deref(), Some("Dead Two"));

    // Сервер мёртв: подключение не должно притворяться рабочим.
    engine.connect().await;
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.stage, ConnectionStage::Disconnected);
    assert_eq!(
        snapshot.error.as_ref().map(|e| e.code),
        Some(ErrorCode::InternetUnavailable)
    );
    assert!(read_marker(&dir.path().join("runtime")).await.is_none());

    // Удаление и отмена удаления.
    let id = snapshot.active_profile_id.clone().unwrap();
    engine.remove_profile(&id).await;
    assert!(engine.snapshot().profiles.is_empty());
    assert!(engine.snapshot().can_undo_remove);
    engine.undo_remove().await;
    assert_eq!(engine.snapshot().profiles.len(), 1);
    assert_eq!(
        engine.snapshot().active_profile_id.as_deref(),
        Some(id.as_str())
    );

    // Состояние переживает перезапуск.
    let reopened = Engine::new(
        dir.path().to_path_buf(),
        binary,
        Arc::new(Recorder::default()),
    );
    reopened.bootstrap().await;
    assert_eq!(reopened.snapshot().mode, RuntimeMode::Mixed);
    assert_eq!(reopened.snapshot().profiles.len(), 1);
    assert!(!recorder.snapshots.lock().unwrap().is_empty());
}

/// Профиль, который движок не умеет, даёт `EngineUnsupported`, а не тихий
/// откат; мёртвый сервер — честное `InternetUnavailable`, без второй попытки.
#[tokio::test(flavor = "multi_thread")]
async fn unsupported_profile_fails_without_fallback() {
    let Some(binary) = engine_binary() else {
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let data = dir.path().join("data");
    let engine = Engine::new(data.clone(), binary, Arc::new(Recorder::default()));
    engine.bootstrap().await;
    engine.set_mode(RuntimeMode::Mixed).await;

    engine
        .add_subscription(&serve(format!("{SS_A}\n{VMESS}\n")).await)
        .await;
    assert_eq!(engine.snapshot().error, None);
    engine.connect().await;
    let error = engine
        .snapshot()
        .error
        .expect("unsupported profile must fail");
    assert_eq!(error.code, ErrorCode::EngineUnsupported);
    assert!(read_marker(&data.join("runtime")).await.is_none());

    let id = engine.snapshot().active_profile_id.clone().unwrap();
    engine.remove_profile(&id).await;
    engine
        .add_subscription(&serve(format!("{SS_A}\n")).await)
        .await;
    engine.connect().await;
    let snapshot = engine.snapshot();
    assert_eq!(snapshot.stage, ConnectionStage::Disconnected);
    assert_eq!(
        snapshot.error.as_ref().map(|e| e.code),
        Some(ErrorCode::InternetUnavailable)
    );
    assert!(read_marker(&data.join("runtime")).await.is_none());
}
