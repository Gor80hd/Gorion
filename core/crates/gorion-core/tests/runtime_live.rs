//! Живой запуск своего движка `gorion-engine` в режиме «Вручную» (mixed).
//! Системный прокси и маршруты не трогаются. Пропускается, если движок ещё
//! не собран (`cargo build -p gorion-engine`).
#![allow(clippy::unwrap_used)]

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use gorion_core::error::CoreError;
use gorion_core::runtime::RuntimeMode;
use gorion_core::runtime::process::{Signal, is_alive, read_marker, send_signal};
use gorion_core::runtime::service::{RuntimeEvent, RuntimeService, StartRequest};

/// Движок из той же сборки, что и тест (`target/<профиль>/gorion-engine`).
fn engine() -> Option<PathBuf> {
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

const TEMPLATE: &str = r#"{
  "outbounds": [
    {"type": "shadowsocks", "tag": "Local A", "server": "127.0.0.1", "server_port": 9,
     "method": "aes-128-gcm", "password": "test-password"},
    {"type": "shadowsocks", "tag": "Local B", "server": "127.0.0.1", "server_port": 10,
     "method": "aes-128-gcm", "password": "test-password"}
  ]
}"#;

fn request(template: &str) -> StartRequest {
    StartRequest {
        profile_id: "test".into(),
        template_config: template.into(),
        mode: RuntimeMode::Mixed,
        selected_server_tag: Some("Local B".into()),
        url_test_url: "https://www.gstatic.com/generate_204".into(),
        bypass_steam: false,
        split_tunnel: None,
    }
}

type Events = Arc<Mutex<Vec<RuntimeEvent>>>;

fn service(dir: &std::path::Path, engine: PathBuf) -> (Arc<RuntimeService>, Events) {
    let events = Events::default();
    let sink = events.clone();
    let service = RuntimeService::new(
        dir.to_path_buf(),
        engine,
        Arc::new(move |e| sink.lock().unwrap().push(e)),
    );
    (service, events)
}

#[tokio::test(flavor = "multi_thread")]
async fn starts_selects_and_stops_the_engine() {
    let Some(engine) = engine() else { return };
    let dir = tempfile::tempdir().unwrap();
    let (service, events) = service(dir.path(), engine);

    let session = service.start(request(TEMPLATE)).await.unwrap();
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
    let Some(engine) = engine() else { return };
    let dir = tempfile::tempdir().unwrap();
    let (service, events) = service(dir.path(), engine);
    let session = service.start(request(TEMPLATE)).await.unwrap();
    send_signal(session.pid, Signal::Kill);
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

/// Профиль, которого движок не умеет, не запускается: причина от
/// `gorion-engine check` уходит в ошибку и в журнал, процесса нет.
#[tokio::test(flavor = "multi_thread")]
async fn refuses_a_profile_the_engine_cannot_run() {
    let Some(engine) = engine() else { return };
    let dir = tempfile::tempdir().unwrap();
    let (service, _) = service(dir.path(), engine);
    let vmess = TEMPLATE.replace(
        r#"{"type": "shadowsocks", "tag": "Local B", "server": "127.0.0.1", "server_port": 10,
     "method": "aes-128-gcm", "password": "test-password"}"#,
        r#"{"type": "vmess", "tag": "Local B", "server": "127.0.0.1", "server_port": 10,
     "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811"}"#,
    );
    assert_ne!(vmess, TEMPLATE);
    let error = service.start(request(&vmess)).await.unwrap_err();
    let CoreError::EngineUnsupported(reason) = &error else {
        panic!("EngineUnsupported expected, got {error:?}");
    };
    assert!(reason.contains("server #2"), "{reason}");
    assert!(service.session().await.is_none());
    assert!(read_marker(dir.path()).await.is_none());
}
