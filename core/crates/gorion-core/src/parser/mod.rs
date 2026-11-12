//! Разбор подписок: JSON sing-box, JSON Xray, списки ссылок, base64.
//! Эталон: `lib/features/profiles/data/profile_parser.dart`.

mod base64_text;
pub mod links;
pub mod uri;
pub mod xray;

use std::collections::HashMap;

use regex::Regex;
use serde_json::{Map, Value, json};
use url::Url;

pub use base64_text::try_decode_base64;

use crate::candidates::extract_candidates;
use crate::display::normalize_server_display_text;
use crate::error::{CoreError, CoreResult};
use crate::model::{ParsedSubscription, ServerEntry, SubscriptionInfo};
use uri::decode_component;

/// Заголовки ответа подписки, ключи — в нижнем регистре.
pub type Headers = HashMap<String, String>;

/// Разбирает тело подписки, загруженной с `source`.
pub fn parse_subscription(
    raw_content: &str,
    source: &Url,
    headers: &Headers,
) -> CoreResult<ParsedSubscription> {
    let config =
        decode_subscription_config(raw_content)?.ok_or(CoreError::UnsupportedSubscriptionFormat)?;
    let config_value = Value::Object(config);
    let candidates = extract_candidates(&config_value);
    if candidates.is_empty() {
        return Err(CoreError::NoSelectableServers);
    }
    let servers: Vec<ServerEntry> = candidates
        .into_iter()
        .map(|c| ServerEntry {
            display_name: normalize_server_display_text(&c.tag, true),
            tag: c.tag,
            kind: c.kind,
            host: c.host,
            port: c.port,
            config_fingerprint: Some(c.config_fingerprint),
        })
        .collect();
    let fallback = servers
        .first()
        .map(|s| s.display_name.clone())
        .unwrap_or_default();
    Ok(ParsedSubscription {
        name: resolve_profile_name(headers, source, &fallback),
        normalized_config_json: config_value.to_string(),
        servers,
        subscription_info: parse_subscription_info(headers),
    })
}

/// Тело ответа как текст: UTF-8, а при ошибке — выбор между UTF-8 с
/// заменами и Latin-1 по признакам «кракозябр».
pub fn decode_response_body(bytes: &[u8]) -> String {
    if let Ok(text) = std::str::from_utf8(bytes) {
        return text.trim().to_owned();
    }
    let utf8_text = String::from_utf8_lossy(bytes).trim().to_owned();
    let latin1_text: String = bytes
        .iter()
        .map(|b| char::from(*b))
        .collect::<String>()
        .trim()
        .to_owned();
    if utf8_text.is_empty() {
        return latin1_text;
    }
    if latin1_text.is_empty() {
        return utf8_text;
    }
    let mojibake = latin1_text
        .chars()
        .filter(|c| matches!(*c as u32, 0xC2 | 0xC3 | 0xD0 | 0xD1 | 0xF0))
        .count();
    if mojibake > 0 {
        return utf8_text;
    }
    if utf8_text.contains('\u{FFFD}') {
        return latin1_text;
    }
    utf8_text
}

type Config = Map<String, Value>;

fn decode_subscription_config(raw: &str) -> CoreResult<Option<Config>> {
    let trimmed = raw.replacen('\u{FEFF}', "", 1);
    let trimmed = trimmed.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }
    if let Some(config) = decode_xray(trimmed)? {
        return Ok(Some(config));
    }
    if let Some(config) = decode_config(trimmed) {
        return Ok(Some(config));
    }
    let direct = parse_remote_outbounds(trimmed)?;
    if !direct.is_empty() {
        return Ok(Some(outbounds_config(direct)));
    }
    let Some(decoded) = try_decode_base64(trimmed) else {
        return Ok(None);
    };
    if let Some(config) = decode_xray(&decoded)? {
        return Ok(Some(config));
    }
    if let Some(config) = decode_config(&decoded) {
        return Ok(Some(config));
    }
    let decoded_outbounds = parse_remote_outbounds(&decoded)?;
    if !decoded_outbounds.is_empty() {
        return Ok(Some(outbounds_config(decoded_outbounds)));
    }
    Ok(None)
}

