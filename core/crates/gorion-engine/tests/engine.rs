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

use std::sync::Arc;

use gorion_engine::{
    EngineConfig, EngineError, Flow, GrpcConfig, Method, Outbound, RealityConfig, Security,
    ShadowsocksConfig, Ss2022Config, Ss2022Method, TargetAddr, TlsConfig, Transport, TrojanConfig,
    UpgradeConfig, VlessConfig, WsConfig,
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
    (run_singbox(binary, &path, &config, port).await, port)
}

/// Пишет конфигурацию, запускает `sing-box run` и ждёт открытия порта.
async fn run_singbox(
    binary: &PathBuf,
    path: &std::path::Path,
    config: &serde_json::Value,
    port: u16,
) -> SingBox {
    std::fs::write(path, serde_json::to_vec(config).unwrap()).unwrap();
    let child = tokio::process::Command::new(binary)
        .args(["run", "-c"])
        .arg(path)
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    for _ in 0..100 {
        if TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return SingBox(child);
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

/// Вывод `sing-box generate …`: строки «Имя: значение».
async fn generate(binary: &PathBuf, args: &[&str]) -> String {
    let output = tokio::process::Command::new(binary)
        .arg("generate")
        .args(args)
        .output()
        .await
        .unwrap();
    assert!(output.status.success());
    String::from_utf8(output.stdout).unwrap()
}

fn field<'a>(text: &'a str, name: &str) -> &'a str {
    text.lines()
        .find_map(|line| line.strip_prefix(name)?.strip_prefix(": "))
        .unwrap()
}

fn pem_blocks(text: &str, label: &str) -> Vec<u8> {
    use base64::Engine as _;
    let begin = format!("-----BEGIN {label}-----");
    let end = format!("-----END {label}-----");
    let start = text.find(&begin).unwrap() + begin.len();
    let stop = start + text[start..].find(&end).unwrap();
    let body: String = text[start..stop].split_whitespace().collect();
    base64::engine::general_purpose::STANDARD
        .decode(body)
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

struct VlessServer {
    _singbox: SingBox,
    plain: TargetAddr,
    reality: TargetAddr,
    vision: TargetAddr,
    public_key: [u8; 32],
}

const USER: &str = "b831381d-6324-4d53-ad4f-8cda48b30811";
const SHORT_ID: &str = "0123abcd";
const DEST_NAME: &str = "dest.test";

/// sing-box с тремя входами VLESS (без защиты, REALITY, REALITY + Vision)
/// и обычным TLS-сайтом, за которым прячется REALITY.
async fn start_singbox_vless(binary: &PathBuf, dir: &std::path::Path) -> VlessServer {
    let keys = generate(binary, &["reality-keypair"]).await;
    let pair = generate(binary, &["tls-keypair", DEST_NAME]).await;
    let cert_path = dir.join("dest.crt");
    let key_path = dir.join("dest.key");
    let cert_start = pair.find("-----BEGIN CERTIFICATE-----").unwrap();
    std::fs::write(&key_path, &pair[..cert_start]).unwrap();
    std::fs::write(&cert_path, &pair[cert_start..]).unwrap();

    let [dest, plain, reality, vision] = [
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
    ];
    let reality_tls = |port: u16| {
        serde_json::json!({
            "enabled": true,
            "server_name": DEST_NAME,
            "reality": {
                "enabled": true,
                "handshake": { "server": "127.0.0.1", "server_port": dest },
                "private_key": field(&keys, "PrivateKey"),
                "short_id": [SHORT_ID]
            },
            "_port": port
        })
    };
    let strip = |mut v: serde_json::Value| {
        v.as_object_mut().unwrap().remove("_port");
        v
    };
    let config = serde_json::json!({
        "log": { "level": "error" },
        "inbounds": [
            {
                "type": "trojan", "tag": "dest", "listen": "127.0.0.1", "listen_port": dest,
                "users": [{ "password": "unused" }],
                "tls": {
                    "enabled": true, "server_name": DEST_NAME,
                    "certificate_path": cert_path, "key_path": key_path
                }
            },
            {
                "type": "vless", "tag": "plain", "listen": "127.0.0.1", "listen_port": plain,
                "users": [{ "uuid": USER }]
            },
            {
                "type": "vless", "tag": "reality", "listen": "127.0.0.1", "listen_port": reality,
                "users": [{ "uuid": USER }],
                "tls": strip(reality_tls(reality))
            },
            {
                "type": "vless", "tag": "vision", "listen": "127.0.0.1", "listen_port": vision,
                "users": [{ "uuid": USER, "flow": "xtls-rprx-vision" }],
                "tls": strip(reality_tls(vision))
            }
        ],
        "outbounds": [{ "type": "direct", "tag": "direct" }]
    });
    let singbox = run_singbox(binary, &dir.join("vless.json"), &config, vision).await;
    let local = |port: u16| TargetAddr::Ip(SocketAddr::from(([127, 0, 0, 1], port)));
    VlessServer {
        _singbox: singbox,
        plain: local(plain),
        reality: local(reality),
        vision: local(vision),
        public_key: base64url(field(&keys, "PublicKey")),
    }
}

fn reality(public_key: [u8; 32], short_id: &str) -> Security {
    Security::Reality(RealityConfig::new(DEST_NAME, public_key, short_id).unwrap())
}

fn vless(server: &TargetAddr, user: &str, flow: Flow, security: Security) -> Outbound {
    Outbound::Vless(Box::new(VlessConfig::new(
        server.clone(),
        user,
        flow,
        security,
    )))
}

/// Эхо-сервер TLS 1.3 (rustls): внутренний TLS, на котором Vision должен
/// перейти на прямое копирование.
async fn tls_echo_server(binary: &PathBuf) -> SocketAddr {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
    let pair = generate(binary, &["tls-keypair", "inner.test"]).await;
    let cert = CertificateDer::from(pem_blocks(&pair, "CERTIFICATE"));
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(pem_blocks(&pair, "PRIVATE KEY")));
    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let config = rustls::ServerConfig::builder_with_provider(provider)
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move {
        loop {
            let (stream, _) = listener.accept().await.unwrap();
            let acceptor = acceptor.clone();
            tokio::spawn(async move {
                let Ok(mut tls) = acceptor.accept(stream).await else {
                    return;
                };
                let mut buf = vec![0u8; 32 * 1024];
                loop {
                    match tls.read(&mut buf).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            if tls.write_all(&buf[..n]).await.is_err() {
                                break;
                            }
                        }
                    }
                }
                let _ = tls.shutdown().await;
            });
        }
    });
    addr
}

