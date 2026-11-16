//! Настройки движка — конфигурация Gorion, которую строит ядро: вход
//! `mixed` (и `tun` с системным стеком на macOS), селектор серверов без
//! своих правил маршрутизации, протоколы, которые движок умеет. Всё
//! остальное — ошибка `Unsupported`: такой профиль не запускается, а
//! причина уходит в ошибку `EngineUnsupported` ядра.

use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;

use base64::Engine as _;
use serde_json::{Map, Value, json};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::hysteria2::Hysteria2Config;
use crate::outbound::Outbound;
use crate::reality::RealityConfig;
use crate::shadowsocks::{Method, ShadowsocksConfig};
use crate::shadowsocks2022::{self as ss2022, Ss2022Config};
use crate::stream::Security;
use crate::tls::TlsConfig;
use crate::transport::{GrpcConfig, Transport, UpgradeConfig, WsConfig};
use crate::trojan::TrojanConfig;
use crate::tun::{DEFAULT_MTU, DohServer, TunConfig};
use crate::vless::{Flow, VlessConfig};
use crate::xhttp::{
    self, DataPlacement, DownloadSettings, PaddingMethod, PaddingObfs, PaddingPlacement, Placement,
    Range, XhttpConfig, Xmux,
};

/// Разобранные настройки.
#[derive(Debug)]
pub struct Plan {
    pub listen: SocketAddr,
    pub controller: Option<ControllerConfig>,
    /// Тег селектора, которым ядро переключает серверы.
    pub selector_tag: String,
    /// Серверы селектора по порядку.
    pub members: Vec<String>,
    pub selected: String,
    /// Исходящие по тегу: все члены селектора.
    pub outbounds: Vec<(String, Arc<Outbound>)>,
    /// Туннель для всего компьютера (режим TUN).
    pub tun: Option<TunConfig>,
}

impl Plan {
    pub fn outbound(&self, tag: &str) -> Option<&Arc<Outbound>> {
        self.outbounds
            .iter()
            .find(|(t, _)| t == tag)
            .map(|(_, o)| o)
    }
}

#[derive(Clone)]
pub struct ControllerConfig {
    pub listen: SocketAddr,
    pub secret: String,
}

impl std::fmt::Debug for ControllerConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ControllerConfig")
            .field("listen", &self.listen)
            .finish_non_exhaustive()
    }
}

fn unsupported(reason: impl Into<String>) -> EngineError {
    EngineError::Unsupported(reason.into())
}

fn str_field<'a>(object: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    object.get(key).and_then(Value::as_str)
}

fn is_enabled(object: &Map<String, Value>, key: &str) -> bool {
    object
        .get(key)
        .and_then(Value::as_object)
        .and_then(|o| o.get("enabled"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn non_empty(value: Option<&Value>) -> bool {
    match value {
        None | Some(Value::Null) => false,
        Some(Value::Array(items)) => !items.is_empty(),
        Some(Value::Object(map)) => !map.is_empty(),
        Some(Value::String(text)) => !text.is_empty(),
        Some(_) => true,
    }
}

/// План движка из конфигурации Gorion (JSON, который пишет ядро).
pub fn from_config(config: &Value) -> Result<Plan> {
    let config = config
        .as_object()
        .ok_or_else(|| unsupported("config is not an object"))?;

    let inbounds = config
        .get("inbounds")
        .and_then(Value::as_array)
        .ok_or_else(|| unsupported("no inbounds"))?;
    let mut mixed = None;
    let mut tun_inbound = None;
    for inbound in inbounds {
        let inbound = inbound
            .as_object()
            .ok_or_else(|| unsupported("bad inbound"))?;
        match str_field(inbound, "type") {
            Some("mixed") if mixed.is_none() => mixed = Some(inbound),
            Some("tun") if tun_inbound.is_none() => tun_inbound = Some(inbound),
            _ => return Err(unsupported("inbounds: one mixed and at most one tun")),
        }
    }
    let inbound = mixed.ok_or_else(|| unsupported("only a mixed inbound is supported"))?;
    if non_empty(inbound.get("users"))
        || inbound.get("set_system_proxy") == Some(&Value::Bool(true))
    {
        return Err(unsupported("mixed inbound options"));
    }
    let host = str_field(inbound, "listen").unwrap_or("127.0.0.1");
    let port = inbound
        .get("listen_port")
        .and_then(Value::as_u64)
        .and_then(|p| u16::try_from(p).ok())
        .ok_or_else(|| unsupported("inbound listen_port"))?;
    let listen = format!("{host}:{port}")
        .parse::<SocketAddr>()
        .map_err(|_| unsupported("inbound listen address"))?;

    let route = config
        .get("route")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    // Правила маршрутизации (раздельное туннелирование, правила шаблона)
    // движок пока не исполняет. В режиме TUN ядро добавляет два своих —
    // разбор протокола и перехват DNS; их движок делает сам.
    let tun_tag = tun_inbound.map(|tun| str_field(tun, "tag").unwrap_or_default());
    let rules_supported = match tun_tag {
        None => !non_empty(route.get("rules")),
        Some(tag) => {
            route.get("rules")
                == Some(&json!([
                    {"inbound": tag, "action": "sniff"},
                    {"inbound": tag, "protocol": "dns", "action": "hijack-dns"},
                ]))
        }
    };
    if !rules_supported || non_empty(route.get("rule_set")) {
        return Err(unsupported("route rules"));
    }

    let outbounds: Vec<&Map<String, Value>> = config
        .get("outbounds")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Value::as_object).collect())
        .unwrap_or_default();
    let by_tag = |tag: &str| {
        outbounds
            .iter()
            .copied()
            .find(|o| str_field(o, "tag") == Some(tag))
    };
    let final_tag = str_field(&route, "final")
        .map(str::to_owned)
        .or_else(|| {
            outbounds
                .first()
                .and_then(|o| str_field(o, "tag"))
                .map(str::to_owned)
        })
        .ok_or_else(|| unsupported("no outbounds"))?;
    let final_outbound = by_tag(&final_tag).ok_or_else(|| unsupported("final outbound missing"))?;

    let (members, selected) = if str_field(final_outbound, "type") == Some("selector") {
        let members: Vec<String> = final_outbound
            .get("outbounds")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect()
            })
            .unwrap_or_default();
        let first = members
            .first()
            .cloned()
            .ok_or_else(|| unsupported("empty selector"))?;
        let selected = str_field(final_outbound, "default")
            .filter(|tag| members.iter().any(|m| m == tag))
            .map_or(first, str::to_owned);
        (members, selected)
    } else {
        (vec![final_tag.clone()], final_tag.clone())
    };

    let mut translated = Vec::with_capacity(members.len());
    for (index, tag) in members.iter().enumerate() {
        let outbound = by_tag(tag).ok_or_else(|| unsupported("selector member missing"))?;
        // Причина без тега: имя сервера — не для журнала ошибок.
        let engine = translate(outbound)
            .map_err(|error| unsupported(format!("server #{}: {error}", index + 1)))?;
        translated.push((tag.clone(), Arc::new(engine)));
    }

    let controller = config
        .get("experimental")
        .and_then(Value::as_object)
        .and_then(|e| e.get("clash_api"))
        .and_then(Value::as_object)
        .and_then(|api| {
            let listen = str_field(api, "external_controller")?.parse().ok()?;
            Some(ControllerConfig {
                listen,
                secret: str_field(api, "secret").unwrap_or_default().to_owned(),
            })
        });

    let tun = match tun_inbound {
        Some(inbound) => Some(tun_config(inbound, tun_dns(config, &final_tag)?)?),
        None => None,
    };

    Ok(Plan {
        listen,
        controller,
        selector_tag: final_tag,
        members,
        selected,
        outbounds: translated,
        tun,
    })
}

