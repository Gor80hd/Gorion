//! Подписки в формате Xray JSON (Remnawave, Marzban, 3x-ui): массив полных
//! конфигураций Xray или одна конфигурация. Каждый исходящий прокси
//! переводится в сервер конфигурации Gorion того же вида, что дают ссылки
//! (`links.rs`). Во Flutter-эталоне этого формата нет (Δ в parity.md).
//!
//! Что не переводится, пропускается целиком, а не «примерно»: mKCP, QUIC
//! Xray движок не умеет.

use serde_json::{Map, Value, json};

use crate::error::{CoreError, CoreResult};

type Outbound = Map<String, Value>;

/// Протоколы Xray, которые умеем переводить.
const PROXY_PROTOCOLS: [&str; 6] = [
    "vless",
    "vmess",
    "trojan",
    "shadowsocks",
    "hysteria",
    "hysteria2",
];

/// Похоже ли значение на подписку Xray: массив конфигураций или конфигурация,
/// где у исходящих есть `protocol`, а не `type`.
pub fn looks_like_xray(value: &Value) -> bool {
    match value {
        Value::Array(items) => items.iter().any(is_xray_config),
        Value::Object(_) => is_xray_config(value),
        _ => false,
    }
}

fn is_xray_config(value: &Value) -> bool {
    value
        .get("outbounds")
        .and_then(Value::as_array)
        .is_some_and(|outbounds| {
            outbounds.iter().any(|o| o.get("protocol").is_some())
                && outbounds.iter().all(|o| o.get("type").is_none())
        })
}

/// Серверы Gorion из подписки Xray. `Err` — серверы были, но ни один
/// не переводится (первая причина).
pub fn convert(value: &Value) -> CoreResult<Vec<Outbound>> {
    let configs: Vec<&Value> = match value {
        Value::Array(items) => items.iter().filter(|v| is_xray_config(v)).collect(),
        other => vec![other],
    };
    let mut outbounds = Vec::new();
    let mut first_error = None;
    for config in configs {
        let remarks = config
            .get("remarks")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|r| !r.is_empty());
        let proxies: Vec<&Map<String, Value>> = config
            .get("outbounds")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(Value::as_object)
            .filter(|o| {
                o.get("protocol")
                    .and_then(Value::as_str)
                    .is_some_and(|p| PROXY_PROTOCOLS.contains(&p.to_ascii_lowercase().as_str()))
            })
            .collect();
        let single = proxies.len() == 1;
        for proxy in proxies {
            // Имя сервера — `remarks` конфигурации; если прокси в ней
            // несколько, к нему добавляется тег.
            let own_tag = proxy
                .get("tag")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty());
            let tag = match (remarks, own_tag) {
                (Some(r), _) if single => r.to_owned(),
                (Some(r), Some(t)) => format!("{r} · {t}"),
                (Some(r), None) => r.to_owned(),
                (None, Some(t)) => t.to_owned(),
                (None, None) => String::new(),
            };
            match convert_outbound(proxy) {
                Ok(Some(mut outbound)) => {
                    if !tag.is_empty() {
                        outbound.insert("tag".into(), json!(tag));
                    }
                    outbounds.push(outbound);
                }
                Ok(None) => {}
                Err(error) => {
                    tracing::debug!(%error, "xray outbound skipped");
                    first_error.get_or_insert(error);
                }
            }
        }
    }
    match (outbounds.is_empty(), first_error) {
        (true, Some(error)) => Err(error),
        _ => Ok(outbounds),
    }
}