/// Клиент TLS без проверки сертификата — для внутреннего тестового TLS.
#[derive(Debug)]
struct AcceptAnyCert(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCert {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &rustls::pki_types::CertificateDer<'_>,
        dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &self.0.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

/// Внутренний TLS через исходящее подключение движка: 1 МБ туда и обратно.
/// Возвращает, перешёл ли Vision на прямое копирование в обе стороны.
async fn inner_tls_echo(outbound: &Outbound, target: SocketAddr) -> bool {
    let connection = outbound
        .connect(&TargetAddr::Ip(target), &[])
        .await
        .unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let client = TcpStream::connect(listener.local_addr().unwrap())
        .await
        .unwrap();
    let (proxy_side, _) = listener.accept().await.unwrap();
    let relay = tokio::spawn(async move {
        connection
            .relay(proxy_side, &gorion_engine::Traffic::default())
            .await
    });

    let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
    let config = rustls::ClientConfig::builder_with_provider(Arc::clone(&provider))
        .with_protocol_versions(&[&rustls::version::TLS13])
        .unwrap()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCert(provider)))
        .with_no_client_auth();
    let connector = tokio_rustls::TlsConnector::from(Arc::new(config));
    let name = rustls::pki_types::ServerName::try_from("inner.test").unwrap();
    let tls = connector.connect(name, client).await.unwrap();
    let (mut read, mut write) = tokio::io::split(tls);
    let payload: Vec<u8> = (0..1_000_000u32).map(|i| (i % 251) as u8).collect();
    let expected = payload.clone();
    let writer = tokio::spawn(async move {
        write.write_all(&payload).await.unwrap();
        write
    });
    let mut received = vec![0u8; expected.len()];
    tokio::time::timeout(Duration::from_secs(20), read.read_exact(&mut received))
        .await
        .expect("inner TLS echo timed out")
        .unwrap();
    assert!(received == expected, "inner TLS payload corrupted");
    let write = writer.await.unwrap();
    drop(read.unsplit(write));
    let transferred = relay.await.unwrap().unwrap();
    transferred.direct
}