/// Вход `tun`, каким его строит ядро: адреса, `auto_route`, системный стек.
fn tun_config(inbound: &Map<String, Value>, dns: DohServer) -> Result<TunConfig> {
    const KNOWN: [&str; 8] = [
        "type",
        "tag",
        "interface_name",
        "address",
        "auto_route",
        "strict_route",
        "stack",
        "mtu",
    ];
    if !cfg!(target_os = "macos") {
        return Err(unsupported("tun on this system"));
    }
    if let Some(key) = inbound.keys().find(|k| !KNOWN.contains(&k.as_str())) {
        return Err(unsupported(format!("tun option {key}")));
    }
    // На macOS имя `utunN` выбирает система; своё имя движок не ставит.
    if non_empty(inbound.get("interface_name")) {
        return Err(unsupported("tun interface_name"));
    }
    if str_field(inbound, "stack") != Some("system") {
        return Err(unsupported("tun stack"));
    }
    let mut inet4 = None;
    let mut inet6 = None;
    let addresses = inbound
        .get("address")
        .and_then(Value::as_array)
        .ok_or_else(|| unsupported("tun address"))?;
    for address in addresses {
        let bad = || unsupported("tun address");
        let (ip, prefix) = address
            .as_str()
            .and_then(|a| a.split_once('/'))
            .ok_or_else(bad)?;
        let prefix: u8 = prefix.parse().map_err(|_| bad())?;
        match ip.parse::<IpAddr>().map_err(|_| bad())? {
            IpAddr::V4(ip) if inet4.is_none() && (1..=30).contains(&prefix) => {
                inet4 = Some((ip, prefix));
            }
            IpAddr::V6(ip) if inet6.is_none() && (1..=126).contains(&prefix) => {
                inet6 = Some((ip, prefix));
            }
            _ => return Err(bad()),
        }
    }
    if inet4.is_none() && inet6.is_none() {
        return Err(unsupported("tun address"));
    }
    let bool_field = |key: &str| match inbound.get(key) {
        None => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(unsupported(format!("tun {key}"))),
    };
    let auto_route = bool_field("auto_route")?;
    // strict_route на macOS sing-box не меняет: принимаем как есть.
    bool_field("strict_route")?;
    let mtu = match inbound.get("mtu") {
        None => DEFAULT_MTU,
        Some(value) => value
            .as_u64()
            .and_then(|m| u32::try_from(m).ok())
            .filter(|m| (1280..=65535).contains(m))
            .ok_or_else(|| unsupported("tun mtu"))?,
    };
    Ok(TunConfig {
        inet4,
        inet6,
        mtu,
        auto_route,
        dns,
    })
}

/// DNS режима TUN — только тот, что ставит ядро: локальный для имён
/// серверов и DNS-over-HTTPS по IP через селектор для всего остального.
fn tun_dns(config: &Map<String, Value>, selector_tag: &str) -> Result<DohServer> {
    let dns = config
        .get("dns")
        .and_then(Value::as_object)
        .ok_or_else(|| unsupported("tun without dns"))?;
    if dns.keys().any(|k| k != "servers" && k != "final") {
        return Err(unsupported("dns options"));
    }
    let final_tag = str_field(dns, "final").ok_or_else(|| unsupported("dns final"))?;
    let servers = dns
        .get("servers")
        .and_then(Value::as_array)
        .ok_or_else(|| unsupported("dns servers"))?;
    let mut doh = None;
    for server in servers {
        let server = server
            .as_object()
            .ok_or_else(|| unsupported("dns server"))?;
        match str_field(server, "type") {
            Some("local") if server.keys().all(|k| k == "type" || k == "tag") => {}
            Some("https") if doh.is_none() && str_field(server, "tag") == Some(final_tag) => {
                doh = Some(doh_server(server, selector_tag)?);
            }
            _ => return Err(unsupported("dns server")),
        }
    }
    doh.ok_or_else(|| unsupported("dns final server"))
}

fn doh_server(server: &Map<String, Value>, selector_tag: &str) -> Result<DohServer> {
    const KNOWN: [&str; 7] = [
        "type",
        "tag",
        "server",
        "server_port",
        "path",
        "tls",
        "detour",
    ];
    if server.keys().any(|k| !KNOWN.contains(&k.as_str())) {
        return Err(unsupported("dns server options"));
    }
    if str_field(server, "detour") != Some(selector_tag) {
        return Err(unsupported("dns detour"));
    }
    let host = str_field(server, "server").ok_or_else(|| unsupported("dns server address"))?;
    // Имя вместо IP пришлось бы разрешать до туннеля: такое движок не умеет.
    let ip: IpAddr = host
        .parse()
        .map_err(|_| unsupported("dns server is not an ip"))?;
    let port = match server.get("server_port") {
        None => 443,
        Some(value) => value
            .as_u64()
            .and_then(|p| u16::try_from(p).ok())
            .ok_or_else(|| unsupported("dns server_port"))?,
    };
    let path = str_field(server, "path").unwrap_or("/dns-query");
    if !path.starts_with('/') {
        return Err(unsupported("dns path"));
    }
    let tls = server
        .get("tls")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    if tls.keys().any(|k| k != "enabled" && k != "server_name") {
        return Err(unsupported("dns tls options"));
    }
    if tls.get("enabled") == Some(&Value::Bool(false)) {
        return Err(unsupported("dns without tls"));
    }
    Ok(DohServer {
        address: SocketAddr::new(ip, port),
        server_name: str_field(&tls, "server_name").unwrap_or(host).to_owned(),
        path: path.to_owned(),
    })
}

/// Хосты серверов, которые надо разрешить до подъёма туннеля.
pub fn server_hosts(plan: &Plan) -> Vec<String> {
    let mut hosts: Vec<String> = Vec::new();
    for (_, outbound) in &plan.outbounds {
        // Сервер скачивания XHTTP тоже нужен до туннеля.
        let download = match &**outbound {
            Outbound::Vless(config) => xhttp_download(&config.transport),
            Outbound::Trojan(config) => xhttp_download(&config.transport),
            _ => None,
        };
        for server in outbound.server().into_iter().chain(download) {
            if let TargetAddr::Domain(host, _) = server
                && !hosts.contains(host)
            {
                hosts.push(host.clone());
            }
        }
    }
    hosts
}

fn xhttp_download(transport: &Transport) -> Option<&TargetAddr> {
    match transport {
        Transport::Xhttp(config) => config.download.as_ref().map(|d| &d.server),
        _ => None,
    }
}

fn server(outbound: &Map<String, Value>) -> Result<TargetAddr> {
    let host = str_field(outbound, "server").ok_or_else(|| unsupported("missing server"))?;
    let port = outbound
        .get("server_port")
        .and_then(Value::as_u64)
        .and_then(|p| u16::try_from(p).ok())
        .ok_or_else(|| unsupported("missing server_port"))?;
    TargetAddr::from_host(host, port)
}

/// Общие для всех протоколов поля, которых движок не умеет.
fn check_common(outbound: &Map<String, Value>) -> Result<()> {
    if non_empty(outbound.get("detour")) {
        return Err(unsupported("detour"));
    }
    if is_enabled(outbound, "multiplex") {
        return Err(unsupported("multiplex"));
    }
    Ok(())
}

/// Строки заголовков: значение — строка или массив строк (как в sing-box).
fn headers(value: Option<&Value>) -> Result<Vec<(String, String)>> {
    let mut out = Vec::new();
    let Some(map) = value.and_then(Value::as_object) else {
        return Ok(out);
    };
    for (name, value) in map {
        match value {
            Value::String(text) => out.push((name.clone(), text.clone())),
            Value::Array(items) => {
                for item in items {
                    let text = item
                        .as_str()
                        .ok_or_else(|| unsupported("transport headers"))?;
                    out.push((name.clone(), text.to_owned()));
                }
            }
            _ => return Err(unsupported("transport headers")),
        }
    }
    Ok(out)
}

