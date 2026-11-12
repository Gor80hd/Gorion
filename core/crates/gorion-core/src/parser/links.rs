//! Ссылки `vless://`, `vmess://`, `trojan://`, `ss://`, `hysteria2://`,
//! `hy2://`, `tuic://`, `anytls://` → outbound sing-box.
//! Эталон: `lib/features/profiles/data/profile_parser.dart`.

use serde_json::{Map, Value, json};

use super::base64_text::try_decode_base64;
use super::uri::{Query, ShareUri, decode_component, decode_component_or_raw, parse_raw_query};
use crate::error::{CoreError, CoreResult};
use crate::json_util::trim_to_none;

type Outbound = Map<String, Value>;

/// `Ok(None)` — строка не ссылка или ссылка неполная (тихо пропускается);
/// `Err` — ссылка распознана, но импортировать её без потерь нельзя.
pub fn parse_share_link(line: &str) -> CoreResult<Option<Outbound>> {
    let Some(scheme) = scheme_of(line) else {
        return Ok(None);
    };
    match scheme.as_str() {
        "hysteria2" | "hy2" => parse_modern_tls(line, "hysteria2"),
        "tuic" => parse_modern_tls(line, "tuic"),
        "anytls" => parse_modern_tls(line, "anytls"),
        "vless" => parse_vless(line),
        "vmess" => parse_vmess(line),
        "trojan" => parse_trojan(line),
        "ss" | "shadowsocks" => Ok(parse_shadowsocks(line)),
        _ => Ok(None),
    }
}

fn scheme_of(line: &str) -> Option<String> {
    let index = line.find("://")?;
    let scheme = &line[..index];
    let mut chars = scheme.chars();
    let first = chars.next()?;
    let valid = first.is_ascii_alphabetic()
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '.' | '-'));
    valid.then(|| scheme.to_ascii_lowercase())
}

fn parse_modern_tls(line: &str, kind: &str) -> CoreResult<Option<Outbound>> {
    let Some(mut uri) = ShareUri::parse(line) else {
        return Ok(None);
    };
    if uri.host.is_empty() {
        return Ok(None);
    }
    if uri.port.is_none() {
        uri.port = Some(443);
    }
    let Some(mut outbound) = credential_outbound(kind, &uri, "password") else {
        return Ok(None);
    };
    let query = uri.query();
    let mut tls = build_tls(&query, true).ok_or_else(|| {
        CoreError::InvalidShareLink(format!("некорректные настройки TLS для {kind}"))
    })?;
    // QUIC-протоколы не используют TCP-рукопожатие uTLS.
    if kind != "anytls" {
        tls.shift_remove("utls");
    }
    if tls.contains_key("reality") {
        return Err(CoreError::InvalidShareLink(format!(
            "REALITY не поддерживается для {kind}"
        )));
    }
    outbound.insert("tls".into(), Value::Object(tls));

    if kind == "hysteria2" {
        if let Some(obfs) = query.get("obfs") {
            let Some(password) = query.get("obfs-password").filter(|_| obfs == "salamander") else {
                return Err(CoreError::InvalidShareLink(
                    "Hysteria2 требует обфускацию salamander с паролем".into(),
                ));
            };
            outbound.insert("obfs".into(), json!({"type": obfs, "password": password}));
        }
        if let Some(ports) = query.get("mport") {
            let ranges = ports
                .split(',')
                .map(parse_port_range)
                .collect::<CoreResult<Vec<String>>>()?;
            outbound.insert("server_ports".into(), json!(ranges));
            outbound.shift_remove("server_port");
        }
        // Пин сертификата требует явной конвертации — молча не теряем.
        if query.contains("pinsha256") {
            return Err(CoreError::InvalidShareLink(
                "импорт пина сертификата Hysteria2 пока не поддерживается".into(),
            ));
        }
    } else if kind == "tuic" {
        let Some(separator) = uri.user_info.find(':').filter(|i| *i > 0) else {
            return Ok(None);
        };
        let decode = |raw: &str| {
            decode_component(raw)
                .ok_or_else(|| CoreError::InvalidShareLink("некорректный userinfo TUIC".into()))
        };
        outbound.insert("uuid".into(), json!(decode(&uri.user_info[..separator])?));
        outbound.insert(
            "password".into(),
            json!(decode(&uri.user_info[separator + 1..])?),
        );
        for key in ["congestion_control", "udp_relay_mode"] {
            if let Some(value) = query.get(key) {
                outbound.insert(key.into(), json!(value));
            }
        }
        for key in ["udp_over_stream", "zero_rtt_handshake"] {
            if let Some(raw) = query.get(key) {
                let value = parse_bool_flag(Some(raw)).ok_or_else(|| {
                    CoreError::InvalidShareLink(format!("некорректный TUIC {key}"))
                })?;
                outbound.insert(key.into(), json!(value));
            }
        }
    }
    Ok(Some(outbound))
}

