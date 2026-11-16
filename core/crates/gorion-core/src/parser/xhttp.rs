//! Транспорт XHTTP из Xray в настройках движка Gorion.
//!
//! Формат в духе остальных транспортов конфигурации Gorion:
//! `{"type": "xhttp", "path", "host", "mode", "headers", "x_padding_bytes",
//! "no_grpc_header", "sc_max_each_post_bytes", "sc_min_posts_interval_ms",
//! "x_padding_obfs_mode", "x_padding_key", "x_padding_header",
//! "x_padding_placement", "x_padding_method", "uplink_http_method",
//! "session_placement", "session_key", "seq_placement", "seq_key",
//! "uplink_data_placement", "uplink_data_key", "uplink_chunk_size",
//! "xmux": {…}, "download_settings": {…}}` — поля Xray в snake_case,
//! диапазоны как в Xray (`"16-32"` или число).
//!
//! `download_settings` — отдельный сервер скачивания в виде исходящего:
//! `{"server", "server_port", "tls", "transport": {"type": "xhttp", …}}`.
//!
//! Настройки Xray приходят из `extra` ссылки (JSON) или из `xhttpSettings`
//! конфигурации. Как в Xray, `extra` заменяет всё, кроме `host`, `path` и
//! `mode`. Сочетания, которые Xray не принимает, — ошибка: такой сервер
//! пропускается, остальные остаются.

use serde_json::{Map, Value, json};

use crate::error::{CoreError, CoreResult};

/// Поля Xray, которые нужны только серверу.
const IGNORED: [&str; 4] = [
    "noSSEHeader",
    "scMaxBufferedPosts",
    "scStreamUpServerSecs",
    "serverMaxHeaderBytes",
];

/// Строковые поля Xray: имя у движка и допустимые значения (пусто — любое).
const STRINGS: [(&str, &str, &[&str]); 11] = [
    ("uplinkHTTPMethod", "uplink_http_method", &[]),
    (
        "sessionPlacement",
        "session_placement",
        &["path", "query", "header", "cookie"],
    ),
    ("sessionKey", "session_key", &[]),
    (
        "seqPlacement",
        "seq_placement",
        &["path", "query", "header", "cookie"],
    ),
    ("seqKey", "seq_key", &[]),
    (
        "uplinkDataPlacement",
        "uplink_data_placement",
        &["auto", "body", "header", "cookie"],
    ),
    ("uplinkDataKey", "uplink_data_key", &[]),
    ("xPaddingKey", "x_padding_key", &[]),
    ("xPaddingHeader", "x_padding_header", &[]),
    (
        "xPaddingPlacement",
        "x_padding_placement",
        &["queryInHeader", "header", "cookie", "query"],
    ),
    (
        "xPaddingMethod",
        "x_padding_method",
        &["repeat-x", "tokenish"],
    ),
];

fn unsupported(what: &str) -> CoreError {
    CoreError::UnsupportedTransport(format!("xhttp {what}"))
}

fn text(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
}

/// Диапазон Xray как есть: число или строка `"от-до"`.
fn range(value: &Value, what: &str) -> CoreResult<Value> {
    match value {
        Value::Number(_) => Ok(value.clone()),
        Value::String(s) if !s.trim().is_empty() => Ok(json!(s.trim())),
        _ => Err(unsupported(what)),
    }
}