fn outbounds_config(outbounds: Vec<Config>) -> Config {
    let mut config = Map::new();
    config.insert(
        "outbounds".into(),
        Value::Array(outbounds.into_iter().map(Value::Object).collect()),
    );
    config
}

fn decode_config(content: &str) -> Option<Config> {
    if let Ok(Value::Object(map)) = serde_json::from_str::<Value>(content) {
        return Some(map);
    }
    let first = content.find('{')?;
    let last = content.rfind('}')?;
    if last <= first {
        return None;
    }
    match serde_json::from_str::<Value>(&content[first..=last]) {
        Ok(Value::Object(map)) => Some(map),
        _ => None,
    }
}

/// Подписка Xray JSON (массив конфигураций или одна конфигурация).
fn decode_xray(content: &str) -> CoreResult<Option<Config>> {
    let Ok(value) = serde_json::from_str::<Value>(content) else {
        return Ok(None);
    };
    if !xray::looks_like_xray(&value) {
        return Ok(None);
    }
    let outbounds = with_unique_tags(xray::convert(&value)?);
    Ok((!outbounds.is_empty()).then(|| outbounds_config(outbounds)))
}

/// Ссылки по строке. Δ к эталону: ссылка, которую нельзя перевести без
/// потерь (например, XHTTP), пропускается, а не роняет всю подписку;
/// ошибка возвращается, только если не перевелось ничего.
fn parse_remote_outbounds(content: &str) -> CoreResult<Vec<Config>> {
    let mut outbounds = Vec::new();
    let mut first_error = None;
    for raw_line in split_lines(content) {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with("//") {
            continue;
        }
        match links::parse_share_link(line) {
            Ok(Some(outbound)) => outbounds.push(outbound),
            Ok(None) => {}
            Err(error) => {
                tracing::debug!(%error, "share link skipped");
                first_error.get_or_insert(error);
            }
        }
    }
    if outbounds.is_empty()
        && let Some(error) = first_error
    {
        return Err(error);
    }
    Ok(with_unique_tags(outbounds))
}

/// Пустой тег заменяется на `host:port [type]`, повторы получают номер.
fn with_unique_tags(outbounds: Vec<Config>) -> Vec<Config> {
    let mut tag_counts: HashMap<String, usize> = HashMap::new();
    let mut result = Vec::with_capacity(outbounds.len());
    for mut outbound in outbounds {
        let original = outbound
            .get("tag")
            .and_then(Value::as_str)
            .map(str::trim)
            .unwrap_or_default()
            .to_owned();
        let base = if original.is_empty() {
            fallback_tag(&outbound)
        } else {
            original
        };
        outbound.insert("tag".into(), json!(unique_tag(base, &mut tag_counts)));
        result.push(outbound);
    }
    result
}

/// Как `LineSplitter`: `\n`, `\r\n` и одиночный `\r`.
fn split_lines(content: &str) -> impl Iterator<Item = &str> {
    content
        .split('\n')
        .flat_map(|line| line.strip_suffix('\r').unwrap_or(line).split('\r'))
}

fn fallback_tag(outbound: &Config) -> String {
    let text = |key: &str| {
        outbound
            .get(key)
            .map(|v| v.as_str().map_or_else(|| v.to_string(), str::to_owned))
    };
    let host = text("server")
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|| "server".into());
    let port = text("server_port")
        .map(|s| s.trim().to_owned())
        .unwrap_or_default();
    let kind = text("type")
        .map(|s| s.trim().to_owned())
        .unwrap_or_else(|| "proxy".into());
    let location = if port.is_empty() {
        host
    } else {
        format!("{host}:{port}")
    };
    format!("{location} [{kind}]")
}

