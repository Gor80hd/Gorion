//! Живой запуск настоящего sing-box в режиме «Вручную» (mixed).
//! Системный прокси и маршруты не трогаются. Пропускается, если бинарника
//! нет (`dart run tool/vendor_singbox.dart`).
#![allow(clippy::unwrap_used)]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use gorion_core::runtime::RuntimeMode;
use gorion_core::runtime::process::{is_alive, read_marker};
use gorion_core::runtime::service::{RuntimeEvent, RuntimeService, StartRequest};

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

const TEMPLATE: &str = r#"{
  "outbounds": [
    {"type": "shadowsocks", "tag": "Local A", "server": "127.0.0.1", "server_port": 9,
     "method": "aes-128-gcm", "password": "test-password"},
    {"type": "shadowsocks", "tag": "Local B", "server": "127.0.0.1", "server_port": 10,
     "method": "aes-128-gcm", "password": "test-password"}
  ]
}"#;

#[tokio::test(flavor = "multi_thread")]
async fn starts_selects_and_stops_real_singbox() {
    let Some(binary) = singbox() else {
        eprintln!("sing-box не найден — тест пропущен");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let events = Arc::new(Mutex::new(Vec::<RuntimeEvent>::new()));
    let sink = events.clone();
    let service = RuntimeService::new(
        dir.path().to_path_buf(),
        binary,
        Arc::new(move |e| sink.lock().unwrap().push(e)),
    );

    let session = service
        .start(StartRequest {
            profile_id: "test".into(),
            template_config: TEMPLATE.into(),
            mode: RuntimeMode::Mixed,
            selected_server_tag: Some("Local B".into()),
            url_test_url: "https://www.gstatic.com/generate_204".into(),
            bypass_steam: false,
            split_tunnel: None,
        })
        .await
        .unwrap();
    assert!(is_alive(session.pid));
    assert_eq!(read_marker(dir.path()).await.unwrap().pid, session.pid);

    let clash = session.clash().unwrap();
    let snapshot = clash.snapshot(&session.manual_selector_tag).await.unwrap();
    assert_eq!(snapshot.selected_tag.as_deref(), Some("Local B"));
    clash
        .select_proxy(&session.manual_selector_tag, "Local A")
        .await
        .unwrap();
    let snapshot = clash.snapshot(&session.manual_selector_tag).await.unwrap();
    assert_eq!(snapshot.selected_tag.as_deref(), Some("Local A"));

    service.stop().await.unwrap();
    assert!(!is_alive(session.pid));
    assert!(read_marker(dir.path()).await.is_none());
    // Остановка по stop() — не «неожиданный выход».
    tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    assert!(events.lock().unwrap().is_empty());
    // Повторная остановка безопасна.
    service.stop().await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn reports_unexpected_exit() {
    let Some(binary) = singbox() else { return };
    let dir = tempfile::tempdir().unwrap();
    let events = Arc::new(Mutex::new(Vec::<RuntimeEvent>::new()));
    let sink = events.clone();
    let service = RuntimeService::new(
        dir.path().to_path_buf(),
        binary,
        Arc::new(move |e| sink.lock().unwrap().push(e)),
    );
    let session = service
        .start(StartRequest {
            profile_id: "test".into(),
            template_config: TEMPLATE.into(),
            mode: RuntimeMode::Mixed,
            selected_server_tag: None,
            url_test_url: "https://www.gstatic.com/generate_204".into(),
            bypass_steam: false,
            split_tunnel: None,
        })
        .await
        .unwrap();
    gorion_core::runtime::process::send_signal(
        session.pid,
        gorion_core::runtime::process::Signal::Kill,
    );
    for _ in 0..40 {
        if !events.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    assert!(matches!(
        events.lock().unwrap().first(),
        Some(RuntimeEvent::UnexpectedExit { .. })
    ));
    assert!(service.session().await.is_none());
    assert!(read_marker(dir.path()).await.is_none());
}