/// Транспорт V2Ray: WebSocket, HTTPUpgrade, gRPC. Незнакомые поля — отказ.
fn transport(outbound: &Map<String, Value>) -> Result<Transport> {
    let Some(transport) = outbound
        .get("transport")
        .and_then(Value::as_object)
        .filter(|t| !t.is_empty())
    else {
        if non_empty(outbound.get("transport")) {
            return Err(unsupported("transport"));
        }
        return Ok(Transport::None);
    };
    let kind = str_field(transport, "type").unwrap_or_default();
    let allowed: &[&str] = match kind {
        "ws" => &[
            "type",
            "path",
            "headers",
            "max_early_data",
            "early_data_header_name",
        ],
        "httpupgrade" => &["type", "host", "path", "headers"],
        // XHTTP из Xray: поля — как в Xray, только snake_case (см. `xhttp`).
        "xhttp" => &[
            "type",
            "path",
            "host",
            "mode",
            "headers",
            "x_padding_bytes",
            "no_grpc_header",
            "sc_max_each_post_bytes",
            "sc_min_posts_interval_ms",
            "xmux",
            "x_padding_obfs_mode",
            "x_padding_key",
            "x_padding_header",
            "x_padding_placement",
            "x_padding_method",
            "uplink_http_method",
            "session_placement",
            "session_key",
            "seq_placement",
            "seq_key",
            "uplink_data_placement",
            "uplink_data_key",
            "uplink_chunk_size",
            "download_settings",
        ],
        // Таймауты пингов HTTP/2 движок не использует: это не меняет поток.
        "grpc" => &[
            "type",
            "service_name",
            "idle_timeout",
            "ping_timeout",
            "permit_without_stream",
        ],
        other => return Err(unsupported(format!("transport {other}"))),
    };
    if let Some((key, _)) = transport
        .iter()
        .find(|(key, value)| !allowed.contains(&key.as_str()) && non_empty(Some(value)))
    {
        return Err(unsupported(format!("transport {kind} {key}")));
    }
    let path = str_field(transport, "path").unwrap_or_default().to_owned();
    Ok(match kind {
        "ws" => Transport::WebSocket(WsConfig {
            path,
            headers: headers(transport.get("headers"))?,
            max_early_data: transport
                .get("max_early_data")
                .and_then(Value::as_u64)
                .and_then(|n| usize::try_from(n).ok())
                .unwrap_or(0),
            early_data_header: str_field(transport, "early_data_header_name")
                .unwrap_or_default()
                .to_owned(),
        }),
        "httpupgrade" => Transport::HttpUpgrade(UpgradeConfig {
            path,
            host: str_field(transport, "host").unwrap_or_default().to_owned(),
            headers: headers(transport.get("headers"))?,
        }),
        "xhttp" => Transport::Xhttp(Box::new(xhttp_config(transport, path, true)?)),
        _ => Transport::Grpc(GrpcConfig::new(
            str_field(transport, "service_name").unwrap_or_default(),
        )),
    })
}

/// Диапазон Xray: число или строка `"от-до"`; отрицательные — ноль.
fn range(value: Option<&Value>, what: &str) -> Result<Option<Range>> {
    let bad = || unsupported(format!("xhttp {what}"));
    let (from, to) = match value {
        None | Some(Value::Null) => return Ok(None),
        Some(Value::Number(n)) => {
            let n = n.as_i64().ok_or_else(bad)?;
            (n, n)
        }
        Some(Value::String(text)) => {
            let text = text.trim();
            if text.is_empty() {
                return Ok(None);
            }
            match text.parse::<i64>() {
                Ok(n) => (n, n),
                Err(_) => {
                    let (from, to) = text.split_once('-').ok_or_else(bad)?;
                    (
                        from.trim().parse().map_err(|_| bad())?,
                        to.trim().parse().map_err(|_| bad())?,
                    )
                }
            }
        }
        Some(_) => return Err(bad()),
    };
    let (from, to) = (from.max(0) as u64, to.max(0) as u64);
    Ok(Some(Range::new(from.min(to), from.max(to))))
}

/// Текстовое поле XHTTP: пусто — `default`.
fn xhttp_text(transport: &Map<String, Value>, key: &str, default: &str) -> String {
    str_field(transport, key)
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or(default)
        .to_owned()
}

fn xhttp_config(
    transport: &Map<String, Value>,
    path: String,
    allow_download: bool,
) -> Result<XhttpConfig> {
    let mode = xhttp::Mode::parse(str_field(transport, "mode").unwrap_or_default())
        .ok_or_else(|| unsupported("xhttp mode"))?;
    let mut config = XhttpConfig::new(path, str_field(transport, "host").unwrap_or_default(), mode);
    config.headers = headers(transport.get("headers"))?;
    xhttp_placements(transport, &mut config)?;
    if let Some(download) = transport
        .get("download_settings")
        .and_then(Value::as_object)
        .filter(|d| !d.is_empty())
    {
        // Как в Xray: со stream-one отдельного скачивания нет.
        if !allow_download || mode == xhttp::Mode::StreamOne {
            return Err(unsupported("xhttp download_settings"));
        }
        config.download = Some(std::sync::Arc::new(download_settings(download)?));
    } else if non_empty(transport.get("download_settings")) {
        return Err(unsupported("xhttp download_settings"));
    }
    if let Some(padding) = range(transport.get("x_padding_bytes"), "x_padding_bytes")? {
        if padding.from == 0 {
            return Err(unsupported("xhttp x_padding_bytes"));
        }
        config.x_padding_bytes = padding;
    }
    if let Some(Value::Bool(flag)) = transport.get("no_grpc_header") {
        config.no_grpc_header = *flag;
    }
    if let Some(max) = range(
        transport.get("sc_max_each_post_bytes"),
        "sc_max_each_post_bytes",
    )?
    .filter(|r| !r.is_zero())
    {
        if max.from == 0 {
            return Err(unsupported("xhttp sc_max_each_post_bytes"));
        }
        config.sc_max_each_post_bytes = max;
    }
    if let Some(interval) = range(
        transport.get("sc_min_posts_interval_ms"),
        "sc_min_posts_interval_ms",
    )?
    .filter(|r| !r.is_zero())
    {
        config.sc_min_posts_interval_ms = interval;
    }
    if let Some(xmux) = transport.get("xmux").and_then(Value::as_object) {
        const KNOWN: [&str; 6] = [
            "max_concurrency",
            "max_connections",
            "c_max_reuse_times",
            "h_max_request_times",
            "h_max_reusable_secs",
            "h_keep_alive_period",
        ];
        if let Some(key) = xmux.keys().find(|k| !KNOWN.contains(&k.as_str())) {
            return Err(unsupported(format!("xhttp xmux {key}")));
        }
        let field =
            |key: &str| Ok::<_, EngineError>(range(xmux.get(key), key)?.unwrap_or_default());
        let parsed = Xmux {
            max_concurrency: field("max_concurrency")?,
            max_connections: field("max_connections")?,
            c_max_reuse_times: field("c_max_reuse_times")?,
            h_max_request_times: field("h_max_request_times")?,
            h_max_reusable_secs: field("h_max_reusable_secs")?,
        };
        // Пустой xmux Xray заменяет своим по умолчанию; пинги HTTP/2
        // (`h_keep_alive_period`) движок не шлёт.
        if parsed != Xmux::default() {
            if !parsed.max_connections.is_zero() && !parsed.max_concurrency.is_zero() {
                return Err(unsupported(
                    "xhttp xmux max_connections with max_concurrency",
                ));
            }
            config.xmux = parsed;
        }
    }
    Ok(config)
}

