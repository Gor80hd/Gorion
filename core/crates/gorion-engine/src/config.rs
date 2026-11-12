//! Настройки движка — та же конфигурация sing-box, что строит ядро Gorion,
//! но только понятное движку подмножество: один вход `mixed`, селектор
//! серверов без правил маршрутизации, протоколы, которые движок умеет.
//! Всё остальное — ошибка `Unsupported`, и ядро запускает sing-box.

use std::net::SocketAddr;
use std::sync::Arc;

use base64::Engine as _;
use serde_json::{Map, Value};

use crate::address::TargetAddr;
use crate::error::{EngineError, Result};
use crate::outbound::Outbound;
use crate::reality::RealityConfig;
use crate::shadowsocks::{Method, ShadowsocksConfig};
use crate::vless::{Flow, Security, VlessConfig};

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

pub fn from_singbox(config: &Value) -> Result<Plan> {
    let config = config
        .as_object()
        .ok_or_else(|| unsupported("config is not an object"))?;

    let inbounds = config
        .get("inbounds")
        .and_then(Value::as_array)
        .ok_or_else(|| unsupported("no inbounds"))?;
    let [inbound] = inbounds.as_slice() else {
        return Err(unsupported("exactly one inbound is supported"));
    };
    let inbound = inbound
        .as_object()
        .ok_or_else(|| unsupported("bad inbound"))?;
    if str_field(inbound, "type") != Some("mixed") {
        return Err(unsupported("only a mixed inbound is supported"));
    }
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
    // движок пока не исполняет.
    if non_empty(route.get("rules")) || non_empty(route.get("rule_set")) {
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

    Ok(Plan {
        listen,
        controller,
        selector_tag: final_tag,
        members,
        selected,
        outbounds: translated,
    })
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
    if non_empty(outbound.get("transport")) {
        return Err(unsupported("transport"));
    }
    Ok(())
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
            let method = Method::parse(str_field(outbound, "method").unwrap_or_default())
                .map_err(|_| unsupported("shadowsocks method"))?;
            let password = str_field(outbound, "password").unwrap_or_default();
            Ok(Outbound::Shadowsocks(ShadowsocksConfig::new(
                server(outbound)?,
                method,
                password,
            )))
        }
        Some("vless") => {
            check_common(outbound)?;
            let uuid = str_field(outbound, "uuid").ok_or_else(|| unsupported("vless uuid"))?;
            let flow = Flow::parse(str_field(outbound, "flow").unwrap_or_default())
                .map_err(|_| unsupported("vless flow"))?;
            let tls = outbound
                .get("tls")
                .and_then(Value::as_object)
                .filter(|tls| tls.get("enabled").and_then(Value::as_bool).unwrap_or(false));
            let mut alpn = None;
            let security = match tls {
                None => Security::None,
                Some(tls) => {
                    if !is_enabled(tls, "reality") {
                        return Err(unsupported("vless tls without reality"));
                    }
                    let reality = tls
                        .get("reality")
                        .and_then(Value::as_object)
                        .ok_or_else(|| unsupported("reality"))?;
                    let key = str_field(reality, "public_key")
                        .ok_or_else(|| unsupported("reality public_key"))?;
                    let key = base64::engine::general_purpose::URL_SAFE_NO_PAD
                        .decode(key.trim_end_matches('='))
                        .ok()
                        .and_then(|k| <[u8; 32]>::try_from(k).ok())
                        .ok_or_else(|| unsupported("reality public_key"))?;
                    let server_name = str_field(tls, "server_name")
                        .ok_or_else(|| unsupported("reality server_name"))?;
                    alpn = tls.get("alpn").and_then(Value::as_array).map(|items| {
                        items
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_owned)
                            .collect::<Vec<_>>()
                    });
                    Security::Reality(
                        RealityConfig::new(
                            server_name,
                            key,
                            str_field(reality, "short_id").unwrap_or_default(),
                        )
                        .map_err(|_| unsupported("reality short_id"))?,
                    )
                }
            };
            let mut config = VlessConfig::new(server(outbound)?, uuid, flow, security);
            if let Some(alpn) = alpn.filter(|a| !a.is_empty()) {
                config.alpn = alpn;
            }
            Ok(Outbound::Vless(Box::new(config)))
        }
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
        let plan = from_singbox(&built(servers(), json!([]))).unwrap();
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
    fn refuses_what_the_engine_cannot_do() {
        let rules = json!([{"domain_suffix": [".ru"], "outbound": "direct"}]);
        assert!(from_singbox(&built(servers(), rules)).is_err());

        let mut list = servers();
        list[0]["transport"] = json!({"type": "ws", "path": "/"});
        assert!(from_singbox(&built(list, json!([]))).is_err());

        let mut list = servers();
        list[1] = json!({"type": "hysteria2", "tag": "S", "server": "h", "server_port": 1});
        let error = from_singbox(&built(list, json!([]))).unwrap_err();
        assert!(error.to_string().contains("server #2"), "{error}");

        let mut list = servers();
        list[0]["tls"]["reality"] = json!({"enabled": false});
        assert!(from_singbox(&built(list, json!([]))).is_err());

        let mut config = built(servers(), json!([]));
        config["inbounds"] = json!([{"type": "tun", "tag": "gorion-tun"}]);
        assert!(from_singbox(&config).is_err());
    }
}
