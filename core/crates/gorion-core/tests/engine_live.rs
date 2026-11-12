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

fn singbox() -> Option<PathBuf> {
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x64"
    };
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("../../../assets/singbox/macos/{arch}/sing-box"));
    (cfg!(target_os = "macos") && path.is_file()).then_some(path)
}

const SUBSCRIPTION: &str = r#"{
  "outbounds": [
    {"type": "shadowsocks", "tag": "[DE] Dead One", "server": "127.0.0.1", "server_port": 9,
     "method": "aes-128-gcm", "password": "test-password"},
    {"type": "shadowsocks", "tag": "Dead Two", "server": "127.0.0.1", "server_port": 10,
     "method": "aes-128-gcm", "password": "test-password"}
  ]
}"#;

/// Однократный HTTP-сервер на 127.0.0.1, отдаёт подписку.
async fn serve_subscription() -> String {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut socket, _)) = listener.accept().await {
            let mut buffer = [0u8; 2048];
            let _ = socket.read(&mut buffer).await;
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nprofile-title: Test\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                SUBSCRIPTION.len(),
                SUBSCRIPTION
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
    let Some(binary) = singbox() else { return };
    let dir = tempfile::tempdir().unwrap();
    let recorder = Arc::new(Recorder::default());
    let engine = Engine::new(dir.path().to_path_buf(), binary, recorder.clone());
    engine.bootstrap().await;
    assert!(!engine.snapshot().bootstrapping);

    engine.set_mode(RuntimeMode::Mixed).await;
    engine.add_subscription(&serve_subscription().await).await;
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
        singbox().unwrap(),
        Arc::new(Recorder::default()),
    );
    reopened.bootstrap().await;
    assert_eq!(reopened.snapshot().mode, RuntimeMode::Mixed);
    assert_eq!(reopened.snapshot().profiles.len(), 1);
    assert!(!recorder.snapshots.lock().unwrap().is_empty());
}
