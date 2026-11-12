//! Шаблон подписки → рабочая конфигурация sing-box.
//! Эталон: `lib/features/runtime/data/singbox_config_builder.dart`.

use serde_json::{Map, Value, json};

use crate::candidates::extract_candidates;
use crate::error::{CoreError, CoreResult};
use crate::json_util::{clone_list, clone_map, objects_to_values};
use crate::runtime::RuntimeMode;

pub const MANAGED_MANUAL_SELECTOR_TAG: &str = "gorion-manual";
pub const MANAGED_AUTO_URLTEST_TAG: &str = "gorion-auto";
pub const MANAGED_MIXED_INBOUND_TAG: &str = "gorion-mixed";
pub const MANAGED_TUN_INBOUND_TAG: &str = "gorion-tun";

/// macOS сама назначает имя `utun*`; на остальных ОС — фиксированное.
pub const MANAGED_TUN_INTERFACE_NAME: &str = if cfg!(target_os = "macos") {
    ""
} else {
    "gorion-tun"
};

#[derive(Debug, Clone)]
pub struct BuildRequest<'a> {
    pub template_config: &'a str,
    pub mode: RuntimeMode,
    pub mixed_port: u16,
    pub controller_port: u16,
    pub controller_secret: &'a str,
    pub url_test_url: &'a str,
    pub selected_server_tag: Option<&'a str>,
    pub selectable_tags_override: Option<&'a [String]>,
    /// Готовые правила раздельного туннелирования (`rule_set`, `rules`).
    pub split_tunnel: Option<SplitTunnelRoute>,
}

/// Управляемые правила маршрутизации, которые ставятся перед правилами шаблона.
#[derive(Debug, Clone, Default)]
pub struct SplitTunnelRoute {
    pub rule_sets: Vec<Map<String, Value>>,
    pub rules: Vec<Map<String, Value>>,
}

pub const MANAGED_SPLIT_TUNNEL_PREFIX: &str = "gorion-split";

#[derive(Debug, Clone, PartialEq)]
pub struct BuiltConfig {
    pub config_json: String,
    pub manual_selector_tag: String,
    pub auto_group_tag: String,
}

pub fn build(request: &BuildRequest<'_>) -> CoreResult<BuiltConfig> {
    let Ok(Value::Object(mut config)) = serde_json::from_str::<Value>(request.template_config)
    else {
        return Err(CoreError::InvalidTemplate(
            "сохранённая конфигурация подписки — не JSON-объект".into(),
        ));
    };
    let extracted: Vec<String> = extract_candidates(&Value::Object(config.clone()))
        .into_iter()
        .map(|c| c.tag)
        .collect();
    if extracted.is_empty() {
        return Err(CoreError::NoSelectableServers);
    }
    let selectable: Vec<String> = match request.selectable_tags_override {
        None => extracted,
        Some(tags) => tags
            .iter()
            .filter(|t| extracted.contains(t))
            .cloned()
            .collect(),
    };
    let Some(first) = selectable.first() else {
        return Err(CoreError::NoSelectableServers);
    };
    let selected = request
        .selected_server_tag
        .filter(|tag| selectable.iter().any(|t| t == tag))
        .unwrap_or(first)
        .to_owned();

    let mut outbounds = clone_list(config.get("outbounds"));
    outbounds.retain(|o| {
        let tag = o.get("tag").and_then(Value::as_str);
        tag != Some(MANAGED_MANUAL_SELECTOR_TAG) && tag != Some(MANAGED_AUTO_URLTEST_TAG)
    });
    if !outbounds
        .iter()
        .any(|o| o.get("tag").and_then(Value::as_str) == Some("direct"))
    {
        outbounds.push(object(json!({"type": "direct", "tag": "direct"})));
    }
    outbounds.push(object(json!({
        "type": "selector",
        "tag": MANAGED_MANUAL_SELECTOR_TAG,
        "outbounds": selectable,
        "default": selected,
        "interrupt_exist_connections": true,
    })));
    outbounds.push(object(json!({
        "type": "urltest",
        "tag": MANAGED_AUTO_URLTEST_TAG,
        "outbounds": selectable,
        "url": request.url_test_url,
        "interval": "5m",
        "tolerance": 50,
        "interrupt_exist_connections": false,
    })));
    config.insert("outbounds".into(), objects_to_values(outbounds));
    config.insert(
        "inbounds".into(),
        build_inbounds(request.mode, request.mixed_port),
    );

    let mut route = clone_map(config.get("route"));
    route.insert("auto_detect_interface".into(), json!(true));
    route.insert("final".into(), json!(MANAGED_MANUAL_SELECTOR_TAG));
    if let Some(split) = &request.split_tunnel {
        apply_split_tunnel(&mut route, split);
    }
    if request.mode.uses_tun() {
        let mut rules = vec![
            object(json!({"inbound": MANAGED_TUN_INBOUND_TAG, "action": "sniff"})),
            object(
                json!({"inbound": MANAGED_TUN_INBOUND_TAG, "protocol": "dns", "action": "hijack-dns"}),
            ),
        ];
        rules.extend(clone_list(route.get("rules")));
        route.insert("rules".into(), objects_to_values(rules));
        if clone_map(config.get("dns")).is_empty() {
            // Имена VPN-серверов резолвятся вне туннеля (иначе замкнутый
            // круг), а DNS клиентов идёт через выбранный сервер.
            config.insert(
                "dns".into(),
                json!({
                    "servers": [
                        {"type": "local", "tag": "gorion-bootstrap"},
                        {
                            "type": "https",
                            "tag": "gorion-dns",
                            "server": "1.1.1.1",
                            "tls": {"enabled": true, "server_name": "cloudflare-dns.com"},
                            "detour": MANAGED_MANUAL_SELECTOR_TAG,
                        },
                    ],
                    "final": "gorion-dns",
                }),
            );
            route
                .entry("default_domain_resolver")
                .or_insert(json!("gorion-bootstrap"));
        }
    }
    config.insert("route".into(), Value::Object(route));

    sanitize_untrusted_sections(&mut config);
    if request.mode.uses_tun() {
        strip_local_file_references(&mut config);
    }
    let mut experimental = clone_map(config.get("experimental"));
    experimental.insert(
        "clash_api".into(),
        json!({
            "external_controller": format!("127.0.0.1:{}", request.controller_port),
            "secret": request.controller_secret,
            "default_mode": "Rule",
            "access_control_allow_origin": ["*"],
        }),
    );
    config.insert("experimental".into(), Value::Object(experimental));

    let config_json = serde_json::to_string_pretty(&Value::Object(config))
        .map_err(|e| CoreError::Internal(e.to_string()))?;
    Ok(BuiltConfig {
        config_json,
        manual_selector_tag: MANAGED_MANUAL_SELECTOR_TAG.into(),
        auto_group_tag: MANAGED_AUTO_URLTEST_TAG.into(),
    })
}