/// Метод, размещения сессии, номера и данных, обфускация паддинга — с
/// проверками и умолчаниями Xray (`SplitHTTPConfig.Build`).
fn xhttp_placements(transport: &Map<String, Value>, config: &mut XhttpConfig) -> Result<()> {
    let bad = |what: &str| unsupported(format!("xhttp {what}"));
    config.uplink_method = xhttp_text(transport, "uplink_http_method", "POST").to_ascii_uppercase();
    if http::Method::from_bytes(config.uplink_method.as_bytes()).is_err() {
        return Err(bad("uplink_http_method"));
    }
    // GET с потоковым телом не бывает (у Xray — только packet-up).
    if config.uplink_method == "GET" && config.mode != xhttp::Mode::PacketUp {
        return Err(bad("uplink_http_method"));
    }
    config.session_placement = Placement::parse(&xhttp_text(transport, "session_placement", ""))
        .ok_or_else(|| bad("session_placement"))?;
    config.seq_placement = Placement::parse(&xhttp_text(transport, "seq_placement", ""))
        .ok_or_else(|| bad("seq_placement"))?;
    let key_for = |placement: Placement, cookie: &str, header: &str| match placement {
        Placement::Path => String::new(),
        Placement::Query | Placement::Cookie => cookie.to_owned(),
        Placement::Header => header.to_owned(),
    };
    config.session_key = xhttp_text(
        transport,
        "session_key",
        &key_for(config.session_placement, "x_session", "X-Session"),
    );
    config.seq_key = xhttp_text(
        transport,
        "seq_key",
        &key_for(config.seq_placement, "x_seq", "X-Seq"),
    );
    config.data_placement =
        DataPlacement::parse(&xhttp_text(transport, "uplink_data_placement", ""))
            .ok_or_else(|| bad("uplink_data_placement"))?;
    // Данные в заголовках или cookie — как в Xray, только при явном packet-up.
    if config.data_placement != DataPlacement::Body && config.mode != xhttp::Mode::PacketUp {
        return Err(bad("uplink_data_placement"));
    }
    let data_default = if config.data_placement == DataPlacement::Cookie {
        "x_data"
    } else {
        "X-Data"
    };
    config.data_key = xhttp_text(transport, "uplink_data_key", data_default);
    if let Some(size) = range(transport.get("uplink_chunk_size"), "uplink_chunk_size")? {
        config.uplink_chunk_size = size;
    }
    match transport.get("x_padding_obfs_mode") {
        None | Some(Value::Null) | Some(Value::Bool(false)) => {}
        Some(Value::Bool(true)) => {
            config.padding_obfs = Some(PaddingObfs {
                placement: PaddingPlacement::parse(&xhttp_text(
                    transport,
                    "x_padding_placement",
                    "",
                ))
                .ok_or_else(|| bad("x_padding_placement"))?,
                key: xhttp_text(transport, "x_padding_key", "x_padding"),
                header: xhttp_text(transport, "x_padding_header", "X-Padding"),
                method: PaddingMethod::parse(&xhttp_text(transport, "x_padding_method", ""))
                    .ok_or_else(|| bad("x_padding_method"))?,
            });
        }
        Some(_) => return Err(bad("x_padding_obfs_mode")),
    }
    Ok(())
}

/// Отдельный сервер скачивания: `server`, `server_port`, `tls` и
/// `transport` (XHTTP) — как у самого исходящего.
fn download_settings(download: &Map<String, Value>) -> Result<DownloadSettings> {
    const KNOWN: [&str; 4] = ["server", "server_port", "tls", "transport"];
    if let Some((key, _)) = download
        .iter()
        .find(|(key, value)| !KNOWN.contains(&key.as_str()) && non_empty(Some(value)))
    {
        return Err(unsupported(format!("xhttp download_settings {key}")));
    }
    let server = server(download)?;
    let (security, alpn) = security(download, &server)?;
    let transport = download
        .get("transport")
        .and_then(Value::as_object)
        .filter(|t| str_field(t, "type") == Some("xhttp"))
        .ok_or_else(|| unsupported("xhttp download_settings transport"))?;
    if non_empty(transport.get("download_settings")) {
        return Err(unsupported("xhttp download_settings"));
    }
    let path = str_field(transport, "path").unwrap_or_default().to_owned();
    Ok(DownloadSettings {
        server,
        security,
        alpn: alpn.unwrap_or_default(),
        xhttp: xhttp_config(transport, path, false)?,
    })
}

/// XHTTP поверх этой защиты. Всё, что умеет Xray-клиент, движок умеет;
/// проверка осталась для будущих ограничений.
fn check_xhttp(transport: &Transport, security: &Security, _alpn: Option<&[String]>) -> Result<()> {
    let Transport::Xhttp(config) = transport else {
        return Ok(());
    };
    if config.download.is_some() && config.resolved_mode(security) == xhttp::Mode::StreamOne {
        return Err(unsupported("xhttp download_settings with stream-one"));
    }
    Ok(())
}

/// Поля `tls`, которые движок понимает. `utls` принимается с любым
/// отпечатком: ClientHello движка всегда как у Chrome.
const TLS_FIELDS: [&str; 7] = [
    "enabled",
    "server_name",
    "insecure",
    "alpn",
    "utls",
    "reality",
    "certificate",
];