fn convert_outbound(proxy: &Map<String, Value>) -> CoreResult<Option<Outbound>> {
    let protocol = str_at(proxy, "protocol")
        .unwrap_or_default()
        .to_ascii_lowercase();
    let settings = proxy.get("settings").cloned().unwrap_or(json!({}));
    let stream = proxy.get("streamSettings").cloned().unwrap_or(json!({}));
    let mut out = Map::new();
    match protocol.as_str() {
        "vless" | "vmess" => {
            let Some((server, port, user)) = vnext_user(&settings) else {
                return Ok(None);
            };
            let Some(id) = str_at(&user, "id") else {
                return Ok(None);
            };
            out.insert("type".into(), json!(protocol));
            insert_server(&mut out, &server, port);
            out.insert("uuid".into(), json!(id));
            if protocol == "vless" {
                if let Some(flow) = str_at(&user, "flow") {
                    out.insert("flow".into(), json!(flow));
                }
                out.insert("packet_encoding".into(), json!("xudp"));
            } else {
                out.insert(
                    "security".into(),
                    json!(str_at(&user, "security").unwrap_or_else(|| "auto".into())),
                );
                out.insert(
                    "alter_id".into(),
                    json!(user.get("alterId").and_then(Value::as_i64).unwrap_or(0)),
                );
            }
        }
        "trojan" | "shadowsocks" => {
            let Some(entry) = first_server(&settings) else {
                return Ok(None);
            };
            let (Some(server), Some(port), Some(password)) = (
                str_at(&entry, "address"),
                port_at(&entry),
                str_at(&entry, "password"),
            ) else {
                return Ok(None);
            };
            out.insert("type".into(), json!(protocol));
            insert_server(&mut out, &server, port);
            out.insert("password".into(), json!(password));
            if protocol == "shadowsocks" {
                let Some(method) = str_at(&entry, "method") else {
                    return Ok(None);
                };
                out.insert("method".into(), json!(method));
            }
        }
        "hysteria" | "hysteria2" => {
            let entry = first_server(&settings).unwrap_or_else(|| as_map(&settings));
            let hysteria = stream
                .get("hysteriaSettings")
                .map(as_map)
                .unwrap_or_default();
            let version = entry
                .get("version")
                .or_else(|| hysteria.get("version"))
                .and_then(Value::as_i64)
                .unwrap_or(2);
            if version != 2 {
                return Err(CoreError::UnsupportedTransport("hysteria v1".into()));
            }
            let (Some(server), Some(port)) = (str_at(&entry, "address"), port_at(&entry)) else {
                return Ok(None);
            };
            let Some(password) = str_at(&hysteria, "auth")
                .or_else(|| str_at(&entry, "password"))
                .or_else(|| str_at(&entry, "auth"))
            else {
                return Ok(None);
            };
            out.insert("type".into(), json!("hysteria2"));
            insert_server(&mut out, &server, port);
            out.insert("password".into(), json!(password));
            // TLS у Hysteria2 обязателен; uTLS к QUIC не относится.
            let mut tls = tls_settings(&stream)?.unwrap_or_else(|| {
                let mut tls = Map::new();
                tls.insert("enabled".into(), json!(true));
                tls
            });
            tls.shift_remove("utls");
            if tls.contains_key("reality") {
                return Err(CoreError::InvalidShareLink(
                    "REALITY не поддерживается для hysteria2".into(),
                ));
            }
            out.insert("tls".into(), Value::Object(tls));
            return Ok(Some(out));
        }
        _ => return Ok(None),
    }
    let tls = tls_settings(&stream)?;
    if protocol == "trojan" {
        // Trojan без TLS не бывает — как у ссылок `trojan://`.
        let tls = tls.unwrap_or_else(|| {
            let mut tls = Map::new();
            tls.insert("enabled".into(), json!(true));
            tls
        });
        out.insert("tls".into(), Value::Object(tls));
    } else if let Some(tls) = tls {
        out.insert("tls".into(), Value::Object(tls));
    }
    if protocol != "shadowsocks"
        && let Some(transport) = transport(&stream)?
    {
        out.insert("transport".into(), Value::Object(transport));
    }
    Ok(Some(out))
}

/// `settings.vnext[0].users[0]` или новый плоский вид Xray
/// (`settings.address`, `settings.port`, `settings.id`).
fn vnext_user(settings: &Value) -> Option<(String, u16, Map<String, Value>)> {
    if let Some(node) = settings
        .get("vnext")
        .and_then(Value::as_array)
        .and_then(|v| v.first())
        .map(as_map)
    {
        let user = node
            .get("users")
            .and_then(Value::as_array)
            .and_then(|u| u.first())
            .map(as_map)?;
        return Some((str_at(&node, "address")?, port_at(&node)?, user));
    }
    let flat = as_map(settings);
    Some((str_at(&flat, "address")?, port_at(&flat)?, flat))
}

