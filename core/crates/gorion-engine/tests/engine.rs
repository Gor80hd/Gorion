//! Сквозные проверки движка на loopback: системные маршруты и прокси не
//! трогаются (правило 5).
//!
//! Совместимость XHTTP проверяется против настоящего сервера Xray, только
//! если задан `GORION_XRAY` — путь к бинарнику.

#![allow(clippy::unwrap_used)]

use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::Stdio;
use std::time::Duration;

use std::sync::Arc;

use gorion_engine::xhttp::{
    DataPlacement, DownloadSettings, Mode as XhttpMode, PaddingMethod, PaddingObfs,
    PaddingPlacement, Placement, Range as XhttpRange,
};
use gorion_engine::{
    EngineConfig, Flow, Outbound, RealityConfig, Security, TargetAddr, TlsConfig, Transport,
    TrojanConfig, VlessConfig, XhttpConfig,
};
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

// --- Внешние серверы для проверок совместимости -----------------------------

/// Процесс тестового сервера: гаснет вместе с проверкой.
struct Server(tokio::process::Child);

impl Drop for Server {
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

fn field<'a>(text: &'a str, name: &str) -> &'a str {
    text.lines()
        .find_map(|line| line.strip_prefix(name)?.strip_prefix(": "))
        .unwrap()
}

fn base64url(text: &str) -> [u8; 32] {
    use base64::Engine as _;
    base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(text)
        .unwrap()
        .try_into()
        .unwrap()
}

const USER: &str = "b831381d-6324-4d53-ad4f-8cda48b30811";
const SHORT_ID: &str = "0123abcd";
const DEST_NAME: &str = "dest.test";

fn vless(server: &TargetAddr, user: &str, flow: Flow, security: Security) -> Outbound {
    Outbound::Vless(Box::new(VlessConfig::new(
        server.clone(),
        user,
        flow,
        security,
    )))
}

// --- Trojan, VLESS поверх TLS, Shadowsocks 2022 -----------------------------

const TLS_NAME: &str = "server.test";
const TROJAN_PASSWORD: &str = "gorion-trojan";

/// Сервер, который говорит первым: шлёт приветствие и ждёт закрытия.
async fn greeting_server() -> SocketAddr {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else {
                return;
            };
            tokio::spawn(async move {
                let _ = stream.write_all(b"220 hello\r\n").await;
                let mut buf = [0u8; 64];
                let _ = stream.read(&mut buf).await;
            });
        }
    });
    addr
}

/// Клиент молчит, пока сервер назначения не заговорит (заголовок
/// протокола уходит по `flush_header`).
async fn assert_server_speaks_first(engine: &gorion_engine::EngineHandle, target: SocketAddr) {
    let mut stream = socks_connect(engine.local_addr(), target).await;
    let mut buf = [0u8; 11];
    tokio::time::timeout(Duration::from_secs(5), stream.read_exact(&mut buf))
        .await
        .expect("server-first greeting timed out")
        .unwrap();
    assert_eq!(&buf, b"220 hello\r\n");
}

/// Никакого эха: сервер не пустил клиента.
async fn assert_no_echo(outbound: Outbound, echo: SocketAddr, what: &str) {
    let engine = start(outbound).await;
    let mut stream = socks_connect(engine.local_addr(), echo).await;
    stream.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    let read = tokio::time::timeout(Duration::from_secs(3), stream.read(&mut buf)).await;
    assert!(!matches!(read, Ok(Ok(4))), "{what} must not echo");
}

/// Свой клиент TLS на настоящих сайтах: цепочки до общих корней, RSA-PSS и
/// ECDSA, сжатые сертификаты. Нужна сеть, поэтому только с
/// `GORION_NET_TLS=1`.
#[tokio::test]
async fn own_tls_client_on_real_sites() {
    if std::env::var_os("GORION_NET_TLS").is_none() {
        eprintln!("GORION_NET_TLS не задан — проверка на настоящих сайтах пропущена");
        return;
    }
    for host in [
        "www.cloudflare.com",
        "www.google.com",
        "www.microsoft.com",
        "www.wikipedia.org",
        "github.com",
    ] {
        let stream = TcpStream::connect((host, 443)).await.unwrap();
        let config = TlsConfig::new(host, false, None).unwrap();
        let (mut reader, mut writer) = gorion_engine::tls::connect(
            stream,
            &gorion_engine::tls::Auth::Certificate(&config),
            &["http/1.1".to_owned()],
        )
        .await
        .unwrap_or_else(|e| panic!("{host}: {e}"));
        writer
            .write_all(
                format!("HEAD / HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").as_bytes(),
            )
            .await
            .unwrap();
        let first = reader.read_record().await.unwrap().unwrap();
        assert!(first.starts_with(b"HTTP/1.1 "), "{host}");
        eprintln!("{host}: {}", String::from_utf8_lossy(&first[..12]));
    }
}