fn parse_port_range(range: &str) -> CoreResult<String> {
    let normalized = range.trim().replace('-', ":");
    let bounds: Vec<&str> = normalized.split(':').collect();
    let numbers: Vec<Option<i64>> = bounds.iter().map(|b| b.parse::<i64>().ok()).collect();
    let invalid = bounds.len() > 2
        || numbers
            .iter()
            .any(|n| !matches!(n, Some(p) if (1..=65535).contains(p)))
        || (numbers.len() == 2 && numbers[0] > numbers[1]);
    if invalid {
        return Err(CoreError::InvalidShareLink(
            "некорректный диапазон портов Hysteria2".into(),
        ));
    }
    Ok(if bounds.len() == 1 {
        format!("{normalized}:{normalized}")
    } else {
        normalized
    })
}

fn transport_from_query(query: &Query) -> CoreResult<Option<Outbound>> {
    build_transport(TransportValues {
        transport_type: query.first(&["type"]).unwrap_or_else(|| "tcp".into()),
        header_type: query.first(&["headertype"]),
        host: query.first(&["host"]),
        path: query.first(&["path"]),
        service_name: query.first(&["servicename", "service-name"]),
        max_early_data: query.first(&["ed", "maxearlydata"]),
        early_data_header_name: query.first(&["eh", "earlydataheadername"]),
    })
}

fn parse_vless(line: &str) -> CoreResult<Option<Outbound>> {
    let Some(uri) = ShareUri::parse(line) else {
        return Ok(None);
    };
    let Some(mut outbound) = credential_outbound("vless", &uri, "uuid") else {
        return Ok(None);
    };
    let query = uri.query();
    if let Some(flow) = query.first(&["flow"]) {
        outbound.insert("flow".into(), json!(flow));
    }
    if let Some(encoding) = query.first(&["packetencoding", "packet-encoding"]) {
        outbound.insert("packet_encoding".into(), json!(encoding));
    }
    let security = query
        .first(&["security"])
        .unwrap_or_default()
        .to_lowercase();
    let tls = build_tls(&query, false);
    if security == "reality" && tls.is_none() {
        return Ok(None);
    }
    if let Some(tls) = tls {
        outbound.insert("tls".into(), Value::Object(tls));
    }
    if let Some(transport) = transport_from_query(&query)? {
        outbound.insert("transport".into(), Value::Object(transport));
    }
    Ok(Some(outbound))
}

fn parse_trojan(line: &str) -> CoreResult<Option<Outbound>> {
    let Some(uri) = ShareUri::parse(line) else {
        return Ok(None);
    };
    let Some(mut outbound) = credential_outbound("trojan", &uri, "password") else {
        return Ok(None);
    };
    let query = uri.query();
    if let Some(tls) = build_tls(&query, true) {
        outbound.insert("tls".into(), Value::Object(tls));
    }
    if let Some(transport) = transport_from_query(&query)? {
        outbound.insert("transport".into(), Value::Object(transport));
    }
    Ok(Some(outbound))
}

fn parse_vmess(line: &str) -> CoreResult<Option<Outbound>> {
    let body = line.get("vmess://".len()..).unwrap_or_default().trim();
    if let Some(decoded) = try_decode_base64(body)
        && let Ok(Value::Object(json)) = serde_json::from_str::<Value>(&decoded)
    {
        return parse_vmess_json(&json);
    }
    let Some(uri) = ShareUri::parse(line) else {
        return Ok(None);
    };
    let Some(mut outbound) = credential_outbound("vmess", &uri, "uuid") else {
        return Ok(None);
    };
    let query = uri.query();
    outbound.insert(
        "security".into(),
        json!(vmess_security(&query).unwrap_or_else(|| "auto".into())),
    );
    let alter_id = query
        .first(&["alterid", "aid"])
        .and_then(|v| v.parse::<i64>().ok())
        .unwrap_or(0);
    outbound.insert("alter_id".into(), json!(alter_id));
    let security = query
        .first(&["security"])
        .unwrap_or_default()
        .to_lowercase();
    let tls = build_tls(&query, false);
    if security == "reality" && tls.is_none() {
        return Ok(None);
    }
    if let Some(tls) = tls {
        outbound.insert("tls".into(), Value::Object(tls));
    }
    if let Some(transport) = transport_from_query(&query)? {
        outbound.insert("transport".into(), Value::Object(transport));
    }
    Ok(Some(outbound))
}

