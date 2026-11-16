//! Процесс `gorion-engine` так, как его запускает ядро Gorion: конфигурация
//! Gorion, Clash API, SIGTERM. Внешние серверы не нужны — серверы здесь
//! «прямые», а протоколы проверяет `engine.rs`.
#![allow(clippy::unwrap_used)]

use std::net::SocketAddr;
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};

const SECRET: &str = "test-secret";

async fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Конфигурация в том виде, в каком её строит `config_builder` ядра.
fn config(mixed: u16, controller: u16) -> serde_json::Value {
    serde_json::json!({
        "log": { "level": "info" },
        "inbounds": [{ "type": "mixed", "tag": "gorion-mixed", "listen": "127.0.0.1", "listen_port": mixed }],
        "outbounds": [
            { "type": "direct", "tag": "A" },
            { "type": "direct", "tag": "B" },
            { "type": "direct", "tag": "direct" },
            { "type": "selector", "tag": "gorion-manual", "outbounds": ["A", "B"], "default": "A",
              "interrupt_exist_connections": true },
            { "type": "urltest", "tag": "gorion-auto", "outbounds": ["A", "B"],
              "url": "https://www.gstatic.com/generate_204" }
        ],
        "route": { "auto_detect_interface": true, "final": "gorion-manual" },
        "experimental": { "clash_api": {
            "external_controller": format!("127.0.0.1:{controller}"),
            "secret": SECRET, "default_mode": "Rule"
        } }
    })
}

/// Простой HTTP/1.1 к контроллеру: (код, тело).
async fn call(port: u16, method: &str, path: &str, body: &str, auth: bool) -> (u16, String) {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await.unwrap();
    let auth = if auth {
        format!("Authorization: Bearer {SECRET}\r\n")
    } else {
        String::new()
    };
    let request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n{auth}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).await.unwrap();
    let status = response[9..12].parse().unwrap();
    let body = response
        .split_once("\r\n\r\n")
        .map(|(_, b)| b.to_owned())
        .unwrap_or_default();
    (status, body)
}

async fn http_server() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (mut stream, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf).await;
                let _ = stream
                    .write_all(b"HTTP/1.1 204 No Content\r\nConnection: close\r\n\r\n")
                    .await;
            });
        }
    });
    addr
}

async fn echo_server() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            tokio::spawn(async move {
                let (mut read, mut write) = stream.into_split();
                let _ = tokio::io::copy(&mut read, &mut write).await;
            });
        }
    });
    addr
}