/// Защита потока из `tls` и ALPN, если он задан.
fn security(
    outbound: &Map<String, Value>,
    server: &TargetAddr,
) -> Result<(Security, Option<Vec<String>>)> {
    let Some(tls) = outbound
        .get("tls")
        .and_then(Value::as_object)
        .filter(|tls| tls.get("enabled").and_then(Value::as_bool).unwrap_or(false))
    else {
        return Ok((Security::None, None));
    };
    if let Some((key, _)) = tls
        .iter()
        .find(|(key, value)| !TLS_FIELDS.contains(&key.as_str()) && non_empty(Some(value)))
    {
        return Err(unsupported(format!("tls {key}")));
    }
    let alpn = tls
        .get("alpn")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .filter(|alpn| !alpn.is_empty());
    let server_name = str_field(tls, "server_name").filter(|name| !name.is_empty());
    if is_enabled(tls, "reality") {
        let reality = tls
            .get("reality")
            .and_then(Value::as_object)
            .ok_or_else(|| unsupported("reality"))?;
        let key =
            str_field(reality, "public_key").ok_or_else(|| unsupported("reality public_key"))?;
        let key = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(key.trim_end_matches('='))
            .ok()
            .and_then(|k| <[u8; 32]>::try_from(k).ok())
            .ok_or_else(|| unsupported("reality public_key"))?;
        let server_name = server_name.ok_or_else(|| unsupported("reality server_name"))?;
        let reality = RealityConfig::new(
            server_name,
            key,
            str_field(reality, "short_id").unwrap_or_default(),
        )
        .map_err(|_| unsupported("reality short_id"))?;
        return Ok((Security::Reality(reality), alpn));
    }
    let server_name = match (server_name, server) {
        (Some(name), _) => name.to_owned(),
        (None, TargetAddr::Domain(host, _)) => host.clone(),
        (None, TargetAddr::Ip(addr)) => addr.ip().to_string(),
    };
    // sing-box принимает сертификат строкой или массивом строк PEM.
    let certificate = match tls.get("certificate") {
        None | Some(Value::Null) => None,
        Some(Value::String(pem)) => Some(pem.clone()),
        Some(Value::Array(lines)) => Some(
            lines
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        Some(_) => return Err(unsupported("tls certificate")),
    };
    let insecure = tls
        .get("insecure")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let config = TlsConfig::new(server_name, insecure, certificate.as_deref())
        .map_err(|_| unsupported("tls certificate"))?;
    Ok((Security::Tls(config), alpn))
}

/// Hysteria2. Скорости (`up_mbps`, `down_mbps`) не используются: движок
/// всегда управляет перегрузкой через BBR. С `server_ports` порт меняется
/// раз в `hop_interval` (по умолчанию 30 с, не чаще раза в 5 с).
fn hysteria2(outbound: &Map<String, Value>) -> Result<Outbound> {
    const KNOWN: [&str; 13] = [
        "type",
        "tag",
        "server",
        "server_port",
        "server_ports",
        "hop_interval",
        "up_mbps",
        "down_mbps",
        "obfs",
        "password",
        "network",
        "tls",
        "domain_strategy",
    ];
    check_common(outbound)?;
    if let Some((key, _)) = outbound
        .iter()
        .find(|(key, value)| !KNOWN.contains(&key.as_str()) && non_empty(Some(value)))
    {
        return Err(unsupported(format!("hysteria2 {key}")));
    }
    if non_empty(outbound.get("domain_strategy")) {
        return Err(unsupported("hysteria2 domain_strategy"));
    }
    let (tcp, udp) = match str_field(outbound, "network") {
        None | Some("") => (true, true),
        Some("tcp") => (true, false),
        Some("udp") => (false, true),
        Some(_) => return Err(unsupported("hysteria2 network")),
    };
    let hop_interval = match outbound.get("hop_interval") {
        None | Some(Value::Null) => crate::udphop::DEFAULT_INTERVAL,
        Some(Value::String(text)) if text.trim().is_empty() => crate::udphop::DEFAULT_INTERVAL,
        Some(Value::String(text)) => go_duration(text)
            .ok_or_else(|| unsupported("hysteria2 hop_interval"))?
            .max(crate::udphop::MIN_INTERVAL),
        Some(_) => return Err(unsupported("hysteria2 hop_interval")),
    };
    let ports = match outbound.get("server_ports") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(items)) => items
            .iter()
            .map(|item| item.as_str().and_then(port_range))
            .collect::<Option<Vec<_>>>()
            .ok_or_else(|| unsupported("hysteria2 server_ports"))?,
        Some(Value::String(text)) => {
            vec![port_range(text).ok_or_else(|| unsupported("hysteria2 server_ports"))?]
        }
        Some(_) => return Err(unsupported("hysteria2 server_ports")),
    };
    let host = str_field(outbound, "server").ok_or_else(|| unsupported("missing server"))?;
    let port = match outbound.get("server_port").and_then(Value::as_u64) {
        Some(port) => u16::try_from(port).map_err(|_| unsupported("server_port"))?,
        None => ports
            .first()
            .map(|(from, _)| *from)
            .ok_or_else(|| unsupported("missing server_port"))?,
    };
    let server = TargetAddr::from_host(host, port)?;
    let obfs = match outbound.get("obfs").and_then(Value::as_object) {
        None => None,
        Some(obfs) if obfs.is_empty() => None,
        Some(obfs) => {
            if str_field(obfs, "type").unwrap_or("salamander") != "salamander" {
                return Err(unsupported("hysteria2 obfs type"));
            }
            let password = str_field(obfs, "password").unwrap_or_default();
            if password.len() < crate::salamander::MIN_PASSWORD_LEN {
                return Err(unsupported("hysteria2 obfs password"));
            }
            Some(password)
        }
    };
    let (security, _alpn) = security(outbound, &server)?;
    let tls = match security {
        Security::Tls(tls) => tls,
        // Без TLS QUIC не бывает; REALITY у Hysteria2 нет.
        Security::None => return Err(unsupported("hysteria2 without tls")),
        Security::Reality(_) => return Err(unsupported("hysteria2 with reality")),
    };
    let password = str_field(outbound, "password").unwrap_or_default();
    let mut config = Hysteria2Config::new(server, password, tls, obfs);
    config.ports = ports;
    config.hop_interval = hop_interval;
    config.tcp = tcp;
    config.udp = udp;
    Ok(Outbound::Hysteria2(Box::new(config)))
}

/// Длительность в записи Go: `30s`, `1m30s`, `500ms`, `1h`.
fn go_duration(text: &str) -> Option<std::time::Duration> {
    let mut rest = text.trim();
    if rest.is_empty() {
        return None;
    }
    let mut total = 0f64;
    while !rest.is_empty() {
        let digits = rest
            .find(|c: char| !c.is_ascii_digit() && c != '.')
            .unwrap_or(rest.len());
        let value: f64 = rest[..digits].parse().ok()?;
        rest = &rest[digits..];
        let unit = rest
            .find(|c: char| c.is_ascii_digit() || c == '.')
            .unwrap_or(rest.len());
        let scale = match &rest[..unit] {
            "ns" => 1e-9,
            "us" | "µs" => 1e-6,
            "ms" => 1e-3,
            "s" => 1.0,
            "m" => 60.0,
            "h" => 3600.0,
            _ => return None,
        };
        rest = &rest[unit..];
        total += value * scale;
    }
    std::time::Duration::try_from_secs_f64(total).ok()
}

/// Диапазон портов sing-box: `"20000:30000"` или один порт.
fn port_range(text: &str) -> Option<(u16, u16)> {
    let (from, to) = text.split_once(':').unwrap_or((text, text));
    let from: u16 = from.trim().parse().ok()?;
    let to: u16 = to.trim().parse().ok()?;
    (from > 0 && from <= to).then_some((from, to))
}