/// `settings.servers[0]` или плоский вид.
fn first_server(settings: &Value) -> Option<Map<String, Value>> {
    if let Some(server) = settings
        .get("servers")
        .and_then(Value::as_array)
        .and_then(|s| s.first())
    {
        return Some(as_map(server));
    }
    let flat = as_map(settings);
    flat.contains_key("address").then_some(flat)
}

pub(super) fn tls_settings(stream: &Value) -> CoreResult<Option<Map<String, Value>>> {
    let security = stream
        .get("security")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    let (key, reality) = match security.as_str() {
        "tls" => ("tlsSettings", false),
        "reality" => ("realitySettings", true),
        "" | "none" => return Ok(None),
        other => return Err(CoreError::UnsupportedTransport(format!("security {other}"))),
    };
    let settings = stream.get(key).map(as_map).unwrap_or_default();
    let mut tls = Map::new();
    tls.insert("enabled".into(), json!(true));
    if let Some(name) = str_at(&settings, "serverName") {
        tls.insert("server_name".into(), json!(name));
    }
    if settings.get("allowInsecure") == Some(&json!(true)) {
        tls.insert("insecure".into(), json!(true));
    }
    if let Some(alpn) = settings.get("alpn").and_then(Value::as_array) {
        let alpn: Vec<&str> = alpn.iter().filter_map(Value::as_str).collect();
        if !alpn.is_empty() {
            tls.insert("alpn".into(), json!(alpn));
        }
    }
    let fingerprint = str_at(&settings, "fingerprint");
    if reality {
        // Новые версии Xray называют открытый ключ `password`.
        let Some(public_key) =
            str_at(&settings, "publicKey").or_else(|| str_at(&settings, "password"))
        else {
            return Err(CoreError::InvalidShareLink(
                "REALITY без открытого ключа".into(),
            ));
        };
        let mut reality = Map::new();
        reality.insert("enabled".into(), json!(true));
        reality.insert("public_key".into(), json!(public_key));
        if let Some(short_id) = str_at(&settings, "shortId") {
            reality.insert("short_id".into(), json!(short_id));
        }
        tls.insert("reality".into(), Value::Object(reality));
        // Отпечаток по умолчанию — Chrome, как в Xray.
        tls.insert(
            "utls".into(),
            json!({"enabled": true, "fingerprint": fingerprint.unwrap_or_else(|| "chrome".into())}),
        );
    } else if let Some(fingerprint) = fingerprint {
        tls.insert(
            "utls".into(),
            json!({"enabled": true, "fingerprint": fingerprint}),
        );
    }
    Ok(Some(tls))
}

fn transport(stream: &Value) -> CoreResult<Option<Map<String, Value>>> {
    let network = stream
        .get("network")
        .and_then(Value::as_str)
        .unwrap_or("tcp")
        .to_ascii_lowercase();
    let section = |key: &str| stream.get(key).map(as_map).unwrap_or_default();
    let mut transport = Map::new();
    match network.as_str() {
        "tcp" | "raw" => {
            let settings = if stream.get("rawSettings").is_some() {
                section("rawSettings")
            } else {
                section("tcpSettings")
            };
            let header = settings.get("header").map(as_map).unwrap_or_default();
            if str_at(&header, "type").as_deref() != Some("http") {
                return Ok(None);
            }
            let request = header.get("request").map(as_map).unwrap_or_default();
            transport.insert("type".into(), json!("http"));
            let hosts = request
                .get("headers")
                .map(as_map)
                .and_then(|h| h.get("Host").cloned())
                .map(string_list)
                .unwrap_or_default();
            if !hosts.is_empty() {
                transport.insert("host".into(), json!(hosts));
            }
            if let Some(path) = request
                .get("path")
                .cloned()
                .map(string_list)
                .and_then(|p| p.into_iter().next())
            {
                transport.insert("path".into(), json!(path));
            }
        }
        "ws" | "websocket" => {
            let settings = section("wsSettings");
            transport.insert("type".into(), json!("ws"));
            if let Some(path) = str_at(&settings, "path") {
                transport.insert("path".into(), json!(path));
            }
            let host = str_at(&settings, "host").or_else(|| {
                settings
                    .get("headers")
                    .map(as_map)
                    .and_then(|h| str_at(&h, "Host"))
            });
            if let Some(host) = host {
                transport.insert("headers".into(), json!({"Host": host}));
            }
        }
        "grpc" | "gun" => {
            let settings = section("grpcSettings");
            transport.insert("type".into(), json!("grpc"));
            if let Some(service) = str_at(&settings, "serviceName") {
                transport.insert(
                    "service_name".into(),
                    json!(service.trim_start_matches('/')),
                );
            }
        }
        "httpupgrade" => {
            let settings = section("httpupgradeSettings");
            transport.insert("type".into(), json!("httpupgrade"));
            if let Some(host) = str_at(&settings, "host") {
                transport.insert("host".into(), json!(host));
            }
            if let Some(path) = str_at(&settings, "path") {
                transport.insert("path".into(), json!(path));
            }
        }
        "h2" | "http" => {
            let settings = section("httpSettings");
            transport.insert("type".into(), json!("http"));
            let hosts = settings
                .get("host")
                .cloned()
                .map(string_list)
                .unwrap_or_default();
            if !hosts.is_empty() {
                transport.insert("host".into(), json!(hosts));
            }
            if let Some(path) = str_at(&settings, "path") {
                transport.insert("path".into(), json!(path));
            }
        }
        "xhttp" | "splithttp" => {
            let settings = if stream.get("xhttpSettings").is_some() {
                section("xhttpSettings")
            } else {
                section("splithttpSettings")
            };
            return super::xhttp::from_xray(&settings).map(Some);
        }
        other => return Err(CoreError::UnsupportedTransport(other.to_owned())),
    }
    Ok(Some(transport))
}