// --- Транспорты: WebSocket, HTTPUpgrade, gRPC --------------------------------

fn with_transport(mut outbound: Outbound, transport: Transport) -> Outbound {
    match &mut outbound {
        Outbound::Vless(config) => config.transport = transport,
        Outbound::Trojan(config) => config.transport = transport,
        _ => panic!("no transport for this protocol"),
    }
    outbound
}

/// DNS режима TUN: DNS-over-HTTPS к 1.1.1.1 через исходящий протокол (здесь
/// прямой), одно соединение на несколько запросов и новое после смены
/// сервера. Нужна сеть, поэтому только с `GORION_NET_TLS=1`.
#[tokio::test]
async fn doh_through_outbound_on_real_server() {
    use gorion_engine::Selector;
    use gorion_engine::tun::dns::{DohClient, DohServer};

    if std::env::var_os("GORION_NET_TLS").is_none() {
        eprintln!("GORION_NET_TLS не задан — проверка DoH пропущена");
        return;
    }
    let selector = Arc::new(Selector::new(Arc::new(Outbound::Direct)));
    let client = DohClient::new(
        DohServer {
            address: "1.1.1.1:443".parse().unwrap(),
            server_name: "cloudflare-dns.com".into(),
            path: "/dns-query".into(),
        },
        Arc::clone(&selector),
    );
    let query = |id: u8, name: &str| {
        let mut q = vec![0xAB, id, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0];
        for label in name.split('.') {
            q.push(label.len() as u8);
            q.extend_from_slice(label.as_bytes());
        }
        q.extend_from_slice(&[0, 0, 1, 0, 1]);
        q
    };
    for (id, name) in [(1, "example.com"), (2, "www.wikipedia.org")] {
        let answer = client.exchange(&query(id, name)).await.unwrap();
        assert_eq!(&answer[..2], &[0xAB, id], "ID клиента возвращён");
        assert_eq!(answer[2] & 0x80, 0x80, "это ответ");
        assert_eq!(answer[3] & 0x0F, 0, "{name}: RCODE");
        assert!(
            u16::from_be_bytes([answer[6], answer[7]]) >= 1,
            "{name}: есть ответы"
        );
    }
    // Сменили сервер — запрос идёт уже через новый.
    selector.set(Arc::new(Outbound::Direct));
    let answer = client.exchange(&query(3, "github.com")).await.unwrap();
    assert_eq!(&answer[..2], &[0xAB, 3]);
}

// --- Hysteria2 ----------------------------------------------------------------