fn parse_vmess_json(json: &Map<String, Value>) -> CoreResult<Option<Outbound>> {
    let pick = |a: &str, b: &str| {
        trim_to_none(json.get(a).filter(|v| !v.is_null()).or_else(|| json.get(b)))
    };
    let server = pick("add", "server");
    let port = parse_json_int(
        json.get("port")
            .filter(|v| !v.is_null())
            .or_else(|| json.get("server_port")),
    )
    .filter(|p| *p > 0);
    let uuid = pick("id", "uuid");
    let (Some(server), Some(port), Some(uuid)) = (server, port, uuid) else {
        return Ok(None);
    };
    let mut outbound = Map::new();
    outbound.insert("type".into(), json!("vmess"));
    outbound.insert(
        "tag".into(),
        json!(trim_to_none(json.get("ps")).unwrap_or_else(|| format!("{server}:{port}"))),
    );
    outbound.insert("server".into(), json!(server));
    outbound.insert("server_port".into(), json!(port));
    outbound.insert("uuid".into(), json!(uuid));
    outbound.insert(
        "security".into(),
        json!(pick("scy", "security").unwrap_or_else(|| "auto".into())),
    );
    outbound.insert(
        "alter_id".into(),
        json!(parse_json_int(json.get("aid")).unwrap_or(0)),
    );

    let mut tls_params = Query::default();
    for (source, target) in [
        ("tls", "security"),
        ("sni", "sni"),
        ("alpn", "alpn"),
        ("fp", "fp"),
        ("allowInsecure", "allowinsecure"),
        ("pbk", "pbk"),
        ("sid", "sid"),
    ] {
        if let Some(value) = trim_to_none(json.get(source)) {
            tls_params.set(target.into(), value);
        }
    }
    let tls_security = tls_params
        .get("security")
        .unwrap_or_default()
        .to_lowercase();
    let tls = build_tls(&tls_params, false);
    if tls_security == "reality" && tls.is_none() {
        return Ok(None);
    }
    if let Some(tls) = tls {
        outbound.insert("tls".into(), Value::Object(tls));
    }
    let transport = build_transport(TransportValues {
        transport_type: trim_to_none(json.get("net")).unwrap_or_else(|| "tcp".into()),
        header_type: trim_to_none(json.get("type")),
        host: trim_to_none(json.get("host")),
        path: trim_to_none(json.get("path")),
        service_name: trim_to_none(json.get("serviceName")),
        max_early_data: trim_to_none(json.get("ed")),
        early_data_header_name: trim_to_none(json.get("eh")),
    })?;
    if let Some(transport) = transport {
        outbound.insert("transport".into(), Value::Object(transport));
    }
    Ok(Some(outbound))
}