/// Шаблон приходит из сети и не должен заставлять ядро писать файлы или
/// открывать лишние порты. В режиме TUN ядро работает от root — путь в
/// шаблоне означал бы запись файла от root.
fn sanitize_untrusted_sections(config: &mut Map<String, Value>) {
    // `log.output` перенаправляет журнал в произвольный файл.
    let template_log = clone_map(config.get("log"));
    let mut log = Map::new();
    log.insert(
        "level".into(),
        template_log.get("level").cloned().unwrap_or(json!("info")),
    );
    for key in ["timestamp", "disabled"] {
        if let Some(value) = template_log.get(key).filter(|v| v.is_boolean()) {
            log.insert(key.into(), value.clone());
        }
    }
    config.insert("log".into(), Value::Object(log));

    // `cache_file.path` — ещё одна цель записи, `v2ray_api` и `debug`
    // открывают порты. Остаются только флаги поведения кэша.
    let template_cache = clone_map(clone_map(config.get("experimental")).get("cache_file"));
    let mut experimental = Map::new();
    if template_cache.get("enabled") == Some(&json!(true)) {
        let allowed = ["enabled", "store_fakeip", "store_rdrc", "rdrc_timeout"];
        let cache: Map<String, Value> = template_cache
            .into_iter()
            .filter(|(key, _)| allowed.contains(&key.as_str()))
            .collect();
        experimental.insert("cache_file".into(), Value::Object(cache));
    }
    config.insert("experimental".into(), Value::Object(experimental));

    // Серверные компоненты (DERP, SSM API, resolved) клиенту не нужны.
    config.shift_remove("services");
}

fn apply_split_tunnel(route: &mut Map<String, Value>, split: &SplitTunnelRoute) {
    if split.rule_sets.is_empty() || split.rules.is_empty() {
        return;
    }
    let mut existing_sets = clone_list(route.get("rule_set"));
    existing_sets.retain(|set| {
        !set.get("tag")
            .and_then(Value::as_str)
            .is_some_and(|tag| tag.starts_with(MANAGED_SPLIT_TUNNEL_PREFIX))
    });
    let mut rule_sets = split.rule_sets.clone();
    rule_sets.extend(existing_sets);
    route.insert("rule_set".into(), objects_to_values(rule_sets));
    let mut rules = split.rules.clone();
    rules.extend(clone_list(route.get("rules")));
    route.insert("rules".into(), objects_to_values(rules));
}

fn build_inbounds(mode: RuntimeMode, mixed_port: u16) -> Value {
    let mut inbounds = vec![json!({
        "type": "mixed",
        "tag": MANAGED_MIXED_INBOUND_TAG,
        "listen": "127.0.0.1",
        "listen_port": mixed_port,
    })];
    if mode.uses_tun() {
        inbounds.push(json!({
            "type": "tun",
            "tag": MANAGED_TUN_INBOUND_TAG,
            "interface_name": MANAGED_TUN_INTERFACE_NAME,
            "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
            "auto_route": true,
            "strict_route": true,
            "stack": "system",
        }));
    }
    Value::Array(inbounds)
}