/// Транспорт движка из `host`, `path`, `mode` и остальных настроек Xray.
pub(crate) fn transport(
    host: Option<String>,
    path: Option<String>,
    mode: Option<String>,
    settings: &Map<String, Value>,
) -> CoreResult<Map<String, Value>> {
    let mut out = Map::new();
    out.insert("type".into(), json!("xhttp"));
    if let Some(path) = path {
        out.insert("path".into(), json!(path));
    }
    if let Some(host) = host {
        out.insert("host".into(), json!(host));
    }
    if let Some(mode) = &mode {
        if !matches!(
            mode.as_str(),
            "auto" | "packet-up" | "stream-up" | "stream-one"
        ) {
            return Err(unsupported("mode"));
        }
        out.insert("mode".into(), json!(mode));
    }
    let mut xmux = Map::new();
    for (key, value) in settings {
        if let Some((_, name, allowed)) = STRINGS.iter().find(|(xray, ..)| *xray == key) {
            match value {
                Value::Null => {}
                Value::String(s) if s.trim().is_empty() => {}
                Value::String(s) if allowed.is_empty() || allowed.contains(&s.trim()) => {
                    out.insert((*name).into(), json!(s.trim()));
                }
                _ => return Err(unsupported(key)),
            }
            continue;
        }
        match key.as_str() {
            "host" | "path" | "mode" | "extra" => {}
            "headers" => {
                let Some(headers) = value.as_object() else {
                    return Err(unsupported("headers"));
                };
                if headers.keys().any(|k| k.eq_ignore_ascii_case("host")) {
                    return Err(unsupported("headers host"));
                }
                if headers.values().any(|v| !v.is_string()) {
                    return Err(unsupported("headers"));
                }
                if !headers.is_empty() {
                    out.insert("headers".into(), value.clone());
                }
            }
            "xPaddingBytes" => {
                out.insert("x_padding_bytes".into(), range(value, key)?);
            }
            "scMaxEachPostBytes" => {
                out.insert("sc_max_each_post_bytes".into(), range(value, key)?);
            }
            "scMinPostsIntervalMs" => {
                out.insert("sc_min_posts_interval_ms".into(), range(value, key)?);
            }
            "uplinkChunkSize" => {
                if !value.is_null() {
                    out.insert("uplink_chunk_size".into(), range(value, key)?);
                }
            }
            "noGRPCHeader" | "xPaddingObfsMode" => match value {
                Value::Bool(true) => {
                    let name = if key == "noGRPCHeader" {
                        "no_grpc_header"
                    } else {
                        "x_padding_obfs_mode"
                    };
                    out.insert(name.into(), json!(true));
                }
                Value::Bool(false) | Value::Null => {}
                _ => return Err(unsupported(key)),
            },
            "xmux" => {
                let Some(settings) = value.as_object() else {
                    return Err(unsupported("xmux"));
                };
                for (key, value) in settings {
                    let name = match key.as_str() {
                        "maxConcurrency" => "max_concurrency",
                        "maxConnections" => "max_connections",
                        "cMaxReuseTimes" => "c_max_reuse_times",
                        "hMaxRequestTimes" => "h_max_request_times",
                        "hMaxReusableSecs" => "h_max_reusable_secs",
                        "hKeepAlivePeriod" => "h_keep_alive_period",
                        _ => return Err(unsupported(&format!("xmux {key}"))),
                    };
                    if !value.is_null() {
                        xmux.insert(name.into(), range(value, key)?);
                    }
                }
            }
            "downloadSettings" => match value {
                Value::Null => {}
                Value::Object(download) => {
                    // Как в Xray: со stream-one отдельного скачивания нет.
                    if mode.as_deref() == Some("stream-one") {
                        return Err(unsupported("downloadSettings with stream-one"));
                    }
                    out.insert("download_settings".into(), self::download(download)?);
                }
                _ => return Err(unsupported(key)),
            },
            key if IGNORED.contains(&key) => {}
            other => return Err(unsupported(other)),
        }
    }
    check_combinations(&out, mode.as_deref())?;
    if !xmux.is_empty() {
        out.insert("xmux".into(), Value::Object(xmux));
    }
    Ok(out)
}

/// Проверки Xray (`SplitHTTPConfig.Build`), которые зависят от режима: `GET`
/// и данные в заголовках или cookie — только при явном packet-up.
fn check_combinations(out: &Map<String, Value>, mode: Option<&str>) -> CoreResult<()> {
    let packet_up = mode == Some("packet-up");
    let method = out.get("uplink_http_method").and_then(Value::as_str);
    if method.is_some_and(|m| http_method(m).is_none()) {
        return Err(unsupported("uplinkHTTPMethod"));
    }
    if method.is_some_and(|m| m.eq_ignore_ascii_case("GET")) && !packet_up {
        return Err(unsupported("uplinkHTTPMethod GET without packet-up"));
    }
    let data = out.get("uplink_data_placement").and_then(Value::as_str);
    if data.is_some_and(|d| d != "auto" && d != "body") && !packet_up {
        return Err(unsupported("uplinkDataPlacement without packet-up"));
    }
    Ok(())
}