fn translate(outbound: &Map<String, Value>) -> Result<Outbound> {
    match str_field(outbound, "type") {
        Some("direct") => {
            if non_empty(outbound.get("override_address")) {
                return Err(unsupported("direct override"));
            }
            Ok(Outbound::Direct)
        }
        Some("shadowsocks") => {
            check_common(outbound)?;
            if non_empty(outbound.get("plugin")) {
                return Err(unsupported("shadowsocks plugin"));
            }
            if non_empty(outbound.get("transport")) {
                return Err(unsupported("transport"));
            }
            let method = str_field(outbound, "method").unwrap_or_default();
            let password = str_field(outbound, "password").unwrap_or_default();
            if ss2022::Method::is_2022(method) {
                let method =
                    ss2022::Method::parse(method).map_err(|_| unsupported("shadowsocks method"))?;
                let config = Ss2022Config::new(server(outbound)?, method, password)
                    .map_err(|_| unsupported("shadowsocks 2022 key"))?;
                return Ok(Outbound::Shadowsocks2022(Box::new(config)));
            }
            let method = Method::parse(method).map_err(|_| unsupported("shadowsocks method"))?;
            Ok(Outbound::Shadowsocks(ShadowsocksConfig::new(
                server(outbound)?,
                method,
                password,
            )))
        }
        Some("trojan") => {
            check_common(outbound)?;
            let password = str_field(outbound, "password").unwrap_or_default();
            let server = server(outbound)?;
            let (security, alpn) = security(outbound, &server)?;
            if matches!(security, Security::Reality(_)) {
                return Err(unsupported("trojan with reality"));
            }
            let transport = transport(outbound)?;
            check_xhttp(&transport, &security, alpn.as_deref())?;
            let mut config = TrojanConfig::new(server, password, security);
            if let Some(alpn) = alpn {
                config.alpn = alpn;
            }
            config.transport = transport;
            Ok(Outbound::Trojan(Box::new(config)))
        }
        Some("vless") => {
            check_common(outbound)?;
            let uuid = str_field(outbound, "uuid").ok_or_else(|| unsupported("vless uuid"))?;
            let flow = Flow::parse(str_field(outbound, "flow").unwrap_or_default())
                .map_err(|_| unsupported("vless flow"))?;
            if non_empty(outbound.get("packet_encoding"))
                && str_field(outbound, "packet_encoding") != Some("xudp")
            {
                return Err(unsupported("vless packet_encoding"));
            }
            let server = server(outbound)?;
            let (security, alpn) = security(outbound, &server)?;
            if flow == Flow::Vision && security.is_none() {
                return Err(unsupported("vision without tls"));
            }
            let transport = transport(outbound)?;
            if flow == Flow::Vision && !transport.is_none() {
                return Err(unsupported("vision with transport"));
            }
            check_xhttp(&transport, &security, alpn.as_deref())?;
            let mut config = VlessConfig::new(server, uuid, flow, security);
            if let Some(alpn) = alpn {
                config.alpn = alpn;
            }
            config.transport = transport;
            Ok(Outbound::Vless(Box::new(config)))
        }
        Some("hysteria2") => hysteria2(outbound),
        Some(other) => Err(unsupported(format!("protocol {other}"))),
        None => Err(unsupported("outbound without type")),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use serde_json::json;

    use super::*;

    fn built(outbounds: Value, rules: Value) -> Value {
        json!({
            "log": {"level": "info"},
            "inbounds": [{"type": "mixed", "tag": "gorion-mixed", "listen": "127.0.0.1", "listen_port": 2080}],
            "outbounds": outbounds,
            "route": {"auto_detect_interface": true, "final": "gorion-manual", "rules": rules},
            "experimental": {"clash_api": {"external_controller": "127.0.0.1:9090", "secret": "s"}}
        })
    }

    fn servers() -> Value {
        json!([
            {"type": "vless", "tag": "R", "server": "example.com", "server_port": 443,
             "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "flow": "xtls-rprx-vision",
             "tls": {"enabled": true, "server_name": "www.microsoft.com",
                     "utls": {"enabled": true, "fingerprint": "chrome"},
                     "reality": {"enabled": true,
                                 "public_key": "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0",
                                 "short_id": "0123abcd"}}},
            {"type": "shadowsocks", "tag": "S", "server": "10.0.0.1", "server_port": 8388,
             "method": "chacha20-ietf-poly1305", "password": "p"},
            {"type": "direct", "tag": "direct"},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["R", "S"], "default": "S"},
            {"type": "urltest", "tag": "gorion-auto", "outbounds": ["R", "S"]}
        ])
    }

    #[test]
    fn reads_the_config_gorion_builds() {
        let plan = from_config(&built(servers(), json!([]))).unwrap();
        assert_eq!(plan.listen, "127.0.0.1:2080".parse().unwrap());
        assert_eq!(plan.selector_tag, "gorion-manual");
        assert_eq!(plan.members, ["R", "S"]);
        assert_eq!(plan.selected, "S");
        assert!(matches!(**plan.outbound("R").unwrap(), Outbound::Vless(_)));
        assert!(matches!(
            **plan.outbound("S").unwrap(),
            Outbound::Shadowsocks(_)
        ));
        let controller = plan.controller.unwrap();
        assert_eq!(controller.listen.port(), 9090);
        assert_eq!(controller.secret, "s");
    }

    #[test]
    fn reads_trojan_shadowsocks_2022_and_plain_tls() {
        let key = base64::engine::general_purpose::STANDARD.encode([1u8; 16]);
        let list = json!([
            {"type": "trojan", "tag": "T", "server": "t.example.com", "server_port": 443,
             "password": "p", "tls": {"enabled": true, "alpn": ["http/1.1"],
                                      "utls": {"enabled": true, "fingerprint": "firefox"}}},
            {"type": "shadowsocks", "tag": "S", "server": "10.0.0.1", "server_port": 8388,
             "method": "2022-blake3-aes-128-gcm", "password": format!("{key}:{key}")},
            {"type": "vless", "tag": "V", "server": "10.0.0.2", "server_port": 443,
             "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "flow": "xtls-rprx-vision",
             "tls": {"enabled": true, "server_name": "v.example.com", "insecure": true}},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["T", "S", "V"]}
        ]);
        let plan = from_config(&built(list, json!([]))).unwrap();
        let Outbound::Trojan(trojan) = &**plan.outbound("T").unwrap() else {
            panic!("trojan")
        };
        assert_eq!(trojan.alpn, ["http/1.1"]);
        let Security::Tls(tls) = &trojan.security else {
            panic!("tls")
        };
        // Имя сервера по умолчанию — его адрес.
        assert_eq!(tls.server_name, "t.example.com");
        assert!(!tls.insecure);
        assert!(matches!(
            **plan.outbound("S").unwrap(),
            Outbound::Shadowsocks2022(_)
        ));
        let Outbound::Vless(vless) = &**plan.outbound("V").unwrap() else {
            panic!("vless")
        };
        let Security::Tls(tls) = &vless.security else {
            panic!("tls")
        };
        assert_eq!(tls.server_name, "v.example.com");
        assert!(tls.insecure);

        // Ключ 2022 не той длины — отказ.
        let list = json!([
            {"type": "shadowsocks", "tag": "S", "server": "10.0.0.1", "server_port": 8388,
             "method": "2022-blake3-aes-256-gcm", "password": key},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["S"]}
        ]);
        assert!(from_config(&built(list, json!([]))).is_err());
    }

    #[test]
    fn reads_transports() {
        let list = json!([
            {"type": "vless", "tag": "W", "server": "10.0.0.2", "server_port": 443,
             "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
             "tls": {"enabled": true, "server_name": "cdn.example.com"},
             "transport": {"type": "ws", "path": "/ws", "headers": {"Host": "cdn.example.com"},
                           "max_early_data": 2048, "early_data_header_name": "Sec-WebSocket-Protocol"}},
            {"type": "trojan", "tag": "G", "server": "10.0.0.3", "server_port": 443, "password": "p",
             "tls": {"enabled": true, "server_name": "g.example.com"},
             "transport": {"type": "grpc", "service_name": "GunService", "idle_timeout": "15s"}},
            {"type": "vless", "tag": "U", "server": "10.0.0.4", "server_port": 80,
             "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
             "transport": {"type": "httpupgrade", "host": "u.example.com", "path": "/up"}},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["W", "G", "U"]}
        ]);
        let plan = from_config(&built(list, json!([]))).unwrap();
        let Outbound::Vless(ws) = &**plan.outbound("W").unwrap() else {
            panic!("vless")
        };
        let Transport::WebSocket(config) = &ws.transport else {
            panic!("ws")
        };
        assert_eq!(config.max_early_data, 2048);
        assert_eq!(
            config.headers,
            [("Host".to_owned(), "cdn.example.com".to_owned())]
        );
        let Outbound::Trojan(grpc) = &**plan.outbound("G").unwrap() else {
            panic!("trojan")
        };
        assert!(matches!(&grpc.transport, Transport::Grpc(c) if c.service_name == "GunService"));
        let Outbound::Vless(up) = &**plan.outbound("U").unwrap() else {
            panic!("vless")
        };
        assert!(matches!(&up.transport, Transport::HttpUpgrade(c) if c.host == "u.example.com"));

        // Чего нет: транспорт HTTP и QUIC, незнакомые поля, Vision поверх транспорта.
        for transport in [
            json!({"type": "http", "host": ["a"]}),
            json!({"type": "quic"}),
            json!({"type": "ws", "path": "/", "unknown": 1}),
        ] {
            let list = json!([
                {"type": "trojan", "tag": "T", "server": "h", "server_port": 1, "password": "p",
                 "transport": transport},
                {"type": "selector", "tag": "gorion-manual", "outbounds": ["T"]}
            ]);
            assert!(from_config(&built(list, json!([]))).is_err());
        }
    }

    #[test]
    fn reads_hysteria2() {
        let list = json!([
            {"type": "hysteria2", "tag": "H", "server": "hy.example.com",
             "server_ports": ["20000:20010", "443"], "hop_interval": "30s",
             "up_mbps": 50, "down_mbps": 100, "password": "p",
             "obfs": {"type": "salamander", "password": "obfs-pass"},
             "tls": {"enabled": true, "server_name": "sni.example.com", "insecure": true,
                     "alpn": ["h3"]}},
            {"type": "hysteria2", "tag": "P", "server": "10.0.0.9", "server_port": 8443,
             "password": "p", "tls": {"enabled": true}},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["H", "P"]}
        ]);
        let plan = from_config(&built(list, json!([]))).unwrap();
        let Outbound::Hysteria2(hy) = &**plan.outbound("H").unwrap() else {
            panic!("hysteria2")
        };
        assert_eq!(hy.ports, [(20000, 20010), (443, 443)]);
        // Без server_port — первый порт диапазона.
        assert_eq!(
            hy.server,
            TargetAddr::Domain("hy.example.com".into(), 20000)
        );
        assert_eq!(hy.tls.server_name, "sni.example.com");
        assert!(hy.tls.insecure);
        let Outbound::Hysteria2(plain) = &**plan.outbound("P").unwrap() else {
            panic!("hysteria2")
        };
        assert_eq!(plain.tls.server_name, "10.0.0.9");
        assert!(plain.ports.is_empty());
        assert_eq!(server_hosts(&plan), ["hy.example.com"]);
        assert_eq!(hy.hop_interval, std::time::Duration::from_secs(30));
        assert!(hy.tcp && hy.udp);
        assert_eq!(
            go_duration("1m30s"),
            Some(std::time::Duration::from_secs(90))
        );
        assert_eq!(
            go_duration("500ms"),
            Some(std::time::Duration::from_millis(500))
        );
        assert_eq!(go_duration("30"), None);
        // Чаще раза в 5 с порт не меняется; network ограничивает подключения.
        let list = json!([
            {"type": "hysteria2", "tag": "H", "server": "h", "server_ports": "1000:1010",
             "hop_interval": "1s", "network": "udp", "password": "p", "tls": {"enabled": true}},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["H"]}
        ]);
        let plan = from_config(&built(list, json!([]))).unwrap();
        let Outbound::Hysteria2(hy) = &**plan.outbound("H").unwrap() else {
            panic!("hysteria2")
        };
        assert_eq!(hy.hop_interval, std::time::Duration::from_secs(5));
        assert!(!hy.tcp && hy.udp);

        for bad in [
            json!({"tls": {"enabled": false}}),
            json!({"obfs": {"type": "other", "password": "obfs-pass"}}),
            json!({"obfs": {"type": "salamander", "password": "x"}}),
            json!({"network": "icmp"}),
            json!({"hop_interval": "soon"}),
            json!({"server_ports": ["30:20"]}),
            json!({"brutal_debug": true}),
        ] {
            let mut server = json!({"type": "hysteria2", "tag": "H", "server": "h",
                "server_port": 443, "password": "p", "tls": {"enabled": true}});
            for (key, value) in bad.as_object().unwrap() {
                server[key] = value.clone();
            }
            let list =
                json!([server, {"type": "selector", "tag": "gorion-manual", "outbounds": ["H"]}]);
            assert!(from_config(&built(list, json!([]))).is_err(), "{bad}");
        }
    }

    #[test]
    fn reads_xhttp_placements_and_download() {
        let list = json!([
            {"type": "vless", "tag": "X", "server": "up.example.com", "server_port": 443,
             "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
             "tls": {"enabled": true, "server_name": "cdn.example.com", "alpn": ["h3"]},
             "transport": {"type": "xhttp", "path": "/up", "mode": "packet-up",
                           "uplink_http_method": "put", "session_placement": "header",
                           "seq_placement": "query", "seq_key": "n",
                           "uplink_data_placement": "cookie", "uplink_chunk_size": "100-200",
                           "x_padding_obfs_mode": true, "x_padding_placement": "header",
                           "x_padding_method": "tokenish",
                           "download_settings": {
                               "server": "dl.example.com", "server_port": 8443,
                               "tls": {"enabled": true, "server_name": "dl.example.com"},
                               "transport": {"type": "xhttp", "path": "/down",
                                             "host": "dl-front.example.com"}}}},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["X"]}
        ]);
        let plan = from_config(&built(list, json!([]))).unwrap();
        let Outbound::Vless(vless) = &**plan.outbound("X").unwrap() else {
            panic!("vless")
        };
        let Transport::Xhttp(config) = &vless.transport else {
            panic!("xhttp")
        };
        assert_eq!(config.uplink_method, "PUT");
        assert_eq!(config.session_placement, Placement::Header);
        assert_eq!(config.session_key, "X-Session");
        assert_eq!(
            (config.seq_placement, config.seq_key.as_str()),
            (Placement::Query, "n")
        );
        assert_eq!(config.data_placement, DataPlacement::Cookie);
        assert_eq!(config.data_key, "x_data");
        assert_eq!(config.uplink_chunk_size, Range::new(100, 200));
        assert_eq!(
            config.padding_obfs,
            Some(PaddingObfs {
                placement: PaddingPlacement::Header,
                key: "x_padding".into(),
                header: "X-Padding".into(),
                method: PaddingMethod::Tokenish,
            })
        );
        let download = config.download.as_ref().unwrap();
        assert_eq!(
            download.server,
            TargetAddr::Domain("dl.example.com".into(), 8443)
        );
        assert_eq!(download.xhttp.path, "/down");
        assert_eq!(download.xhttp.host, "dl-front.example.com");
        assert!(matches!(download.security, Security::Tls(_)));
        // Оба имени закрепляются до туннеля.
        assert_eq!(server_hosts(&plan), ["up.example.com", "dl.example.com"]);
    }

    #[test]
    fn reads_xhttp() {
        let list = json!([
            {"type": "vless", "tag": "X", "server": "10.0.0.2", "server_port": 443,
             "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811",
             "tls": {"enabled": true, "server_name": "cdn.example.com"},
             "transport": {"type": "xhttp", "path": "/xh?ed=1", "host": "front.example.com",
                           "mode": "packet-up", "headers": {"X-Test": "1"},
                           "x_padding_bytes": "200-400", "no_grpc_header": true,
                           "sc_max_each_post_bytes": 500000, "sc_min_posts_interval_ms": "10-20",
                           "xmux": {"max_concurrency": "16-32", "h_max_request_times": "100-200",
                                    "h_keep_alive_period": 30}}},
            {"type": "trojan", "tag": "D", "server": "10.0.0.3", "server_port": 80,
             "password": "p", "transport": {"type": "xhttp", "path": "/d"}},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["X", "D"]}
        ]);
        let plan = from_config(&built(list, json!([]))).unwrap();
        let Outbound::Vless(vless) = &**plan.outbound("X").unwrap() else {
            panic!("vless")
        };
        let Transport::Xhttp(config) = &vless.transport else {
            panic!("xhttp")
        };
        assert_eq!(config.path, "/xh?ed=1");
        assert_eq!(config.host, "front.example.com");
        assert_eq!(config.mode, xhttp::Mode::PacketUp);
        assert_eq!(config.x_padding_bytes, Range::new(200, 400));
        assert!(config.no_grpc_header);
        assert_eq!(config.sc_max_each_post_bytes, Range::new(500_000, 500_000));
        assert_eq!(config.sc_min_posts_interval_ms, Range::new(10, 20));
        assert_eq!(config.xmux.max_concurrency, Range::new(16, 32));
        assert_eq!(config.xmux.h_max_request_times, Range::new(100, 200));
        assert!(config.xmux.h_max_reusable_secs.is_zero());
        // Без настроек — значения Xray по умолчанию.
        let Outbound::Trojan(trojan) = &**plan.outbound("D").unwrap() else {
            panic!("trojan")
        };
        let Transport::Xhttp(config) = &trojan.transport else {
            panic!("xhttp")
        };
        assert_eq!(config.mode, xhttp::Mode::Auto);
        assert_eq!(config.xmux, Xmux::XRAY_DEFAULT);
        assert_eq!(config.x_padding_bytes, Range::new(100, 1000));

        // HTTP/3 и потоковые режимы поверх HTTP/1.1 — принимаются.
        for (transport, tls) in [
            (
                json!({"type": "xhttp", "path": "/"}),
                json!({"enabled": true, "alpn": ["h3"]}),
            ),
            (
                json!({"type": "xhttp", "mode": "stream-one"}),
                json!({"enabled": false}),
            ),
        ] {
            let list = json!([
                {"type": "trojan", "tag": "T", "server": "h", "server_port": 443, "password": "p",
                 "tls": tls, "transport": transport},
                {"type": "selector", "tag": "gorion-manual", "outbounds": ["T"]}
            ]);
            assert!(from_config(&built(list, json!([]))).is_ok(), "{transport}");
        }

        // Чего нет: незнакомые поля и то, что Xray сам отвергает.
        for (transport, tls) in [
            (
                json!({"type": "xhttp", "mode": "fast"}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "mode": "stream-one", "download_settings": {
                    "server": "d", "server_port": 443, "transport": {"type": "xhttp"}}}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "download_settings": {"server": "d", "server_port": 443}}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "download_settings": {"server": "d", "server_port": 443,
                    "transport": {"type": "xhttp", "download_settings": {"server": "e"}}}}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "mode": "stream-up", "uplink_data_placement": "header"}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "uplink_data_placement": "cookie"}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "mode": "stream-one", "uplink_http_method": "get"}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "session_placement": "body"}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "x_padding_obfs_mode": true, "x_padding_method": "zeros"}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "x_padding_bytes": "0-10"}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "xmux": {"max_connections": 2, "max_concurrency": 4}}),
                json!({"enabled": true}),
            ),
            (
                json!({"type": "xhttp", "xmux": {"other": 1}}),
                json!({"enabled": true}),
            ),
        ] {
            let list = json!([
                {"type": "trojan", "tag": "T", "server": "h", "server_port": 443, "password": "p",
                 "tls": tls, "transport": transport},
                {"type": "selector", "tag": "gorion-manual", "outbounds": ["T"]}
            ]);
            assert!(from_config(&built(list, json!([]))).is_err(), "{transport}");
        }
        let list = json!([
            {"type": "vless", "tag": "V", "server": "h", "server_port": 443,
             "uuid": "b831381d-6324-4d53-ad4f-8cda48b30811", "flow": "xtls-rprx-vision",
             "tls": {"enabled": true}, "transport": {"type": "xhttp"}},
            {"type": "selector", "tag": "gorion-manual", "outbounds": ["V"]}
        ]);
        assert!(from_config(&built(list, json!([]))).is_err());
    }

    #[test]
    fn refuses_what_the_engine_cannot_do() {
        let rules = json!([{"domain_suffix": [".ru"], "outbound": "direct"}]);
        assert!(from_config(&built(servers(), rules)).is_err());

        let mut list = servers();
        list[0]["transport"] = json!({"type": "ws", "path": "/"});
        assert!(from_config(&built(list, json!([]))).is_err());

        let mut list = servers();
        list[1] = json!({"type": "hysteria2", "tag": "S", "server": "h", "server_port": 1});
        let error = from_config(&built(list, json!([]))).unwrap_err();
        assert!(error.to_string().contains("server #2"), "{error}");

        // Настройки TLS, которых движок не умеет: ECH, только TLS 1.2.
        let mut list = servers();
        list[0]["tls"]["reality"] = json!({"enabled": false});
        list[0]["tls"]["ech"] = json!({"enabled": true});
        assert!(from_config(&built(list, json!([]))).is_err());
        let mut list = servers();
        list[0]["tls"]["max_version"] = json!("1.2");
        assert!(from_config(&built(list, json!([]))).is_err());

        // Vision без TLS sing-box не примет — и движок тоже.
        let mut list = servers();
        list[0]["tls"] = json!({"enabled": false});
        assert!(from_config(&built(list, json!([]))).is_err());

        let mut config = built(servers(), json!([]));
        config["inbounds"] = json!([{"type": "tun", "tag": "gorion-tun"}]);
        assert!(from_config(&config).is_err());
    }

    /// Конфигурация режима TUN, как её строит ядро Gorion.
    fn built_tun() -> Value {
        let mut config = built(
            servers(),
            json!([
                {"inbound": "gorion-tun", "action": "sniff"},
                {"inbound": "gorion-tun", "protocol": "dns", "action": "hijack-dns"}
            ]),
        );
        config["inbounds"] = json!([
            {"type": "mixed", "tag": "gorion-mixed", "listen": "127.0.0.1", "listen_port": 2080},
            {"type": "tun", "tag": "gorion-tun", "interface_name": "",
             "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
             "auto_route": true, "strict_route": true, "stack": "system"}
        ]);
        config["dns"] = json!({
            "servers": [
                {"type": "local", "tag": "gorion-bootstrap"},
                {"type": "https", "tag": "gorion-dns", "server": "1.1.1.1",
                 "tls": {"enabled": true, "server_name": "cloudflare-dns.com"},
                 "detour": "gorion-manual"}
            ],
            "final": "gorion-dns"
        });
        config["route"]["default_domain_resolver"] = json!("gorion-bootstrap");
        config
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn reads_the_tun_config_gorion_builds() {
        let plan = from_config(&built_tun()).unwrap();
        let tun = plan.tun.as_ref().unwrap();
        assert_eq!(tun.inet4, Some(("172.19.0.1".parse().unwrap(), 30)));
        assert_eq!(tun.inet6, Some(("fdfe:dcba:9876::1".parse().unwrap(), 126)));
        assert!(tun.auto_route);
        assert_eq!(tun.mtu, DEFAULT_MTU);
        assert_eq!(
            tun.dns,
            DohServer {
                address: "1.1.1.1:443".parse().unwrap(),
                server_name: "cloudflare-dns.com".into(),
                path: "/dns-query".into(),
            }
        );
        assert_eq!(plan.listen.port(), 2080);
        // Имя сервера разрешается заранее, IP — нет.
        assert_eq!(server_hosts(&plan), ["example.com"]);
    }

    #[test]
    fn tun_with_anything_else_is_refused() {
        // Правило раздельного туннелирования поверх управляемых.
        let mut config = built_tun();
        config["route"]["rules"]
            .as_array_mut()
            .unwrap()
            .push(json!({"domain_suffix": [".ru"], "outbound": "direct"}));
        assert!(from_config(&config).is_err());
        // DNS из шаблона подписки.
        let mut config = built_tun();
        config["dns"] = json!({"servers": [{"type": "udp", "tag": "x", "server": "8.8.8.8"}]});
        assert!(from_config(&config).is_err());
        // DNS-сервер по имени, мимо селектора, другой стек.
        let mut config = built_tun();
        config["dns"]["servers"][1]["server"] = json!("dns.example");
        assert!(from_config(&config).is_err());
        let mut config = built_tun();
        config["dns"]["servers"][1]["detour"] = json!("direct");
        assert!(from_config(&config).is_err());
        let mut config = built_tun();
        config["inbounds"][1]["stack"] = json!("gvisor");
        assert!(from_config(&config).is_err());
        let mut config = built_tun();
        config["inbounds"][1]["include_package"] = json!(["x"]);
        assert!(from_config(&config).is_err());
        // TUN без DNS-раздела.
        let mut config = built_tun();
        config.as_object_mut().unwrap().remove("dns");
        assert!(from_config(&config).is_err());
        // Управляемые правила без TUN — это уже чужие правила.
        let mut config = built_tun();
        config["inbounds"] = json!([config["inbounds"][0].clone()]);
        assert!(from_config(&config).is_err());
    }
}