/// В режиме TUN ядро работает от root через помощника: ни один ключ
/// шаблона не должен указывать ему на локальный файл (сертификаты, ключи,
/// локальные rule-set). Правила, которые ссылались только на вырезанные
/// rule-set, уходят вместе с ними — иначе `sing-box check` не пройдёт.
fn strip_local_file_references(config: &mut Map<String, Value>) {
    strip_path_keys(config);
    let mut removed = Vec::new();
    if let Some(Value::Object(route)) = config.get_mut("route")
        && let Some(Value::Array(sets)) = route.get_mut("rule_set")
    {
        sets.retain(|set| {
            let local = set.get("type").and_then(Value::as_str) == Some("local");
            if local && let Some(tag) = set.get("tag").and_then(Value::as_str) {
                removed.push(tag.to_owned());
            }
            !local
        });
    }
    if removed.is_empty() {
        return;
    }
    for section in ["route", "dns"] {
        if let Some(Value::Object(map)) = config.get_mut(section)
            && let Some(Value::Array(rules)) = map.get_mut("rules")
        {
            rules.retain_mut(|rule| keep_rule_without(rule, &removed));
        }
    }
}

fn strip_path_keys(map: &mut Map<String, Value>) {
    map.retain(|key, _| !key.ends_with("_path"));
    for value in map.values_mut() {
        match value {
            Value::Object(inner) => strip_path_keys(inner),
            Value::Array(items) => {
                for item in items {
                    if let Value::Object(inner) = item {
                        strip_path_keys(inner);
                    }
                }
            }
            _ => {}
        }
    }
}

/// Убирает из правила ссылки на вырезанные rule-set; `false` — правило
/// опустело и должно уйти.
fn keep_rule_without(rule: &mut Value, removed: &[String]) -> bool {
    let Value::Object(map) = rule else {
        return true;
    };
    let Some(sets) = map.get_mut("rule_set") else {
        // Логические правила (`type: logical`) содержат вложенные.
        if let Some(Value::Array(inner)) = map.get_mut("rules") {
            inner.retain_mut(|r| keep_rule_without(r, removed));
            return !inner.is_empty();
        }
        return true;
    };
    match sets {
        Value::String(tag) => !removed.contains(tag),
        Value::Array(tags) => {
            tags.retain(|t| t.as_str().is_none_or(|t| !removed.iter().any(|r| r == t)));
            !tags.is_empty()
        }
        _ => true,
    }
}

fn object(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(map) => map,
        _ => Map::new(),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;

    fn build_for(mode: RuntimeMode, template: &str) -> Value {
        let built = build(&BuildRequest {
            template_config: template,
            mode,
            mixed_port: 2080,
            controller_port: 9090,
            controller_secret: "s",
            url_test_url: "https://example.com/",
            selected_server_tag: None,
            selectable_tags_override: None,
            split_tunnel: None,
        })
        .unwrap();
        serde_json::from_str(&built.config_json).unwrap()
    }

    const TEMPLATE: &str = r#"{
      "outbounds": [{"type": "trojan", "tag": "A", "server": "1.2.3.4", "server_port": 443,
        "password": "x", "tls": {"enabled": true, "certificate_path": "/etc/master.passwd"}}],
      "route": {
        "rule_set": [
          {"type": "local", "tag": "secret", "format": "binary", "path": "/var/root/x.srs"},
          {"type": "remote", "tag": "ads", "format": "binary", "url": "https://example.com/ads.srs"}
        ],
        "rules": [
          {"rule_set": "secret", "outbound": "direct"},
          {"rule_set": ["secret", "ads"], "action": "reject"},
          {"type": "logical", "mode": "and", "rules": [{"rule_set": "secret"}], "outbound": "direct"},
          {"domain_suffix": ["example.org"], "outbound": "direct"}
        ]
      }
    }"#;

    #[test]
    fn tun_strips_local_files_for_root() {
        let config = build_for(RuntimeMode::Tun, TEMPLATE);
        let text = config.to_string();
        assert!(!text.contains("certificate_path"), "{text}");
        assert!(!text.contains("/var/root"), "{text}");
        let sets = config["route"]["rule_set"].as_array().unwrap();
        assert_eq!(sets.len(), 1);
        assert_eq!(sets[0]["tag"], "ads");
        let rules = config["route"]["rules"].as_array().unwrap();
        // sniff + hijack-dns + правило с «ads» + правило по домену.
        assert_eq!(rules.len(), 4, "{rules:?}");
        assert_eq!(rules[2]["rule_set"], serde_json::json!(["ads"]));
    }

    #[test]
    fn proxy_modes_keep_template_files() {
        let config = build_for(RuntimeMode::Mixed, TEMPLATE);
        assert_eq!(config["route"]["rule_set"].as_array().unwrap().len(), 2);
        assert!(config.to_string().contains("certificate_path"));
    }
}
