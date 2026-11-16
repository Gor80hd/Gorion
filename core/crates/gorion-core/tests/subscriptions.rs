//! Подписки сверх эталона Flutter (Δ в parity.md): Xray JSON и списки, где
//! часть серверов не переводится. Итоговую конфигурацию принимает свой
//! движок и — если в ней нет XHTTP, которого sing-box не знает, — настоящий
//! `sing-box check`, если бинарник есть.

#![allow(clippy::unwrap_used)]

use std::path::PathBuf;

use gorion_core::config_builder::{BuildRequest, build};
use gorion_core::parser::{Headers, parse_subscription};
use gorion_core::runtime::RuntimeMode;
use serde_json::{Value, json};
use url::Url;

const UUID: &str = "11111111-2222-3333-4444-555555555555";

fn parse(body: &str) -> gorion_core::model::ParsedSubscription {
    parse_subscription(
        body,
        &Url::parse("https://sub.example.com/sub").unwrap(),
        &Headers::new(),
    )
    .unwrap()
}

fn singbox() -> Option<PathBuf> {
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x64"
    };
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join(format!("../../../assets/singbox/macos/{arch}/sing-box"));
    path.is_file().then_some(path)
}

fn built(normalized: &str, mode: RuntimeMode) -> String {
    build(&BuildRequest {
        template_config: normalized,
        mode,
        mixed_port: 20808,
        controller_port: 29090,
        controller_secret: "s",
        url_test_url: "https://www.gstatic.com/generate_204",
        selected_server_tag: None,
        selectable_tags_override: None,
        split_tunnel: None,
    })
    .unwrap()
    .config_json
}

/// Конфигурацию для каждого режима принимает свой движок (TUN — только
/// там, где он у движка есть) и `sing-box check`, если XHTTP в ней нет.
fn assert_accepted(normalized: &str) {
    let mut modes = vec![RuntimeMode::Mixed];
    if cfg!(target_os = "macos") {
        modes.push(RuntimeMode::Tun);
    }
    for mode in modes {
        let config: Value = serde_json::from_str(&built(normalized, mode)).unwrap();
        if let Err(error) = gorion_engine::config::from_singbox(&config) {
            panic!("{mode:?}: engine refused: {error}");
        }
    }
    if !normalized.contains("\"xhttp\"") {
        assert_singbox_accepts(normalized);
    }
}