#[tokio::test]
async fn singbox_vless_interop() {
    let Some(binary) = singbox_path() else {
        eprintln!("GORION_SINGBOX не задан — проверка VLESS с sing-box пропущена");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let server = start_singbox_vless(&binary, dir.path()).await;
    let echo = echo_server().await;
    let key = server.public_key;

    // VLESS без защиты, REALITY, REALITY + Vision: обычный поток в обе стороны.
    for (name, outbound) in [
        (
            "plain",
            vless(&server.plain, USER, Flow::None, Security::None),
        ),
        (
            "reality",
            vless(&server.reality, USER, Flow::None, reality(key, SHORT_ID)),
        ),
        (
            "vision",
            vless(&server.vision, USER, Flow::Vision, reality(key, SHORT_ID)),
        ),
    ] {
        eprintln!("vless {name}");
        let engine = start(outbound).await;
        assert_echo(socks_connect(engine.local_addr(), echo).await).await;
    }

    // Внутри TLS 1.3: Vision обязан перейти на прямое копирование.
    let inner = tls_echo_server(&binary).await;
    let vision = vless(&server.vision, USER, Flow::Vision, reality(key, SHORT_ID));
    assert!(
        inner_tls_echo(&vision, inner).await,
        "vision did not switch to direct copy"
    );
    // Без Vision тот же внутренний TLS просто идёт через REALITY.
    let plain_reality = vless(&server.reality, USER, Flow::None, reality(key, SHORT_ID));
    assert!(!inner_tls_echo(&plain_reality, inner).await);

    // Чужой ключ или short id: сервер не подтверждает себя — ошибка, а не
    // подключение к настоящему сайту.
    let mut wrong_key = key;
    wrong_key[0] ^= 1;
    for security in [reality(wrong_key, SHORT_ID), reality(key, "ffff")] {
        let outbound = vless(&server.reality, USER, Flow::None, security);
        let error = outbound
            .connect(&TargetAddr::Ip(echo), b"ping")
            .await
            .err()
            .expect("unauthenticated REALITY must fail");
        assert!(matches!(error, EngineError::RealityRejected), "{error}");
    }

    // Чужой UUID: рукопожатие проходит, но эха нет.
    let stranger = start(vless(
        &server.reality,
        "00000000-0000-0000-0000-000000000000",
        Flow::None,
        reality(key, SHORT_ID),
    ))
    .await;
    let mut stream = socks_connect(stranger.local_addr(), echo).await;
    stream.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    let read = tokio::time::timeout(Duration::from_secs(3), stream.read(&mut buf)).await;
    assert!(!matches!(read, Ok(Ok(4))), "unknown user must not echo");
}

// --- Trojan, VLESS поверх TLS, Shadowsocks 2022 -----------------------------

const TLS_NAME: &str = "server.test";
const TROJAN_PASSWORD: &str = "gorion-trojan";

fn b64(bytes: &[u8]) -> String {
    use base64::Engine as _;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

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

#[tokio::test]
async fn singbox_trojan_tls_and_ss2022_interop() {
    let Some(binary) = singbox_path() else {
        eprintln!("GORION_SINGBOX не задан — проверка Trojan и SS 2022 с sing-box пропущена");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let pair = generate(&binary, &["tls-keypair", TLS_NAME]).await;
    let cert_start = pair.find("-----BEGIN CERTIFICATE-----").unwrap();
    let certificate = pair[cert_start..].to_owned();
    let (cert_path, key_path) = (dir.path().join("s.crt"), dir.path().join("s.key"));
    std::fs::write(&key_path, &pair[..cert_start]).unwrap();
    std::fs::write(&cert_path, &certificate).unwrap();
    let tls = serde_json::json!({
        "enabled": true, "server_name": TLS_NAME,
        "certificate_path": cert_path, "key_path": key_path
    });

    let key16 = b64(&[0x11; 16]);
    let key32 = b64(&[0x22; 32]);
    let server_key = b64(&[0x33; 32]);
    let user_key = b64(&[0x44; 32]);
    let [trojan, vless_tls, ss128, ss256, ss_chacha, ss_multi] = [
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
        free_port().await,
    ];
    let ss = |port: u16, method: &str, password: &str| {
        serde_json::json!({
            "type": "shadowsocks", "listen": "127.0.0.1", "listen_port": port,
            "method": method, "password": password
        })
    };
    let mut multi = ss(ss_multi, "2022-blake3-aes-256-gcm", &server_key);
    multi["users"] = serde_json::json!([{ "name": "u", "password": user_key }]);
    let config = serde_json::json!({
        "log": { "level": "error" },
        "inbounds": [
            {
                "type": "trojan", "listen": "127.0.0.1", "listen_port": trojan,
                "users": [{ "password": TROJAN_PASSWORD }], "tls": tls
            },
            {
                "type": "vless", "listen": "127.0.0.1", "listen_port": vless_tls,
                "users": [{ "uuid": USER, "flow": "xtls-rprx-vision" }], "tls": tls
            },
            ss(ss128, "2022-blake3-aes-128-gcm", &key16),
            ss(ss256, "2022-blake3-aes-256-gcm", &key32),
            ss(ss_chacha, "2022-blake3-chacha20-poly1305", &key32),
            multi
        ],
        "outbounds": [{ "type": "direct", "tag": "direct" }]
    });
    let _singbox = run_singbox(&binary, &dir.path().join("mixed.json"), &config, ss_multi).await;
    let local = |port: u16| TargetAddr::Ip(SocketAddr::from(([127, 0, 0, 1], port)));
    let echo = echo_server().await;
    let greeting = greeting_server().await;

    let pinned =
        |name: &str| Security::Tls(TlsConfig::new(name, false, Some(&certificate)).unwrap());
    let trojan_with = |password: &str, security: Security| {
        Outbound::Trojan(Box::new(TrojanConfig::new(
            local(trojan),
            password,
            security,
        )))
    };

    // Trojan: свой сертификат сервера и режим без проверки.
    for (name, security) in [
        ("pinned", pinned(TLS_NAME)),
        (
            "insecure",
            Security::Tls(TlsConfig::new(TLS_NAME, true, None).unwrap()),
        ),
    ] {
        eprintln!("trojan {name}");
        let engine = start(trojan_with(TROJAN_PASSWORD, security)).await;
        assert_echo(socks_connect(engine.local_addr(), echo).await).await;
        assert_server_speaks_first(&engine, greeting).await;
    }
    // Сертификат не от доверенного корня или на другое имя — отказ.
    for security in [
        Security::Tls(TlsConfig::new(TLS_NAME, false, None).unwrap()),
        pinned("other.test"),
    ] {
        let error = trojan_with(TROJAN_PASSWORD, security)
            .connect(&TargetAddr::Ip(echo), b"ping")
            .await
            .err()
            .expect("untrusted certificate must fail");
        assert!(
            matches!(error, EngineError::UntrustedCertificate(_)),
            "{error}"
        );
    }
    assert_no_echo(
        trojan_with("wrong", pinned(TLS_NAME)),
        echo,
        "trojan wrong password",
    )
    .await;

    // VLESS + Vision поверх обычного TLS: поток и прямое копирование.
    let vless_vision = vless(&local(vless_tls), USER, Flow::Vision, pinned(TLS_NAME));
    let engine = start(vless_vision.clone()).await;
    assert_echo(socks_connect(engine.local_addr(), echo).await).await;
    let inner = tls_echo_server(&binary).await;
    assert!(
        inner_tls_echo(&vless_vision, inner).await,
        "vision over TLS did not switch to direct copy"
    );

    // Shadowsocks 2022: три шифра и цепочка ключей (iPSK:uPSK).
    for (name, port, method, password) in [
        ("aes-128", ss128, Ss2022Method::Aes128, key16.clone()),
        ("aes-256", ss256, Ss2022Method::Aes256, key32.clone()),
        ("chacha20", ss_chacha, Ss2022Method::Chacha20, key32.clone()),
        (
            "multi-user",
            ss_multi,
            Ss2022Method::Aes256,
            format!("{server_key}:{user_key}"),
        ),
    ] {
        eprintln!("ss2022 {name}");
        let outbound = Outbound::Shadowsocks2022(Box::new(
            Ss2022Config::new(local(port), method, &password).unwrap(),
        ));
        let engine = start(outbound).await;
        assert_echo(socks_connect(engine.local_addr(), echo).await).await;
        assert_server_speaks_first(&engine, greeting).await;
    }
    for (what, port, password) in [
        ("ss2022 wrong key", ss128, b64(&[0x55; 16])),
        (
            "ss2022 unknown user",
            ss_multi,
            format!("{server_key}:{key32}"),
        ),
    ] {
        let method = if port == ss128 {
            Ss2022Method::Aes128
        } else {
            Ss2022Method::Aes256
        };
        let outbound = Outbound::Shadowsocks2022(Box::new(
            Ss2022Config::new(local(port), method, &password).unwrap(),
        ));
        assert_no_echo(outbound, echo, what).await;
    }
}

/// Свой клиент TLS на настоящих сайтах: цепочки до общих корней, RSA-PSS и
/// ECDSA, сжатые сертификаты. Нужна сеть, поэтому только с
/// `GORION_NET_TLS=1`. Отказы проверяет `singbox_trojan_tls_and_ss2022_interop`.
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

fn ws(path: &str, early: usize, header: &str) -> Transport {
    Transport::WebSocket(WsConfig {
        path: path.into(),
        headers: vec![("Host".into(), "ws.test".into())],
        max_early_data: early,
        early_data_header: header.into(),
    })
}

fn with_transport(mut outbound: Outbound, transport: Transport) -> Outbound {
    match &mut outbound {
        Outbound::Vless(config) => config.transport = transport,
        Outbound::Trojan(config) => config.transport = transport,
        _ => panic!("no transport for this protocol"),
    }
    outbound
}

#[tokio::test]
async fn singbox_transports_interop() {
    let Some(binary) = singbox_path() else {
        eprintln!("GORION_SINGBOX не задан — проверка транспортов с sing-box пропущена");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    let pair = generate(&binary, &["tls-keypair", TLS_NAME]).await;
    let cert_start = pair.find("-----BEGIN CERTIFICATE-----").unwrap();
    let certificate = pair[cert_start..].to_owned();
    let (cert_path, key_path) = (dir.path().join("s.crt"), dir.path().join("s.key"));
    std::fs::write(&key_path, &pair[..cert_start]).unwrap();
    std::fs::write(&cert_path, &certificate).unwrap();
    let tls = serde_json::json!({
        "enabled": true, "server_name": TLS_NAME,
        "certificate_path": cert_path, "key_path": key_path
    });
    let keys = generate(&binary, &["reality-keypair"]).await;

    let ports: Vec<u16> = {
        let mut out = Vec::new();
        for _ in 0..9 {
            out.push(free_port().await);
        }
        out
    };
    let [
        ws_plain,
        ws_tls,
        ws_path,
        upgrade,
        upgrade_tls,
        grpc_tls,
        grpc_plain,
        grpc_reality,
        dest,
    ] = ports[..]
    else {
        unreachable!()
    };
    let vless_in = |port: u16, transport: serde_json::Value| {
        serde_json::json!({
            "type": "vless", "listen": "127.0.0.1", "listen_port": port,
            "users": [{ "uuid": USER }], "transport": transport
        })
    };
    let trojan_in = |port: u16, transport: serde_json::Value| {
        serde_json::json!({
            "type": "trojan", "listen": "127.0.0.1", "listen_port": port,
            "users": [{ "password": TROJAN_PASSWORD }], "tls": tls, "transport": transport
        })
    };
    let mut reality_in = vless_in(
        grpc_reality,
        serde_json::json!({"type": "grpc", "service_name": "GunService"}),
    );
    reality_in["tls"] = serde_json::json!({
        "enabled": true, "server_name": DEST_NAME,
        "reality": {
            "enabled": true,
            "handshake": { "server": "127.0.0.1", "server_port": dest },
            "private_key": field(&keys, "PrivateKey"),
            "short_id": [SHORT_ID]
        }
    });
    let mut ws_tls_in = vless_in(
        ws_tls,
        serde_json::json!({"type": "ws", "path": "/ws", "max_early_data": 2048,
                           "early_data_header_name": "Sec-WebSocket-Protocol"}),
    );
    ws_tls_in["tls"] = tls.clone();
    let config = serde_json::json!({
        "log": { "level": "error" },
        "inbounds": [
            vless_in(ws_plain, serde_json::json!({"type": "ws", "path": "/ws"})),
            ws_tls_in,
            vless_in(ws_path, serde_json::json!({"type": "ws", "path": "/ws", "max_early_data": 2048})),
            vless_in(upgrade, serde_json::json!({"type": "httpupgrade", "host": "up.test", "path": "/up"})),
            trojan_in(upgrade_tls, serde_json::json!({"type": "httpupgrade", "path": "/up"})),
            trojan_in(grpc_tls, serde_json::json!({"type": "grpc", "service_name": "GunService"})),
            vless_in(grpc_plain, serde_json::json!({"type": "grpc", "service_name": "GunService"})),
            reality_in,
            {
                "type": "trojan", "listen": "127.0.0.1", "listen_port": dest,
                "users": [{ "password": "unused" }], "tls": tls
            }
        ],
        "outbounds": [{ "type": "direct", "tag": "direct" }]
    });
    let _singbox = run_singbox(&binary, &dir.path().join("transports.json"), &config, dest).await;
    let local = |port: u16| TargetAddr::Ip(SocketAddr::from(([127, 0, 0, 1], port)));
    let echo = echo_server().await;
    let greeting = greeting_server().await;
    let pinned = || Security::Tls(TlsConfig::new(TLS_NAME, false, Some(&certificate)).unwrap());
    let plain_vless = |port: u16| vless(&local(port), USER, Flow::None, Security::None);
    let trojan = |port: u16| {
        Outbound::Trojan(Box::new(TrojanConfig::new(
            local(port),
            TROJAN_PASSWORD,
            pinned(),
        )))
    };
    let gun = || Transport::Grpc(GrpcConfig::new("GunService"));

    let cases = [
        (
            "ws",
            with_transport(plain_vless(ws_plain), ws("/ws", 0, "")),
        ),
        (
            "ws+tls, early data in header",
            with_transport(
                vless(&local(ws_tls), USER, Flow::None, pinned()),
                ws("/ws", 2048, "Sec-WebSocket-Protocol"),
            ),
        ),
        (
            "ws, early data in path",
            with_transport(plain_vless(ws_path), ws("/ws", 2048, "")),
        ),
        (
            "httpupgrade",
            with_transport(
                plain_vless(upgrade),
                Transport::HttpUpgrade(UpgradeConfig {
                    path: "/up".into(),
                    host: "up.test".into(),
                    headers: Vec::new(),
                }),
            ),
        ),
        (
            "trojan+httpupgrade+tls",
            with_transport(
                trojan(upgrade_tls),
                Transport::HttpUpgrade(UpgradeConfig {
                    path: "up".into(),
                    host: String::new(),
                    headers: Vec::new(),
                }),
            ),
        ),
        ("trojan+grpc+tls", with_transport(trojan(grpc_tls), gun())),
        ("grpc h2c", with_transport(plain_vless(grpc_plain), gun())),
        (
            "grpc+reality",
            with_transport(
                vless(
                    &local(grpc_reality),
                    USER,
                    Flow::None,
                    reality(base64url(field(&keys, "PublicKey")), SHORT_ID),
                ),
                gun(),
            ),
        ),
    ];
    for (name, outbound) in cases {
        eprintln!("transport {name}");
        let engine = start(outbound).await;
        assert_echo(socks_connect(engine.local_addr(), echo).await).await;
        assert_server_speaks_first(&engine, greeting).await;
        // Несколько потоков сразу (у gRPC — в одном соединении HTTP/2).
        let address = engine.local_addr();
        let parallel: Vec<_> = (0..4)
            .map(|_| {
                tokio::spawn(async move { assert_echo(socks_connect(address, echo).await).await })
            })
            .collect();
        for task in parallel {
            task.await.unwrap();
        }
    }

    // Чужой путь: сервер не переходит на WebSocket — ошибка, а не эхо.
    let wrong = with_transport(plain_vless(ws_plain), ws("/other", 0, ""));
    let (mut reader, mut writer) = match wrong.connect(&TargetAddr::Ip(echo), &[]).await.unwrap() {
        gorion_engine::outbound::Connection::Vless(parts) => {
            let (reader, writer, _) = *parts;
            (reader, writer)
        }
        _ => unreachable!(),
    };
    use gorion_engine::relay::{ChunkRead, PayloadWrite};
    assert!(writer.write_payload(b"ping").await.is_err());
    assert!(reader.read_chunk().await.is_err());
}
