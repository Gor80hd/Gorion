//! Серверы, которые можно выбрать, из конфигурации Gorion.
//! Эталон: `lib/features/auto_select/utils/auto_select_server_config.dart`.

use serde_json::{Map, Value, json};

use crate::json_util::{as_object, value_to_trimmed_string};

pub const SELECTABLE_OUTBOUND_TYPES: &[&str] = &[
    "anytls",
    "http",
    "hysteria",
    "hysteria2",
    "mieru",
    "naive",
    "shadowtls",
    "shadowsocks",
    "shadowsocksr",
    "socks",
    "ssh",
    "trojan",
    "tuic",
    "vless",
    "vmess",
    "warp",
    "wireguard",
    "awg",
    "xvless",
    "xvmess",
    "xtrojan",
    "xfreedom",
    "xshadowsocks",
    "xsocks",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigCandidate {
    pub tag: String,
    pub kind: String,
    pub host: Option<String>,
    pub port: Option<i64>,
    pub config_fingerprint: String,
}

pub fn extract_candidates(config: &Value) -> Vec<ConfigCandidate> {
    let Some(outbounds) = config.get("outbounds").and_then(Value::as_array) else {
        return Vec::new();
    };
    outbounds
        .iter()
        .filter_map(as_object)
        .filter_map(|map| {
            let tag = value_to_trimmed_string(map.get("tag"));
            let kind = value_to_trimmed_string(map.get("type")).to_lowercase();
            if tag.is_empty() || kind.is_empty() || tag.contains("§hide§") {
                return None;
            }
            if !SELECTABLE_OUTBOUND_TYPES.contains(&kind.as_str()) {
                return None;
            }
            Some(ConfigCandidate {
                host: candidate_host(map),
                port: candidate_port(map),
                config_fingerprint: fingerprint(map),
                tag,
                kind,
            })
        })
        .collect()
}

pub fn extract_candidates_from_json(config_json: &str) -> Vec<ConfigCandidate> {
    serde_json::from_str::<Value>(config_json)
        .ok()
        .filter(Value::is_object)
        .map(|config| extract_candidates(&config))
        .unwrap_or_default()
}

/// Outbound с данным тегом из конфигурации.
pub fn find_outbound<'a>(config: &'a Value, tag: &str) -> Option<&'a Map<String, Value>> {
    config
        .get("outbounds")?
        .as_array()?
        .iter()
        .filter_map(as_object)
        .find(|map| map.get("tag").and_then(Value::as_str) == Some(tag))
}

/// Минимальная конфигурация для проверки одного сервера: локальный mixed
/// и сам сервер — быстро стартует и быстро падает.
pub fn build_minimal_probe_config(outbound: &Map<String, Value>, mixed_port: u16) -> Value {
    json!({
        "log": {"level": "warn"},
        "inbounds": [{
            "type": "mixed",
            "listen": "127.0.0.1",
            "listen_port": mixed_port,
            "tag": format!("probe{mixed_port}"),
        }],
        "outbounds": [Value::Object(outbound.clone()), {"type": "direct", "tag": "direct"}],
        "route": {"final": outbound.get("tag").cloned().unwrap_or(Value::Null)},
    })
}

fn candidate_host(map: &Map<String, Value>) -> Option<String> {
    // Как в эталоне: `address` берётся, только если `server` отсутствует.
    let raw = match map.get("server") {
        Some(Value::Null) | None => map.get("address"),
        some => some,
    };
    let host = value_to_trimmed_string(raw);
    (!host.is_empty()).then_some(host)
}

fn candidate_port(map: &Map<String, Value>) -> Option<i64> {
    let raw = match map.get("server_port") {
        Some(Value::Null) | None => map.get("port"),
        some => some,
    }?;
    let text = match raw {
        Value::String(s) => s.clone(),
        Value::Null => return None,
        other => other.to_string(),
    };
    text.parse::<i64>().ok().filter(|port| *port > 0)
}

/// FNV-1a 64 по каноническому JSON без тега: одинаковые серверы под
/// разными именами получают один отпечаток (избранное переживает
/// переименование в подписке).
pub fn fingerprint(map: &Map<String, Value>) -> String {
    let mut sanitized = map.clone();
    sanitized.shift_remove("tag");
    let canonical = canonical_json(&Value::Object(sanitized));
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in canonical.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    dart_hex(hash)
}

/// Как `int.toRadixString(16).padLeft(16, '0')` в Dart: 64-битное целое
/// там знаковое, поэтому хеши со старшим битом печатаются с минусом.
/// Формат сохранён ради совместимости с уже записанными отпечатками.
fn dart_hex(hash: u64) -> String {
    let signed = hash as i64;
    let text = if signed < 0 {
        format!("-{:x}", signed.unsigned_abs())
    } else {
        format!("{signed:x}")
    };
    format!("{text:0>16}")
}

fn canonical_json(value: &Value) -> String {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let body: Vec<String> = keys
                .into_iter()
                .map(|key| {
                    let encoded_key = Value::String(key.clone()).to_string();
                    format!("{encoded_key}:{}", canonical_json(&map[key]))
                })
                .collect();
            format!("{{{}}}", body.join(","))
        }
        Value::Array(items) => {
            let body: Vec<String> = items.iter().map(canonical_json).collect();
            format!("[{}]", body.join(","))
        }
        other => other.to_string(),
    }
}