/// Имя метода HTTP: токен из букв, цифр и `!#$%&'*+-.^_`|~`.
fn http_method(method: &str) -> Option<&str> {
    let token = |c: char| c.is_ascii_alphanumeric() || "!#$%&'*+-.^_`|~".contains(c);
    (!method.is_empty() && method.chars().all(token)).then_some(method)
}

/// Сервер скачивания: `downloadSettings` Xray — это `streamSettings` с
/// адресом и портом, транспорт в нём только XHTTP.
fn download(settings: &Map<String, Value>) -> CoreResult<Value> {
    let bad = || unsupported("downloadSettings");
    let server = text(settings.get("address")).ok_or_else(bad)?;
    let port = match settings.get("port") {
        Some(Value::Number(n)) => n.as_u64().and_then(|p| u16::try_from(p).ok()),
        Some(Value::String(s)) => s.trim().parse().ok(),
        _ => None,
    }
    .filter(|p| *p > 0)
    .ok_or_else(bad)?;
    let network = settings
        .get("network")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();
    if network != "xhttp" && network != "splithttp" {
        return Err(unsupported("downloadSettings network"));
    }
    let xhttp = settings
        .get("xhttpSettings")
        .or_else(|| settings.get("splithttpSettings"))
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    let transport = from_xray(&xhttp)?;
    // Вложенного скачивания у Xray не бывает.
    if transport.contains_key("download_settings") {
        return Err(unsupported("nested downloadSettings"));
    }
    let mut out = Map::new();
    out.insert("server".into(), json!(server));
    out.insert("server_port".into(), json!(port));
    if let Some(tls) = super::xray::tls_settings(&Value::Object(settings.clone()))? {
        out.insert("tls".into(), Value::Object(tls));
    }
    out.insert("transport".into(), Value::Object(transport));
    Ok(Value::Object(out))
}