#[tokio::test]
async fn engine_process_speaks_clash_api() {
    let binary = env!("CARGO_BIN_EXE_gorion-engine");
    let dir = tempfile::tempdir().unwrap();
    let (mixed, controller) = (free_port().await, free_port().await);
    let path = dir.path().join("config.json");
    std::fs::write(&path, config(mixed, controller).to_string()).unwrap();

    // check: принимает конфигурацию ядра, отказывается от TUN.
    let status = tokio::process::Command::new(binary)
        .args(["check", "-c"])
        .arg(&path)
        .status()
        .await
        .unwrap();
    assert!(status.success());
    let mut tun = config(mixed, controller);
    tun["inbounds"] = serde_json::json!([{ "type": "tun", "tag": "gorion-tun" }]);
    let tun_path = dir.path().join("tun.json");
    std::fs::write(&tun_path, tun.to_string()).unwrap();
    let output = tokio::process::Command::new(binary)
        .args(["check", "-c"])
        .arg(&tun_path)
        .output()
        .await
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("unsupported"));

    let mut child = tokio::process::Command::new(binary)
        .args(["run", "-c"])
        .arg(&path)
        .stdout(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap()).lines();
    let started = tokio::time::timeout(Duration::from_secs(10), stdout.next_line())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(started.contains("2 servers"), "{started}");

    // Как wait_until_ready и ClashClient ядра.
    assert_eq!(call(controller, "GET", "/version", "", false).await.0, 401);
    assert_eq!(call(controller, "GET", "/version", "", true).await.0, 200);
    let (_, proxies) = call(controller, "GET", "/proxies", "", true).await;
    let proxies: serde_json::Value = serde_json::from_str(&proxies).unwrap();
    assert_eq!(proxies["proxies"]["gorion-manual"]["now"], "A");

    let (status, _) = call(
        controller,
        "PUT",
        "/proxies/gorion-manual",
        r#"{"name":"B"}"#,
        true,
    )
    .await;
    assert_eq!(status, 204);
    let (status, _) = call(
        controller,
        "PUT",
        "/proxies/gorion-manual",
        r#"{"name":"Z"}"#,
        true,
    )
    .await;
    assert_eq!(status, 400);
    let (_, proxies) = call(controller, "GET", "/proxies", "", true).await;
    let proxies: serde_json::Value = serde_json::from_str(&proxies).unwrap();
    assert_eq!(proxies["proxies"]["gorion-manual"]["now"], "B");

    // URL-тест — настоящий HTTP-запрос; задержка попадает в историю.
    let web = http_server().await;
    let url = format!("http%3A%2F%2F{web}%2Fgenerate_204");
    let (status, body) = call(
        controller,
        "GET",
        &format!("/proxies/A/delay?url={url}&timeout=3000"),
        "",
        true,
    )
    .await;
    assert_eq!(status, 200, "{body}");
    let delay: serde_json::Value = serde_json::from_str(&body).unwrap();
    assert!(delay["delay"].as_u64().unwrap() >= 1);
    let (_, proxies) = call(controller, "GET", "/proxies", "", true).await;
    assert!(proxies.contains("\"history\":[{\"delay\""));
    let closed = free_port().await;
    let (status, _) = call(
        controller,
        "GET",
        &format!("/proxies/A/delay?url=http%3A%2F%2F127.0.0.1%3A{closed}%2F&timeout=2000"),
        "",
        true,
    )
    .await;
    assert!(
        status == 503 || status == 504,
        "dead server must not get a delay"
    );
    assert_eq!(
        call(controller, "GET", "/proxies/nope/delay?url=x", "", true)
            .await
            .0,
        404
    );

    // Трафик через вход виден в /traffic.
    let mut traffic = TcpStream::connect(("127.0.0.1", controller)).await.unwrap();
    traffic
        .write_all(
            format!("GET /traffic HTTP/1.1\r\nHost: x\r\nAuthorization: Bearer {SECRET}\r\n\r\n")
                .as_bytes(),
        )
        .await
        .unwrap();
    let echo = echo_server().await;
    let mut proxied = TcpStream::connect(("127.0.0.1", mixed)).await.unwrap();
    proxied
        .write_all(format!("CONNECT {echo} HTTP/1.1\r\nHost: {echo}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut head = [0u8; 39];
    proxied.read_exact(&mut head).await.unwrap();
    assert!(head.starts_with(b"HTTP/1.1 200"));
    let payload = vec![7u8; 100_000];
    proxied.write_all(&payload).await.unwrap();
    let mut back = vec![0u8; payload.len()];
    proxied.read_exact(&mut back).await.unwrap();
    assert_eq!(back, payload);
    // Строки {"up":…,"down":…} внутри кусков chunked: суммируем.
    let mut seen = String::new();
    let mut buf = [0u8; 1024];
    let deadline = tokio::time::Instant::now() + Duration::from_secs(6);
    loop {
        let (up, down) = seen
            .split(['\r', '\n'])
            .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
            .filter(serde_json::Value::is_object)
            .fold((0, 0), |(u, d), v| {
                (
                    u + v["up"].as_u64().unwrap_or(0),
                    d + v["down"].as_u64().unwrap_or(0),
                )
            });
        if up >= payload.len() as u64 && down >= payload.len() as u64 {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "traffic not counted: {seen}"
        );
        let n = tokio::time::timeout(Duration::from_secs(3), traffic.read(&mut buf))
            .await
            .unwrap()
            .unwrap();
        seen.push_str(&String::from_utf8_lossy(&buf[..n]));
    }

    // Смена сервера рвёт открытые подключения, как в sing-box.
    call(
        controller,
        "PUT",
        "/proxies/gorion-manual",
        r#"{"name":"A"}"#,
        true,
    )
    .await;
    let mut rest = [0u8; 1];
    let read = tokio::time::timeout(Duration::from_secs(3), proxied.read(&mut rest)).await;
    assert!(
        matches!(read, Ok(Ok(0)) | Ok(Err(_))),
        "old connection must close"
    );

    // SIGTERM — штатная остановка.
    let pid = child.id().unwrap() as i32;
    std::process::Command::new("kill")
        .args(["-TERM", &pid.to_string()])
        .status()
        .unwrap();
    let status = tokio::time::timeout(Duration::from_secs(5), child.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(status.success());
}
