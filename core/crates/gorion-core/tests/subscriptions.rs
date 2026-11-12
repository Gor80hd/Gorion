//! Подписки сверх эталона Flutter (Δ в parity.md): Xray JSON и списки, где
//! часть серверов не переводится. Итоговая конфигурация проверяется
//! настоящим `sing-box check`, если бинарник есть.

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
         vless://{UUID}@x.example.com:443?security=tls&type=xhttp&path=%2Fx#XHTTP\n\
         hysteria2://secret@hy.example.com:443?sni=hy.example.com#HY2\n"
    );
    let parsed = parse(&body);
    let tags: Vec<&str> = parsed.servers.iter().map(|s| s.tag.as_str()).collect();
    assert_eq!(tags, ["NL", "HY2"]);
    let config: Value = serde_json::from_str(&parsed.normalized_config_json).unwrap();
    // REALITY без `fp` получает отпечаток Chrome, иначе sing-box не стартует.
    assert_eq!(
        config["outbounds"][0]["tls"]["utls"],
        json!({"enabled": true, "fingerprint": "chrome"})
    );
    assert_singbox_accepts(&parsed.normalized_config_json);
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
             "streamSettings": {"network": "xhttp", "security": "tls"}}]}
    ]);
    let parsed = parse(&sub.to_string());
    let names: Vec<&str> = parsed.servers.iter().map(|s| s.tag.as_str()).collect();
    assert_eq!(names, ["🇩🇪 Frankfurt", "🇫🇮 Helsinki WS"]);
    assert_eq!(parsed.servers[0].kind, "vless");
    assert_singbox_accepts(&parsed.normalized_config_json);

    // То же самое в base64, как отдают многие панели.
    use base64::Engine as _;
    let encoded = base64::engine::general_purpose::STANDARD.encode(sub.to_string());
    assert_eq!(parse(&encoded).servers.len(), 2);
}