/// Настройки XHTTP из `xhttpSettings` Xray: `extra` поверх, как в Xray.
pub(crate) fn from_xray(settings: &Map<String, Value>) -> CoreResult<Map<String, Value>> {
    let extra = match settings.get("extra") {
        None | Some(Value::Null) => None,
        Some(Value::Object(extra)) => Some(extra.clone()),
        // В ссылках и некоторых панелях `extra` — строка с JSON.
        Some(Value::String(raw)) if raw.trim().is_empty() => None,
        Some(Value::String(raw)) => Some(
            serde_json::from_str::<Value>(raw)
                .ok()
                .and_then(|v| v.as_object().cloned())
                .ok_or_else(|| unsupported("extra"))?,
        ),
        Some(_) => return Err(unsupported("extra")),
    };
    transport(
        text(settings.get("host")),
        text(settings.get("path")),
        text(settings.get("mode")),
        extra.as_ref().unwrap_or(settings),
    )
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn map(value: Value) -> Map<String, Value> {
        value.as_object().unwrap().clone()
    }

    #[test]
    fn converts_extra_and_xmux() {
        let out = from_xray(&map(json!({
            "host": "cdn.example.com", "path": "/xh", "mode": "packet-up",
            "headers": {"X-Ignored": "1"},
            "extra": {
                "headers": {"User-Agent": "UA"}, "xPaddingBytes": "100-1000",
                "noGRPCHeader": false, "scMaxEachPostBytes": 1000000,
                "scMinPostsIntervalMs": "10-50", "noSSEHeader": true,
                "uplinkHTTPMethod": "POST", "sessionPlacement": "path",
                "xmux": {"maxConcurrency": "16-32", "hMaxRequestTimes": "600-900",
                         "hKeepAlivePeriod": 0}
            }
        })))
        .unwrap();
        assert_eq!(
            Value::Object(out),
            json!({
                "type": "xhttp", "path": "/xh", "host": "cdn.example.com", "mode": "packet-up",
                "headers": {"User-Agent": "UA"}, "x_padding_bytes": "100-1000",
                "sc_max_each_post_bytes": 1000000, "sc_min_posts_interval_ms": "10-50",
                "uplink_http_method": "POST", "session_placement": "path",
                "xmux": {"max_concurrency": "16-32", "h_max_request_times": "600-900",
                         "h_keep_alive_period": 0}
            })
        );
        // `extra` строкой, как в ссылках.
        let out = from_xray(&map(json!({
            "path": "/x", "extra": "{\"noGRPCHeader\": true}"
        })))
        .unwrap();
        assert_eq!(out["no_grpc_header"], json!(true));
        assert_eq!(out.get("mode"), None);
    }

    #[test]
    fn converts_placements_obfuscation_and_download() {
        let out = from_xray(&map(json!({
            "path": "/xh", "mode": "packet-up",
            "uplinkHTTPMethod": "GET", "sessionPlacement": "cookie", "sessionKey": "sid",
            "seqPlacement": "header", "uplinkDataPlacement": "cookie",
            "uplinkChunkSize": "2048-3072", "xPaddingObfsMode": true,
            "xPaddingPlacement": "query", "xPaddingKey": "pad", "xPaddingMethod": "tokenish",
            "downloadSettings": {
                "address": "dl.example.com", "port": "8443", "network": "xhttp",
                "security": "tls", "tlsSettings": {"serverName": "dl.example.com", "alpn": ["h3"]},
                "xhttpSettings": {"path": "/down", "extra": {"xPaddingBytes": "10-20"}}
            }
        })))
        .unwrap();
        assert_eq!(
            Value::Object(out),
            json!({
                "type": "xhttp", "path": "/xh", "mode": "packet-up",
                "uplink_http_method": "GET", "session_placement": "cookie", "session_key": "sid",
                "seq_placement": "header", "uplink_data_placement": "cookie",
                "uplink_chunk_size": "2048-3072", "x_padding_obfs_mode": true,
                "x_padding_placement": "query", "x_padding_key": "pad",
                "x_padding_method": "tokenish",
                "download_settings": {
                    "server": "dl.example.com", "server_port": 8443,
                    "tls": {"enabled": true, "server_name": "dl.example.com", "alpn": ["h3"]},
                    "transport": {"type": "xhttp", "path": "/down", "x_padding_bytes": "10-20"}
                }
            })
        );
    }

    #[test]
    fn refuses_what_xray_refuses() {
        let download = json!({"address": "d", "port": 443, "network": "xhttp"});
        for settings in [
            json!({"mode": "fast"}),
            json!({"downloadSettings": {"address": "dl.example.com"}}),
            json!({"downloadSettings": {"address": "d", "port": 443, "network": "ws"}}),
            json!({"mode": "stream-one", "downloadSettings": download}),
            json!({"downloadSettings": {"address": "d", "port": 443, "network": "xhttp",
                   "xhttpSettings": {"downloadSettings": download}}}),
            json!({"xPaddingObfsMode": "yes"}),
            json!({"xPaddingMethod": "random"}),
            json!({"uplinkHTTPMethod": "GE T"}),
            json!({"uplinkHTTPMethod": "GET"}),
            json!({"mode": "stream-up", "uplinkHTTPMethod": "GET"}),
            json!({"sessionPlacement": "body"}),
            json!({"uplinkDataPlacement": "cookie"}),
            json!({"headers": {"Host": "x"}}),
            json!({"xmux": {"unknown": 1}}),
            json!({"somethingNew": 1}),
            json!({"extra": "not json"}),
        ] {
            assert!(from_xray(&map(settings.clone())).is_err(), "{settings}");
        }
    }
}