fn unique_tag(tag: String, counts: &mut HashMap<String, usize>) -> String {
    match counts.get_mut(&tag) {
        None => {
            counts.insert(tag.clone(), 1);
            tag
        }
        Some(count) => {
            *count += 1;
            format!("{tag} ({count})")
        }
    }
}

fn resolve_profile_name(headers: &Headers, source: &Url, fallback: &str) -> String {
    let title = decode_header_text(headers.get("profile-title").map(String::as_str));
    if !title.is_empty() {
        return title;
    }
    let disposition =
        content_disposition_name(headers.get("content-disposition").map(String::as_str));
    if !disposition.is_empty() {
        return disposition;
    }
    if let Some(fragment) = source.fragment() {
        let decoded = decode_component(fragment).unwrap_or_else(|| fragment.to_owned());
        let decoded = decoded.trim();
        if !decoded.is_empty() {
            return decoded.to_owned();
        }
    }
    let segment = source
        .path_segments()
        .and_then(|mut segments| segments.next_back())
        .map(|s| decode_component(s).unwrap_or_else(|| s.to_owned()))
        .unwrap_or_default();
    let segment = segment.trim();
    if !segment.is_empty() {
        return match segment.rfind('.') {
            Some(dot) if dot > 0 => segment[..dot].to_owned(),
            _ => segment.to_owned(),
        };
    }
    fallback.to_owned()
}

fn decode_header_text(raw: Option<&str>) -> String {
    let Some(raw) = raw.filter(|r| !r.trim().is_empty()) else {
        return String::new();
    };
    let uri_decoded = decode_full(raw);
    let uri_decoded = uri_decoded.trim();
    let payload = uri_decoded
        .strip_prefix("base64:")
        .map(str::trim)
        .unwrap_or(uri_decoded);
    match try_decode_base64(payload) {
        Some(decoded) if !decoded.is_empty() => decoded,
        _ => payload.to_owned(),
    }
}

/// `Uri.decodeFull`: декодирует %-последовательности, `+` оставляет.
fn decode_full(value: &str) -> String {
    decode_component(value).unwrap_or_else(|| value.to_owned())
}

#[allow(clippy::unwrap_used)] // Константные шаблоны.
fn content_disposition_name(raw: Option<&str>) -> String {
    let Some(raw) = raw.filter(|r| !r.is_empty()) else {
        return String::new();
    };
    let utf8 = Regex::new(r"(?i)filename\*=UTF-8''([^;]+)").unwrap();
    if let Some(caps) = utf8.captures(raw) {
        let value = &caps[1];
        return decode_component(value)
            .unwrap_or_else(|| value.to_owned())
            .trim()
            .to_owned();
    }
    let plain = Regex::new(r#"(?i)filename="?([^";]+)"?"#).unwrap();
    if let Some(caps) = plain.captures(raw) {
        return caps[1].trim().to_owned();
    }
    String::new()
}

fn parse_subscription_info(headers: &Headers) -> Option<SubscriptionInfo> {
    let raw = headers
        .get("subscription-userinfo")
        .filter(|r| !r.trim().is_empty())?;
    let mut values: HashMap<String, i64> = HashMap::new();
    for segment in raw.split(';') {
        let parts: Vec<&str> = segment.split('=').collect();
        if parts.len() != 2 {
            continue;
        }
        values.insert(
            parts[0].trim().to_lowercase(),
            parts[1].trim().parse().unwrap_or(0),
        );
    }
    if !["upload", "download", "total"]
        .iter()
        .any(|k| values.contains_key(*k))
    {
        return None;
    }
    let expire_at = values.get("expire").and_then(|seconds| {
        chrono::DateTime::from_timestamp(*seconds, 0)
            .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
    });
    Some(SubscriptionInfo {
        upload: values.get("upload").copied().unwrap_or(0),
        download: values.get("download").copied().unwrap_or(0),
        total: values.get("total").copied().unwrap_or(0),
        expire_at,
        web_page_url: headers.get("profile-web-page-url").cloned(),
        support_url: headers.get("support-url").cloned(),
    })
}
