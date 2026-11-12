//! Помощник целиком, но без root: отдельный процесс `gorion-helper serve` на
//! временном сокете. Ядро запускается в режиме «Вручную» (`--allow-non-tun`),
//! поэтому TUN, маршруты и системный прокси не трогаются (правило 5).

#![allow(clippy::unwrap_used)]

use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gorion_core::helper::client::{HelperClient, TunRuntime};
use gorion_core::helper::{HelperStart, HelperStatus, Request};
use gorion_core::runtime::RuntimeMode;
use gorion_core::runtime::process::{Signal, is_alive, send_signal};
use gorion_core::runtime::service::{RuntimeEvent, StartRequest};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;

struct Helper {
    child: Child,
    socket: PathBuf,
    _dir: tempfile::TempDir,
}

impl Drop for Helper {
    fn drop(&mut self) {
        // SIGTERM: помощник должен сам погасить ядро.
        send_signal(self.child.id() as i32, Signal::Terminate);
        let _ = self.child.wait();
    }
}

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

async fn spawn_helper(allow_non_tun: bool, singbox: &Path) -> Helper {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("helper.sock");
    let mut command = Command::new(env!("CARGO_BIN_EXE_gorion-helper"));
    command
        .arg("serve")
        .arg("--socket")
        .arg(&socket)
        .arg("--runtime-dir")
        .arg(dir.path().join("runtime"))
        .arg("--singbox")
        .arg(singbox)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit());
    if allow_non_tun {
        command.arg("--allow-non-tun");
    }
    let helper = Helper {
        child: command.spawn().unwrap(),
        socket,
        _dir: dir,
    };
    let client = HelperClient::new(&helper.socket);
    for _ in 0..100 {
        if client.status().await == HelperStatus::Ready {
            return helper;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("helper did not start");
}

const TEMPLATE: &str = r#"{
  "outbounds": [
    {"type": "shadowsocks", "tag": "Local A", "server": "127.0.0.1", "server_port": 9,
     "method": "aes-128-gcm", "password": "test-password"}
  ]
}"#;

fn request(mode: RuntimeMode) -> StartRequest {
    StartRequest {
        profile_id: "test".into(),
        template_config: TEMPLATE.into(),
        mode,
        selected_server_tag: None,
        url_test_url: "https://www.gstatic.com/generate_204".into(),
        bypass_steam: false,
        split_tunnel: None,
    }
}

type Events = Arc<Mutex<Vec<RuntimeEvent>>>;

fn tun_runtime(helper: &Helper) -> (Arc<TunRuntime>, Events) {
    let events = Events::default();
    let sink = events.clone();
    let runtime = TunRuntime::new(
        HelperClient::new(&helper.socket),
        Arc::new(move |e| sink.lock().unwrap().push(e)),
    );
    (runtime, events)
}

async fn wait_until(mut condition: impl FnMut() -> bool) -> bool {
    for _ in 0..100 {
        if condition() {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    false
}

#[tokio::test]
async fn missing_helper_reports_not_installed() {
    let dir = tempfile::tempdir().unwrap();
    let client = HelperClient::new(dir.path().join("nothing.sock"));
    assert_eq!(client.status().await, HelperStatus::NotInstalled);
    let (runtime, _) = (TunRuntime::new(client, Arc::new(|_| {})), ());
    let error = runtime
        .start(&request(RuntimeMode::Tun), false)
        .await
        .unwrap_err();
    assert_eq!(error.code(), gorion_core::ErrorCode::TunHelperRequired);
}

#[tokio::test]
async fn helper_refuses_everything_but_tun() {
    // Бинарник не нужен: запрос отклоняется до запуска ядра.
    let helper = spawn_helper(false, Path::new("/nonexistent/sing-box")).await;
    let (runtime, _) = tun_runtime(&helper);
    let error = runtime
        .start(&request(RuntimeMode::Mixed), false)
        .await
        .unwrap_err();
    assert_eq!(error.code(), gorion_core::ErrorCode::Unsupported);
}

#[tokio::test]
async fn rejects_garbage_and_survives() {
    let helper = spawn_helper(false, Path::new("/nonexistent/sing-box")).await;
    let mut stream = UnixStream::connect(&helper.socket).await.unwrap();
    stream.write_all(b"{not json}\n").await.unwrap();
    let mut line = String::new();
    BufReader::new(&mut stream)
        .read_line(&mut line)
        .await
        .unwrap();
    assert!(line.contains(r#""event":"error""#), "{line}");
    // Служба жива и отвечает следующим.
    assert_eq!(
        HelperClient::new(&helper.socket).status().await,
        HelperStatus::Ready
    );
    // Формат запроса из протокола тоже принимается как есть.
    let start = Request::Start(HelperStart {
        profile_id: "x".into(),
        template_config: "{}".into(),
        mode: RuntimeMode::Tun,
        selected_server_tag: None,
        url_test_url: "https://x/".into(),
        sing_box_only: false,
    });
    assert!(
        serde_json::to_string(&start)
            .unwrap()
            .starts_with(r#"{"op":"start""#)
    );
}

#[tokio::test(flavor = "multi_thread")]
async fn lease_controls_the_core() {
    let Some(binary) = singbox() else {
        eprintln!("sing-box не найден — тест пропущен");
        return;
    };
    let helper = spawn_helper(true, &binary).await;

    // 1. Явная остановка.
    let (runtime, events) = tun_runtime(&helper);
    let session = runtime
        .start(&request(RuntimeMode::Mixed), false)
        .await
        .unwrap();
    assert!(is_alive(session.pid));
    assert!(session.mixed_port > 0 && session.controller_port > 0);
    runtime.stop().await.unwrap();
    assert!(wait_until(|| !is_alive(session.pid)).await, "stop");
    runtime.stop().await.unwrap(); // идемпотентно

    // 2. Приложение пропало, не сказав `stop`: аренда закрылась — ядро гаснет.
    let session = runtime
        .start(&request(RuntimeMode::Mixed), false)
        .await
        .unwrap();
    drop(runtime);
    assert!(wait_until(|| !is_alive(session.pid)).await, "lease close");
    assert!(events.lock().unwrap().is_empty());

    // 3. Ядро упало само — приложение узнаёт об этом по аренде.
    let (runtime, events) = tun_runtime(&helper);
    let session = runtime
        .start(&request(RuntimeMode::Mixed), false)
        .await
        .unwrap();
    send_signal(session.pid, Signal::Kill);
    assert!(
        wait_until(|| !events.lock().unwrap().is_empty()).await,
        "exit event"
    );
    assert!(matches!(
        events.lock().unwrap()[0],
        RuntimeEvent::UnexpectedExit { .. }
    ));
    runtime.stop().await.unwrap();

    // 4. Новый запуск заменяет прежний; закрытие старой аренды его не трогает.
    let (first, _) = tun_runtime(&helper);
    let (second, _) = tun_runtime(&helper);
    let old = first
        .start(&request(RuntimeMode::Mixed), false)
        .await
        .unwrap();
    let new = second
        .start(&request(RuntimeMode::Mixed), false)
        .await
        .unwrap();
    assert!(wait_until(|| !is_alive(old.pid)).await, "replaced");
    drop(first);
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(is_alive(new.pid), "old lease must not stop the new session");
    let logs = HelperClient::new(&helper.socket).logs().await.unwrap();
    assert!(
        logs.iter().any(|l| l.contains("sing-box запущен")),
        "{logs:?}"
    );

    // 5. Остановка службы гасит ядро.
    drop(helper);
    assert!(wait_until(|| !is_alive(new.pid)).await, "helper shutdown");
}
