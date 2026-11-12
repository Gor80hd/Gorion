//! Сквозные проверки движка на loopback: системные маршруты и прокси не
//! трогаются (правило 5).
//!
//! `singbox_interop` проверяет совместимость с настоящим сервером sing-box и
//! запускается, только если задан `GORION_SINGBOX` — путь к бинарнику.

#![allow(clippy::unwrap_used)]

use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use gorion_engine::{EngineConfig, Method, Outbound, ShadowsocksConfig, TargetAddr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Эхо-сервер: возвращает всё, что получил, и закрывается вслед за клиентом.
async fn echo_server() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let (mut read, mut write) = stream.split();
                let _ = tokio::io::copy(&mut read, &mut write).await;
                let _ = write.shutdown().await;
            });
        }
    });
    addr
}

/// HTTP-сервер, который отвечает телом с первой строкой запроса.
async fn http_server() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let mut buf = vec![0u8; 4096];
                let mut head = Vec::new();
                while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                    let n = stream.read(&mut buf).await.unwrap();
                    if n == 0 {
                        return;
                    }
                    head.extend_from_slice(&buf[..n]);
                }
                let body = String::from_utf8_lossy(&head).to_string();
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\n\r\n{body}",
                    body.len()
                );
                stream.write_all(response.as_bytes()).await.unwrap();
            });
        }
    });
    addr
}

async fn socks_connect(proxy: SocketAddr, target: SocketAddr) -> TcpStream {
    let mut stream = TcpStream::connect(proxy).await.unwrap();
    stream.write_all(&[5, 1, 0]).await.unwrap();
    let mut reply = [0u8; 2];
    stream.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply, [5, 0]);
    let mut request = vec![5, 1, 0];
    TargetAddr::Ip(target).write_socks(&mut request).unwrap();
    stream.write_all(&request).await.unwrap();
    let mut reply = [0u8; 10];
    stream.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply[1], 0, "socks reply code");
    stream
}

/// Отправляет 300 КБ (больше куска Shadowsocks) и ждёт их обратно целиком.
async fn assert_echo(mut stream: TcpStream) {
    let data: Vec<u8> = (0..300_000u32)
        .map(|i| (i.wrapping_mul(31) % 256) as u8)
        .collect();
    let (mut read, mut write) = stream.split();
    let send = async {
        write.write_all(&data).await.unwrap();
        write.shutdown().await.unwrap();
    };
    let receive = async {
        let mut got = Vec::new();
        read.read_to_end(&mut got).await.unwrap();
        got
    };
    let ((), got) = tokio::join!(send, receive);
    assert_eq!(got.len(), data.len());
    assert!(got == data, "echoed bytes differ");
}

async fn start(outbound: Outbound) -> gorion_engine::EngineHandle {
    gorion_engine::start(EngineConfig {
        listen: "127.0.0.1:0".parse().unwrap(),
        outbound,
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn socks_direct_echo() {
    let echo = echo_server().await;
    let engine = start(Outbound::Direct).await;
    assert_echo(socks_connect(engine.local_addr(), echo).await).await;
}

#[tokio::test]
async fn http_forward_rewrites_request() {
    let server = http_server().await;
    let engine = start(Outbound::Direct).await;
    let mut stream = TcpStream::connect(engine.local_addr()).await.unwrap();
    let request = format!(
        "GET http://{server}/path?q=1 HTTP/1.1\r\nHost: {server}\r\nProxy-Connection: keep-alive\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).await.unwrap();
    assert!(response.starts_with("HTTP/1.1 200 OK"), "{response}");
    assert!(response.contains("GET /path?q=1 HTTP/1.1\r\n"));
    assert!(!response.to_ascii_lowercase().contains("proxy-connection"));
}

#[tokio::test]
async fn http_connect_tunnel() {
    let echo = echo_server().await;
    let engine = start(Outbound::Direct).await;
    let mut stream = TcpStream::connect(engine.local_addr()).await.unwrap();
    stream
        .write_all(format!("CONNECT {echo} HTTP/1.1\r\nHost: {echo}\r\n\r\n").as_bytes())
        .await
        .unwrap();
    let mut head = [0u8; 39];
    stream.read_exact(&mut head).await.unwrap();
    assert_eq!(&head, b"HTTP/1.1 200 Connection established\r\n\r\n");
    assert_echo(stream).await;
}

#[tokio::test]
async fn socks_reports_refused_target() {
    // Порт, на котором точно никто не слушает.
    let closed = TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap();
    let engine = start(Outbound::Direct).await;
    let mut stream = TcpStream::connect(engine.local_addr()).await.unwrap();
    stream.write_all(&[5, 1, 0]).await.unwrap();
    let mut reply = [0u8; 2];
    stream.read_exact(&mut reply).await.unwrap();
    let mut request = vec![5, 1, 0];
    TargetAddr::Ip(closed).write_socks(&mut request).unwrap();
    stream.write_all(&request).await.unwrap();
    let mut reply = [0u8; 10];
    stream.read_exact(&mut reply).await.unwrap();
    assert_eq!(reply[1], 5, "connection refused");
}

// --- Совместимость с sing-box ------------------------------------------------

fn singbox_path() -> Option<PathBuf> {
    std::env::var_os("GORION_SINGBOX")
        .map(PathBuf::from)
        .filter(|p| p.exists())
}

struct SingBox(tokio::process::Child);

impl Drop for SingBox {
    fn drop(&mut self) {
        let _ = self.0.start_kill();
    }
}

async fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

async fn start_singbox_ss(
    binary: &PathBuf,
    dir: &std::path::Path,
    method: Method,
    password: &str,
) -> (SingBox, u16) {
    let port = free_port().await;
    let config = serde_json::json!({
        "log": { "level": "error" },
        "inbounds": [{
            "type": "shadowsocks", "tag": "in", "listen": "127.0.0.1",
            "listen_port": port, "method": method.name(), "password": password
        }],
        "outbounds": [{ "type": "direct", "tag": "direct" }]
    });
    let path = dir.join(format!("ss-{}.json", method.name()));
    std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
    let child = tokio::process::Command::new(binary)
        .args(["run", "-c"])
        .arg(&path)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return (SingBox(child), port);
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("sing-box did not start");
}

#[tokio::test]
async fn singbox_interop() {
    let Some(binary) = singbox_path() else {
        eprintln!("GORION_SINGBOX не задан — проверка совместимости с sing-box пропущена");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let echo = echo_server().await;
    for method in [
        Method::Aes128Gcm,
        Method::Aes256Gcm,
        Method::Chacha20Poly1305,
    ] {
        let password = "gorion-test-password";
        let (_server, port) = start_singbox_ss(&binary, dir.path(), method, password).await;
        let server = TargetAddr::Ip(SocketAddr::from(([127, 0, 0, 1], port)));
        let engine = start(Outbound::Shadowsocks(ShadowsocksConfig::new(
            server.clone(),
            method,
            password,
        )))
        .await;
        assert_echo(socks_connect(engine.local_addr(), echo).await).await;

        // Чужой пароль: сервер не должен ничего вернуть.
        let wrong = start(Outbound::Shadowsocks(ShadowsocksConfig::new(
            server, method, "wrong",
        )))
        .await;
        let mut stream = socks_connect(wrong.local_addr(), echo).await;
        stream.write_all(b"ping").await.unwrap();
        let mut buf = [0u8; 4];
        let read = tokio::time::timeout(Duration::from_secs(3), stream.read(&mut buf)).await;
        assert!(
            !matches!(read, Ok(Ok(4))),
            "{}: wrong password must not echo",
            method.name()
        );
    }
}