fn insert_server(out: &mut Outbound, server: &str, port: u16) {
    out.insert("server".into(), json!(server));
    out.insert("server_port".into(), json!(port));
}

fn as_map(value: &Value) -> Map<String, Value> {
    value.as_object().cloned().unwrap_or_default()
}

fn str_at(map: &Map<String, Value>, key: &str) -> Option<String> {
    map.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

fn port_at(map: &Map<String, Value>) -> Option<u16> {
    match map.get("port")? {
        Value::Number(n) => n.as_u64().and_then(|p| u16::try_from(p).ok()),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
    .filter(|p| *p > 0)
}

fn string_list(value: Value) -> Vec<String> {
    match value {
        Value::String(s) => s
            .split(',')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect(),
        Value::Array(items) => items
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect(),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    const UUID: &str = "11111111-2222-3333-4444-555555555555";

    fn config(remarks: &str, outbound: Value) -> Value {
        json!({
            "remarks": remarks,
            "inbounds": [{"protocol": "socks", "port": 10808}],
            "outbounds": [outbound, {"protocol": "freedom", "tag": "direct"},
                          {"protocol": "blackhole", "tag": "block"}],
        })
    }

    #[test]
    fn converts_reality_vision_and_names_by_remarks() {
        let sub = json!([config(
            "🇳🇱 Amsterdam",
            json!({
                "tag": "proxy", "protocol": "vless",
                "settings": {"vnext": [{"address": "nl.example.com", "port": 443,
                    "users": [{"id": UUID, "flow": "xtls-rprx-vision", "encryption": "none"}]}]},
                "streamSettings": {"network": "tcp", "security": "reality",
                    "realitySettings": {"serverName": "www.example.org", "publicKey": "PBK",
                        "shortId": "ab12"}}
            })
        )]);
        assert!(looks_like_xray(&sub));
        let out = convert(&sub).unwrap();
        assert_eq!(out.len(), 1);
        assert_eq!(
            Value::Object(out[0].clone()),
            json!({
                "type": "vless", "server": "nl.example.com", "server_port": 443,
                "uuid": UUID, "flow": "xtls-rprx-vision", "packet_encoding": "xudp",
                "tls": {"enabled": true, "server_name": "www.example.org",
                    "reality": {"enabled": true, "public_key": "PBK", "short_id": "ab12"},
                    "utls": {"enabled": true, "fingerprint": "chrome"}},
                "tag": "🇳🇱 Amsterdam"
            })
        );
    }

    #[test]
    fn converts_transports_and_xhttp() {
        let sub = json!([
            config(
                "WS",
                json!({"protocol": "vless",
                "settings": {"vnext": [{"address": "a.example.com", "port": 443, "users": [{"id": UUID}]}]},
                "streamSettings": {"network": "ws", "security": "tls",
                    "tlsSettings": {"serverName": "a.example.com", "fingerprint": "firefox", "alpn": ["http/1.1"]},
                    "wsSettings": {"path": "/ws", "headers": {"Host": "cdn.example.com"}}}})
            ),
            config(
                "gRPC",
                json!({"protocol": "trojan",
                "settings": {"servers": [{"address": "b.example.com", "port": 443, "password": "pw"}]},
                "streamSettings": {"network": "grpc", "security": "tls",
                    "grpcSettings": {"serviceName": "/svc"}}})
            ),
            config(
                "XHTTP",
                json!({"protocol": "vless",
                "settings": {"vnext": [{"address": "c.example.com", "port": 443, "users": [{"id": UUID}]}]},
                "streamSettings": {"network": "xhttp", "security": "tls",
                    "xhttpSettings": {"path": "/xh", "host": "cdn.example.com", "mode": "auto",
                        "extra": {"xmux": {"maxConcurrency": "16-32"}}}}})
            ),
            config(
                "XHTTP split",
                json!({"protocol": "vless",
                "settings": {"vnext": [{"address": "d.example.com", "port": 443, "users": [{"id": UUID}]}]},
                "streamSettings": {"network": "xhttp", "security": "tls",
                    "xhttpSettings": {"path": "/xh",
                        "extra": {"downloadSettings": {"address": "dl.example.com"}}}}})
            ),
        ]);
        let out = convert(&sub).unwrap();
        assert_eq!(
            out.len(),
            3,
            "XHTTP с отдельным сервером скачивания пропущен"
        );
        assert_eq!(
            out[2]["transport"],
            json!({"type": "xhttp", "path": "/xh", "host": "cdn.example.com", "mode": "auto",
                   "xmux": {"max_concurrency": "16-32"}})
        );
        assert_eq!(
            out[0]["transport"],
            json!({"type": "ws", "path": "/ws", "headers": {"Host": "cdn.example.com"}})
        );
        assert_eq!(out[0]["tls"]["utls"]["fingerprint"], "firefox");
        assert_eq!(out[1]["type"], "trojan");
        assert_eq!(
            out[1]["transport"],
            json!({"type": "grpc", "service_name": "svc"})
        );
    }

    #[test]
    fn converts_hysteria2_and_shadowsocks() {
        let sub = json!([
            config(
                "HY2",
                json!({"protocol": "hysteria",
                "settings": {"version": 2, "address": "hy.example.com", "port": 8443},
                "streamSettings": {"network": "hysteria", "security": "tls",
                    "tlsSettings": {"serverName": "hy.example.com", "fingerprint": "chrome"},
                    "hysteriaSettings": {"version": 2, "auth": "secret"}}})
            ),
            config(
                "SS",
                json!({"protocol": "shadowsocks",
                "settings": {"servers": [{"address": "203.0.113.5", "port": 8388,
                    "method": "2022-blake3-aes-128-gcm", "password": "key"}]}})
            ),
        ]);
        let out = convert(&sub).unwrap();
        assert_eq!(
            Value::Object(out[0].clone()),
            json!({"type": "hysteria2", "server": "hy.example.com", "server_port": 8443,
                "password": "secret", "tls": {"enabled": true, "server_name": "hy.example.com"},
                "tag": "HY2"})
        );
        assert_eq!(out[1]["method"], "2022-blake3-aes-128-gcm");
    }

    #[test]
    fn only_unsupported_servers_is_an_error() {
        let sub = json!([config(
            "XHTTP",
            json!({"protocol": "vless",
            "settings": {"vnext": [{"address": "c.example.com", "port": 443, "users": [{"id": UUID}]}]},
            "streamSettings": {"network": "xhttp",
                "xhttpSettings": {"extra": {"uplinkHTTPMethod": "GET"}}}})
        )]);
        assert!(convert(&sub).is_err());
        // Конфигурация Gorion — не Xray.
        assert!(!looks_like_xray(
            &json!({"outbounds": [{"type": "vless", "tag": "x"}]})
        ));
    }
}