async fn free_udp_port() -> u16 {
    tokio::net::UdpSocket::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// Три подключения через движок одновременно, каждое — полное эхо.
async fn echo_three(proxy: SocketAddr, target: SocketAddr) {
    let one = || async move { assert_echo(socks_connect(proxy, target).await).await };
    tokio::join!(one(), one(), one());
}

// --- XHTTP против Xray ----------------------------------------------------------

fn xray_path() -> Option<PathBuf> {
    std::env::var_os("GORION_XRAY")
        .map(PathBuf::from)
        .filter(|p| p.exists())
}

/// Самоподписанный сертификат Xray: (PEM сертификата, PEM ключа).
async fn xray_cert(binary: &PathBuf, domain: &str) -> (String, String) {
    let output = tokio::process::Command::new(binary)
        .args([
            "tls",
            "cert",
            &format!("--domain={domain}"),
            "--expire=240h",
        ])
        .output()
        .await
        .unwrap();
    assert!(output.status.success());
    let json: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    let lines = |key: &str| {
        json[key]
            .as_array()
            .unwrap()
            .iter()
            .map(|l| l.as_str().unwrap())
            .collect::<Vec<_>>()
            .join("\n")
    };
    (lines("certificate"), lines("key"))
}

async fn xray_keys(binary: &PathBuf) -> (String, [u8; 32]) {
    let output = tokio::process::Command::new(binary)
        .arg("x25519")
        .output()
        .await
        .unwrap();
    let text = String::from_utf8(output.stdout).unwrap();
    let private = field(&text, "PrivateKey").to_owned();
    (private, base64url(field(&text, "Password (PublicKey)")))
}

const XHTTP_HOST: &str = "cdn.test";

#[tokio::test]
async fn xray_xhttp_interop() {
    let Some(binary) = xray_path() else {
        eprintln!("GORION_XRAY не задан — проверка XHTTP с Xray пропущена");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let (certificate, key) = xray_cert(&binary, TLS_NAME).await;
    let (dest_cert, dest_key) = xray_cert(&binary, DEST_NAME).await;
    let (private_key, public_key) = xray_keys(&binary).await;
    let [dest, plain, tls, reality, trojan, custom, cookie] = [
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
    ];
    let quic = free_udp_port().await;
    let tls_alpn = |cert: &str, key: &str, alpn: serde_json::Value| {
        serde_json::json!({
            "alpn": alpn,
            "certificates": [{
                "certificate": cert.lines().collect::<Vec<_>>(),
                "key": key.lines().collect::<Vec<_>>()
            }]
        })
    };
    let tls_settings =
        |cert: &str, key: &str| tls_alpn(cert, key, serde_json::json!(["h2", "http/1.1"]));
    let xhttp = |host: &str| serde_json::json!({ "path": "/xh", "host": host, "mode": "auto" });
    let vless_in = |port: u16, stream: serde_json::Value| {
        serde_json::json!({
            "listen": "127.0.0.1", "port": port, "protocol": "vless",
            "settings": { "clients": [{ "id": USER }], "decryption": "none" },
            "streamSettings": stream
        })
    };
    let config = serde_json::json!({
        "log": { "loglevel": "warning" },
        "inbounds": [
            // Обычный TLS-сайт, за которым прячется REALITY.
            vless_in(dest, serde_json::json!({
                "network": "raw", "security": "tls",
                "tlsSettings": tls_settings(&dest_cert, &dest_key)
            })),
            vless_in(plain, serde_json::json!({
                "network": "xhttp", "xhttpSettings": xhttp("")
            })),
            vless_in(tls, serde_json::json!({
                "network": "xhttp", "xhttpSettings": xhttp(XHTTP_HOST),
                "security": "tls", "tlsSettings": tls_settings(&certificate, &key)
            })),
            vless_in(reality, serde_json::json!({
                "network": "xhttp", "xhttpSettings": xhttp(""),
                "security": "reality",
                "realitySettings": {
                    "target": format!("127.0.0.1:{dest}"), "serverNames": [DEST_NAME],
                    "privateKey": private_key, "shortIds": [SHORT_ID]
                }
            })),
            // HTTP/3: QUIC на UDP-порту.
            vless_in(quic, serde_json::json!({
                "network": "xhttp", "xhttpSettings": xhttp(XHTTP_HOST),
                "security": "tls",
                "tlsSettings": tls_alpn(&certificate, &key, serde_json::json!(["h3"]))
            })),
            // Свой метод, сессия в заголовке, номер в запросе, данные в
            // заголовках, паддинг tokenish в cookie — поверх HTTP/2.
            vless_in(custom, serde_json::json!({
                "network": "xhttp", "security": "tls",
                "tlsSettings": tls_settings(&certificate, &key),
                "xhttpSettings": {
                    "path": "/xh", "mode": "packet-up", "uplinkHTTPMethod": "PUT",
                    "sessionPlacement": "header", "seqPlacement": "query", "seqKey": "n",
                    "uplinkDataPlacement": "header", "scMaxEachPostBytes": 2048,
                    "xPaddingObfsMode": true, "xPaddingPlacement": "cookie",
                    "xPaddingMethod": "tokenish"
                }
            })),
            // GET с данными в cookie, сессия в cookie, номер в заголовке,
            // паддинг в запросе — поверх HTTP/1.1.
            vless_in(cookie, serde_json::json!({
                "network": "xhttp",
                "xhttpSettings": {
                    "path": "/xh", "mode": "packet-up", "uplinkHTTPMethod": "GET",
                    "sessionPlacement": "cookie", "seqPlacement": "header",
                    "uplinkDataPlacement": "cookie", "scMaxEachPostBytes": 2048,
                    "xPaddingObfsMode": true, "xPaddingPlacement": "query",
                    "xPaddingKey": "pad"
                }
            })),
            {
                "listen": "127.0.0.1", "port": trojan, "protocol": "trojan",
                "settings": { "clients": [{ "password": TROJAN_PASSWORD }] },
                "streamSettings": {
                    "network": "xhttp", "xhttpSettings": xhttp(XHTTP_HOST),
                    "security": "tls", "tlsSettings": tls_settings(&certificate, &key)
                }
            }
        ],
        "outbounds": [{ "protocol": "freedom" }]
    });
    let path = dir.path().join("xray.json");
    std::fs::write(&path, serde_json::to_vec(&config).unwrap()).unwrap();
    let child = tokio::process::Command::new(&binary)
        .args(["run", "-c"])
        .arg(&path)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let _xray = Server(child);
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", trojan)).await.is_ok() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }

    let local = |port: u16| TargetAddr::Ip(SocketAddr::from(([127, 0, 0, 1], port)));
    let echo = echo_server().await;
    let greeting = greeting_server().await;
    let pinned = || Security::Tls(TlsConfig::new(TLS_NAME, false, Some(&certificate)).unwrap());
    let xh = |host: &str, mode: XhttpMode| {
        // Запрос в пути уходит серверу как есть.
        Transport::Xhttp(Box::new(XhttpConfig::new("/xh?ed=2048", host, mode)))
    };
    let vless_xh = |port: u16, security: Security, transport: Transport| {
        with_transport(vless(&local(port), USER, Flow::None, security), transport)
    };
    let mut h1_over_tls = VlessConfig::new(local(tls), USER, Flow::None, pinned());
    h1_over_tls.alpn = vec!["http/1.1".into()];
    h1_over_tls.transport = xh(XHTTP_HOST, XhttpMode::Auto);
    let mut small_posts = XhttpConfig::new("/xh", "", XhttpMode::PacketUp);
    // Мелкие куски: отправка 300 КБ — десятки запросов с номерами.
    small_posts.sc_max_each_post_bytes = XhttpRange::new(8192, 16384);
    small_posts.sc_min_posts_interval_ms = XhttpRange::new(1, 5);

    let mut h3 = VlessConfig::new(local(quic), USER, Flow::None, pinned());
    h3.alpn = vec!["h3".into()];
    h3.transport = xh(XHTTP_HOST, XhttpMode::Auto);
    let mut h3_stream = VlessConfig::new(local(quic), USER, Flow::None, pinned());
    h3_stream.alpn = vec!["h3".into()];
    h3_stream.transport = xh(XHTTP_HOST, XhttpMode::StreamOne);

    let mut placed = XhttpConfig::new("/xh", "", XhttpMode::PacketUp);
    placed.uplink_method = "PUT".into();
    placed.session_placement = Placement::Header;
    placed.session_key = "X-Session".into();
    placed.seq_placement = Placement::Query;
    placed.seq_key = "n".into();
    placed.data_placement = DataPlacement::Header;
    placed.data_key = "X-Data".into();
    placed.sc_max_each_post_bytes = XhttpRange::new(2048, 2048);
    placed.padding_obfs = Some(PaddingObfs {
        placement: PaddingPlacement::Cookie,
        key: "x_padding".into(),
        header: "X-Padding".into(),
        method: PaddingMethod::Tokenish,
    });
    let mut cookies = XhttpConfig::new("/xh", "", XhttpMode::PacketUp);
    cookies.uplink_method = "GET".into();
    cookies.session_placement = Placement::Cookie;
    cookies.session_key = "x_session".into();
    cookies.seq_placement = Placement::Header;
    cookies.seq_key = "X-Seq".into();
    cookies.data_placement = DataPlacement::Cookie;
    cookies.data_key = "x_data".into();
    cookies.sc_max_each_post_bytes = XhttpRange::new(2048, 2048);
    cookies.padding_obfs = Some(PaddingObfs {
        placement: PaddingPlacement::Query,
        key: "pad".into(),
        header: "X-Padding".into(),
        method: PaddingMethod::RepeatX,
    });

    // Скачивание отдельно: отправка по HTTP/2, приём — по HTTP/1.1 к тому
    // же серверу (сессии у Xray — на входе); поверх REALITY auto
    // становится stream-up.
    let mut split = XhttpConfig::new("/xh", XHTTP_HOST, XhttpMode::Auto);
    split.download = Some(Arc::new(DownloadSettings {
        server: local(tls),
        security: pinned(),
        alpn: vec!["http/1.1".into()],
        xhttp: XhttpConfig::new("/xh", XHTTP_HOST, XhttpMode::Auto),
    }));
    let mut split_reality = XhttpConfig::new("/xh", "", XhttpMode::Auto);
    split_reality.download = Some(Arc::new(DownloadSettings {
        server: local(reality),
        security: reality_xray(public_key),
        alpn: Vec::new(),
        xhttp: XhttpConfig::new("/xh", "", XhttpMode::Auto),
    }));

    for (what, outbound) in [
        ("h3 packet-up", Outbound::Vless(Box::new(h3))),
        ("h3 stream-one", Outbound::Vless(Box::new(h3_stream))),
        (
            "h2 placements and tokenish",
            vless_xh(custom, pinned(), Transport::Xhttp(Box::new(placed))),
        ),
        (
            "http/1.1 cookies and GET",
            vless_xh(cookie, Security::None, Transport::Xhttp(Box::new(cookies))),
        ),
        (
            "http/1.1 stream-one",
            vless_xh(plain, Security::None, xh("", XhttpMode::StreamOne)),
        ),
        (
            "http/1.1 stream-up",
            vless_xh(plain, Security::None, xh("", XhttpMode::StreamUp)),
        ),
        (
            "download over http/1.1",
            vless_xh(tls, pinned(), Transport::Xhttp(Box::new(split))),
        ),
        (
            "reality download stream-up",
            vless_xh(
                reality,
                reality_xray(public_key),
                Transport::Xhttp(Box::new(split_reality)),
            ),
        ),
        (
            "http/1.1 packet-up",
            vless_xh(plain, Security::None, xh("", XhttpMode::Auto)),
        ),
        (
            "http/1.1 small posts",
            vless_xh(
                plain,
                Security::None,
                Transport::Xhttp(Box::new(small_posts)),
            ),
        ),
        (
            "tls http/1.1 packet-up",
            Outbound::Vless(Box::new(h1_over_tls)),
        ),
        (
            "tls h2 packet-up",
            vless_xh(tls, pinned(), xh(XHTTP_HOST, XhttpMode::Auto)),
        ),
        (
            "tls h2 stream-up",
            vless_xh(tls, pinned(), xh(XHTTP_HOST, XhttpMode::StreamUp)),
        ),
        (
            "tls h2 stream-one",
            vless_xh(tls, pinned(), xh(XHTTP_HOST, XhttpMode::StreamOne)),
        ),
        (
            "reality stream-one",
            vless_xh(reality, reality_xray(public_key), xh("", XhttpMode::Auto)),
        ),
        (
            "reality packet-up",
            vless_xh(
                reality,
                reality_xray(public_key),
                xh("", XhttpMode::PacketUp),
            ),
        ),
        (
            "trojan tls h2",
            with_transport(
                Outbound::Trojan(Box::new(TrojanConfig::new(
                    local(trojan),
                    TROJAN_PASSWORD,
                    pinned(),
                ))),
                xh(XHTTP_HOST, XhttpMode::Auto),
            ),
        ),
    ] {
        let engine = start(outbound).await;
        echo_three(engine.local_addr(), echo).await;
        assert_server_speaks_first(&engine, greeting).await;
        eprintln!("xhttp {what}: ok");
    }

    // Чужое имя (`host`) сервер не пускает: 404 вместо сессии.
    assert_no_echo(
        vless_xh(tls, pinned(), xh("other.test", XhttpMode::Auto)),
        echo,
        "wrong host",
    )
    .await;
}

fn reality_xray(public_key: [u8; 32]) -> Security {
    Security::Reality(RealityConfig::new(DEST_NAME, public_key, SHORT_ID).unwrap())
}