fn parse_shadowsocks(line: &str) -> Option<Outbound> {
    let raw_body = &line[line.find("://")? + 3..];
    let (without_fragment, fragment) = match raw_body.find('#') {
        Some(i) => (&raw_body[..i], &raw_body[i + 1..]),
        None => (raw_body, ""),
    };
    let (mut authority, raw_query) = match without_fragment.find('?') {
        Some(i) => (without_fragment[..i].to_owned(), &without_fragment[i + 1..]),
        None => (without_fragment.to_owned(), ""),
    };
    if !authority.contains('@')
        && let Some(decoded) = try_decode_base64(&authority)
        && decoded.contains('@')
    {
        authority = decoded;
    }
    let at = authority.rfind('@').filter(|i| *i > 0)?;
    let mut credentials = authority[..at].to_owned();
    let host_port = &authority[at + 1..];
    if let Some(decoded) = try_decode_base64(&credentials)
        && decoded.contains(':')
    {
        credentials = decoded;
    }
    let separator = credentials.find(':').filter(|i| *i > 0)?;
    let method = decode_component_or_raw(&credentials[..separator])
        .unwrap_or_else(|| credentials[..separator].trim().to_owned());
    let password = decode_component_or_raw(&credentials[separator + 1..])
        .unwrap_or_else(|| credentials[separator + 1..].trim().to_owned());
    let endpoint = ShareUri::parse(&format!("placeholder://{host_port}"))?;
    if method.is_empty()
        || password.is_empty()
        || endpoint.host.is_empty()
        || endpoint.port_or_zero() == 0
    {
        return None;
    }
    let mut outbound = Map::new();
    outbound.insert("type".into(), json!("shadowsocks"));
    outbound.insert(
        "tag".into(),
        json!(decode_component_or_raw(fragment).unwrap_or_else(|| format!(
            "{}:{}",
            endpoint.host,
            endpoint.port_or_zero()
        ))),
    );
    outbound.insert("server".into(), json!(endpoint.host));
    outbound.insert("server_port".into(), json!(endpoint.port_or_zero()));
    outbound.insert("method".into(), json!(method));
    outbound.insert("password".into(), json!(password));
    let query = parse_raw_query(raw_query);
    if let Some(plugin) = query.first(&["plugin"]) {
        let segments: Vec<&str> = plugin
            .split(';')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect();
        if let Some((first, rest)) = segments.split_first() {
            outbound.insert("plugin".into(), json!(first));
            if !rest.is_empty() {
                outbound.insert("plugin_opts".into(), json!(rest.join(";")));
            }
        }
    }
    Some(outbound)
}

fn credential_outbound(kind: &str, uri: &ShareUri, credential_key: &str) -> Option<Outbound> {
    let host = uri.host.trim();
    let credential =
        decode_component_or_raw(&uri.user_info).unwrap_or_else(|| uri.user_info.trim().to_owned());
    let port = uri.port_or_zero();
    if host.is_empty() || credential.is_empty() || port == 0 {
        return None;
    }
    let mut outbound = Map::new();
    outbound.insert("type".into(), json!(kind));
    outbound.insert("tag".into(), json!(outbound_tag(uri)));
    outbound.insert("server".into(), json!(host));
    outbound.insert("server_port".into(), json!(port));
    outbound.insert(credential_key.into(), json!(credential));
    Some(outbound)
}

/// Имя из фрагмента или `host:port`.
///
/// Δ к эталону: фрагмент декодируется из %-кодировки. Flutter-версия
/// оставляла `%20`, `%F0%9F…` в именах серверов vless/vmess/trojan/hy2/tuic.
fn outbound_tag(uri: &ShareUri) -> String {
    if let Some(name) = uri.fragment.as_deref().and_then(decode_component_or_raw) {
        return name;
    }
    match uri.port {
        Some(port) if port > 0 => format!("{}:{port}", uri.host),
        _ => uri.host.clone(),
    }
}

fn build_tls(params: &Query, force_enabled: bool) -> Option<Map<String, Value>> {
    let security = params
        .first(&["security"])
        .unwrap_or_default()
        .to_lowercase();
    if !(force_enabled || security == "tls" || security == "reality") {
        return None;
    }
    let mut tls = Map::new();
    tls.insert("enabled".into(), json!(true));
    if let Some(server_name) = params.first(&["sni", "servername", "server-name"]) {
        tls.insert("server_name".into(), json!(server_name));
    }
    if parse_bool_flag(params.first(&["allowinsecure", "insecure"]).as_deref()) == Some(true) {
        tls.insert("insecure".into(), json!(true));
    }
    let alpn = split_csv(params.first(&["alpn"]).as_deref());
    if !alpn.is_empty() {
        tls.insert("alpn".into(), json!(alpn));
    }
    if let Some(fingerprint) = params.first(&["fp", "fingerprint"]) {
        tls.insert(
            "utls".into(),
            json!({"enabled": true, "fingerprint": fingerprint}),
        );
    }
    if security == "reality" {
        let public_key = params.first(&["pbk", "publickey", "public-key"])?;
        let mut reality = Map::new();
        reality.insert("enabled".into(), json!(true));
        reality.insert("public_key".into(), json!(public_key));
        if let Some(short_id) = params.first(&["sid", "shortid", "short-id"]) {
            reality.insert("short_id".into(), json!(short_id));
        }
        tls.insert("reality".into(), Value::Object(reality));
        // Δ к эталону: sing-box запускает REALITY только с uTLS, а ссылки
        // без `fp` встречаются. Xray в этом случае берёт Chrome — так же.
        tls.entry("utls")
            .or_insert_with(|| json!({"enabled": true, "fingerprint": "chrome"}));
    }
    Some(tls)
}