/// Собирает конфигурацию для каждого режима и даёт её `sing-box check`.
fn assert_singbox_accepts(normalized: &str) {
    let Some(binary) = singbox() else {
        eprintln!("sing-box не найден — check пропущен");
        return;
    };
    let dir = tempfile::tempdir().unwrap();
    for mode in [RuntimeMode::Mixed, RuntimeMode::Tun] {
        let built = build(&BuildRequest {
            template_config: normalized,
            mode,
            mixed_port: 20808,
            controller_port: 29090,
            controller_secret: "s",
            url_test_url: "https://www.gstatic.com/generate_204",
            selected_server_tag: None,
            selectable_tags_override: None,
            split_tunnel: None,
        })
        .unwrap();
        let path = dir.path().join("config.json");
        std::fs::write(&path, built.config_json).unwrap();
        let output = std::process::Command::new(&binary)
            .args(["check", "-c"])
            .arg(&path)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{mode:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn link_list_keeps_servers_around_unsupported_ones() {
    let body = format!(
        "vless://{UUID}@nl.example.com:443?security=reality&sni=www.example.org&pbk=jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0&sid=ab12&flow=xtls-rprx-vision#NL\n\
         vless://{UUID}@x.example.com:443?security=tls&type=xhttp&path=%2Fx&mode=packet-up#XHTTP\n\
         vless://{UUID}@y.example.com:443?security=tls&type=xhttp&path=%2Fy&extra=%7B%22downloadSettings%22%3A%7B%22address%22%3A%22d%22%7D%7D#BROKEN\n\
         vless://{UUID}@z.example.com:443?security=tls&type=xhttp&path=%2Fz&mode=stream-up&extra=%7B%22downloadSettings%22%3A%7B%22address%22%3A%22dl.example.com%22%2C%22port%22%3A443%2C%22network%22%3A%22xhttp%22%2C%22security%22%3A%22tls%22%2C%22tlsSettings%22%3A%7B%22serverName%22%3A%22dl.example.com%22%7D%2C%22xhttpSettings%22%3A%7B%22path%22%3A%22%2Fdl%22%7D%7D%7D#SPLIT\n\
         hysteria2://secret@hy.example.com:443?sni=hy.example.com&obfs=salamander&obfs-password=gorion-obfs#HY2\n"
    );
    let parsed = parse(&body);
    let tags: Vec<&str> = parsed.servers.iter().map(|s| s.tag.as_str()).collect();
    // Сервер скачивания без порта Xray не примет — пропущен только он.
    assert_eq!(tags, ["NL", "XHTTP", "SPLIT", "HY2"]);
    let config: Value = serde_json::from_str(&parsed.normalized_config_json).unwrap();
    // REALITY без `fp` получает отпечаток Chrome, иначе sing-box не стартует.
    assert_eq!(
        config["outbounds"][0]["tls"]["utls"],
        json!({"enabled": true, "fingerprint": "chrome"})
    );
    assert_eq!(
        config["outbounds"][1]["transport"],
        json!({"type": "xhttp", "path": "/x", "mode": "packet-up"})
    );
    assert_eq!(
        config["outbounds"][2]["transport"]["download_settings"],
        json!({"server": "dl.example.com", "server_port": 443,
               "tls": {"enabled": true, "server_name": "dl.example.com"},
               "transport": {"type": "xhttp", "path": "/dl"}})
    );
    assert_accepted(&parsed.normalized_config_json);
}

#[test]
fn xray_json_subscription_imports() {
    let sub = json!([
        {"remarks": "🇩🇪 Frankfurt", "outbounds": [
            {"tag": "proxy", "protocol": "vless",
             "settings": {"vnext": [{"address": "de.example.com", "port": 443,
                "users": [{"id": UUID, "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
             "streamSettings": {"network": "raw", "security": "reality",
                "realitySettings": {"serverName": "www.example.org",
                    "publicKey": "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0",
                    "shortId": "6ba85179e30d4fc2", "fingerprint": "chrome"}}},
            {"tag": "direct", "protocol": "freedom"}]},
        {"remarks": "🇫🇮 Helsinki WS", "outbounds": [
            {"tag": "proxy", "protocol": "vless",
             "settings": {"vnext": [{"address": "fi.example.com", "port": 443, "users": [{"id": UUID}]}]},
             "streamSettings": {"network": "ws", "security": "tls",
                "tlsSettings": {"serverName": "fi.example.com"},
                "wsSettings": {"path": "/ws", "host": "fi.example.com"}}}]},
        {"remarks": "🇳🇱 XHTTP", "outbounds": [
            {"tag": "proxy", "protocol": "vless",
             "settings": {"vnext": [{"address": "nl.example.com", "port": 443, "users": [{"id": UUID}]}]},
             "streamSettings": {"network": "xhttp", "security": "reality",
                "realitySettings": {"serverName": "www.example.org",
                    "publicKey": "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0", "shortId": "ab12"},
                "xhttpSettings": {"path": "/xh", "mode": "auto"}}}]},
        {"remarks": "🇺🇸 HY2", "outbounds": [
            {"tag": "proxy", "protocol": "hysteria",
             "settings": {"version": 2, "address": "us.example.com", "port": 8443},
             "streamSettings": {"network": "hysteria", "security": "tls",
                "tlsSettings": {"serverName": "us.example.com"},
                "hysteriaSettings": {"version": 2, "auth": "secret"}}}]}
    ]);
    let parsed = parse(&sub.to_string());
    let names: Vec<&str> = parsed.servers.iter().map(|s| s.tag.as_str()).collect();
    assert_eq!(
        names,
        ["🇩🇪 Frankfurt", "🇫🇮 Helsinki WS", "🇳🇱 XHTTP", "🇺🇸 HY2"]
    );
    assert_eq!(parsed.servers[0].kind, "vless");
    assert_accepted(&parsed.normalized_config_json);

    // То же самое в base64, как отдают многие панели.
    use base64::Engine as _;
    let encoded = base64::engine::general_purpose::STANDARD.encode(sub.to_string());
    assert_eq!(parse(&encoded).servers.len(), 4);
}