struct TransportValues {
    transport_type: String,
    header_type: Option<String>,
    host: Option<String>,
    path: Option<String>,
    service_name: Option<String>,
    max_early_data: Option<String>,
    early_data_header_name: Option<String>,
}

fn build_transport(values: TransportValues) -> CoreResult<Option<Outbound>> {
    let kind = values.transport_type.trim().to_lowercase();
    let header_type = values
        .header_type
        .as_deref()
        .unwrap_or_default()
        .trim()
        .to_lowercase();
    let path = values
        .path
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty());
    let host = values
        .host
        .as_deref()
        .map(str::trim)
        .filter(|h| !h.is_empty());
    let mut transport = Map::new();
    let http = |transport: &mut Outbound| {
        transport.insert("type".into(), json!("http"));
        let hosts = split_csv(host);
        if !hosts.is_empty() {
            transport.insert("host".into(), json!(hosts));
        }
        if let Some(path) = path {
            transport.insert("path".into(), json!(path));
        }
    };
    match kind.as_str() {
        "" | "tcp" => {
            if header_type != "http" {
                return Ok(None);
            }
            http(&mut transport);
        }
        "ws" | "websocket" => {
            transport.insert("type".into(), json!("ws"));
            if let Some(path) = path {
                transport.insert("path".into(), json!(path));
            }
            if let Some(host) = host {
                transport.insert("headers".into(), json!({"Host": host}));
            }
            if let Some(early) = values
                .max_early_data
                .as_deref()
                .and_then(|v| v.trim().parse::<i64>().ok())
                && early > 0
            {
                transport.insert("max_early_data".into(), json!(early));
            }
            if let Some(name) = values
                .early_data_header_name
                .as_deref()
                .map(str::trim)
                .filter(|n| !n.is_empty())
            {
                transport.insert("early_data_header_name".into(), json!(name));
            }
        }
        "grpc" => {
            transport.insert("type".into(), json!("grpc"));
            let service = values
                .service_name
                .as_deref()
                .or(values.path.as_deref())
                .map(|s| s.trim_start_matches('/').trim().to_owned())
                .filter(|s| !s.is_empty());
            if let Some(service) = service {
                transport.insert("service_name".into(), json!(service));
            }
        }
        "http" => http(&mut transport),
        "httpupgrade" | "http-upgrade" => {
            transport.insert("type".into(), json!("httpupgrade"));
            if let Some(host) = host {
                transport.insert("host".into(), json!(host));
            }
            if let Some(path) = path {
                transport.insert("path".into(), json!(path));
            }
        }
        "quic" => {
            transport.insert("type".into(), json!("quic"));
        }
        _ => return Err(CoreError::UnsupportedTransport(values.transport_type)),
    }
    Ok(Some(transport))
}

fn vmess_security(query: &Query) -> Option<String> {
    if let Some(encryption) = query.first(&["encryption"]) {
        return Some(encryption);
    }
    let security = query.first(&["security"])?;
    let normalized = security.to_lowercase();
    (normalized != "tls" && normalized != "reality").then_some(security)
}

fn split_csv(value: Option<&str>) -> Vec<String> {
    value
        .map(|v| {
            v.split(',')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_owned)
                .collect()
        })
        .unwrap_or_default()
}

pub(crate) fn parse_bool_flag(value: Option<&str>) -> Option<bool> {
    match value?.trim().to_lowercase().as_str() {
        "1" | "true" | "yes" | "on" => Some(true),
        "0" | "false" | "no" | "off" => Some(false),
        _ => None,
    }
}

fn parse_json_int(value: Option<&Value>) -> Option<i64> {
    match value? {
        Value::Number(n) => n.as_i64().or_else(|| n.to_string().parse().ok()),
        Value::String(s) => s.trim().parse().ok(),
        Value::Null => None,
        other => other.to_string().trim().parse().ok(),
    }
}
