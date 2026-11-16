//! Сверка с золотыми фикстурами Flutter-эталона (`dart run tool/export_golden.dart`).

#![allow(clippy::unwrap_used)]

use std::collections::HashMap;
use std::path::PathBuf;

use gorion_core::config_builder::{BuildRequest, build};
use gorion_core::display::{extract_country_code, normalize_server_display_text};
use gorion_core::parser::{Headers, parse_subscription};
use gorion_core::runtime::RuntimeMode;
use serde_json::Value;
use url::Url;

fn fixture(name: &str) -> Vec<Value> {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../fixtures")
        .join(name);
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str::<Value>(&text)
        .unwrap()
        .as_array()
        .unwrap()
        .clone()
}

/// Осознанные отличия от эталона (см. parity.md, «Δ»): имя сервера из
/// %-кодированного фрагмента теперь декодируется.
fn apply_known_deltas(case: &str, expected: &mut Value) {
    let renamed: HashMap<&str, (&str, &str)> = HashMap::from([
        (
            "link_vless_reality_vision",
            ("🇳🇱 NL Amsterdam", "🇳🇱 NL Amsterdam"),
        ),
        ("link_trojan_basic", ("Trojan Server", "Trojan Server")),
    ]);
    let Some((tag, display)) = renamed.get(case) else {
        return;
    };
    let ok = expected.get_mut("ok").unwrap();
    ok["servers"][0]["tag"] = Value::from(*tag);
    ok["servers"][0]["displayName"] = Value::from(*display);
    ok["config"]["outbounds"][0]["tag"] = Value::from(*tag);
    if ok["name"] == "sub" {
        return;
    }
    ok["name"] = Value::from(*display);
}

/// Эталон отказывает, а ядро переводит (Δ в parity.md): XHTTP есть в своём
/// движке. Ожидаемый транспорт вместо ошибки.
fn now_supported(case: &str) -> Option<Value> {
    match case {
        "link_vless_xhttp_rejected" => Some(serde_json::json!({"type": "xhttp", "path": "/x"})),
        _ => None,
    }
}

#[test]
fn parser_matches_reference() {
    let mut failures = Vec::new();
    for case in fixture("parser.json") {
        let name = case["name"].as_str().unwrap();
        let input = case["input"].as_str().unwrap();
        let url = Url::parse(
            case.get("url")
                .and_then(Value::as_str)
                .unwrap_or("https://sub.example.com/sub"),
        )
        .unwrap();
        let headers: Headers = case
            .get("headers")
            .and_then(Value::as_object)
            .map(|h| {
                h.iter()
                    .map(|(k, v)| (k.clone(), v.as_str().unwrap().to_owned()))
                    .collect()
            })
            .unwrap_or_default();
        let mut expected = case.clone();
        apply_known_deltas(name, &mut expected);
        match (
            parse_subscription(input, &url, &headers),
            expected.get("ok"),
        ) {
            (Ok(parsed), Some(ok)) => {
                let config: Value = serde_json::from_str(&parsed.normalized_config_json).unwrap();
                if config != ok["config"] {
                    failures.push(format!(
                        "{name}: config\n  got  {config}\n  want {}",
                        ok["config"]
                    ));
                }
                let servers = serde_json::to_value(&parsed.servers).unwrap();
                if servers != ok["servers"] {
                    failures.push(format!(
                        "{name}: servers\n  got  {servers}\n  want {}",
                        ok["servers"]
                    ));
                }
                if parsed.name != ok["name"].as_str().unwrap() {
                    failures.push(format!(
                        "{name}: name got {:?} want {}",
                        parsed.name, ok["name"]
                    ));
                }
                let info = parsed.subscription_info.as_ref();
                let want_info = &ok["subscriptionInfo"];
                match (info, want_info.is_null()) {
                    (None, true) => {}
                    (Some(info), false) => {
                        let expire = info
                            .expire_at
                            .as_deref()
                            .map(|e| chrono::DateTime::parse_from_rfc3339(e).unwrap().timestamp());
                        if info.upload != want_info["upload"].as_i64().unwrap()
                            || info.total != want_info["total"].as_i64().unwrap()
                            || expire != want_info["expireAtEpochSeconds"].as_i64()
                            || info.support_url.as_deref() != want_info["supportUrl"].as_str()
                        {
                            failures
                                .push(format!("{name}: subscription info {info:?} vs {want_info}"));
                        }
                    }
                    _ => failures.push(format!("{name}: subscription info presence differs")),
                }
            }
            (Err(error), None) => {
                let _ = error; // Оба отказали — достаточно; тексты различаются намеренно.
            }
            (Ok(parsed), None) if now_supported(name).is_some() => {
                let config: Value = serde_json::from_str(&parsed.normalized_config_json).unwrap();
                if Some(&config["outbounds"][0]["transport"]) != now_supported(name).as_ref() {
                    failures.push(format!("{name}: transport {config}"));
                }
            }
            (Ok(parsed), None) => failures.push(format!(
                "{name}: expected error {}, got {parsed:?}",
                case["error"]
            )),
            (Err(error), Some(_)) => failures.push(format!("{name}: unexpected error {error}")),
        }
    }
    assert!(
        failures.is_empty(),
        "{} расхождений:\n{}",
        failures.len(),
        failures.join("\n")
    );
}

#[test]
fn display_names_match_reference() {
    for case in fixture("display.json") {
        let input = case["input"].as_str().unwrap();
        assert_eq!(
            normalize_server_display_text(input, true),
            case["normalized"].as_str().unwrap(),
            "{input}"
        );
        assert_eq!(
            extract_country_code(input).as_deref(),
            case["countryCode"].as_str(),
            "{input}"
        );
    }
}

#[test]
fn config_builder_matches_reference() {
    for case in fixture("config_builder.json") {
        let template = case["template"].to_string();
        let selected = case["selected"].as_str();
        let built = build(&BuildRequest {
            template_config: &template,
            mode: RuntimeMode::from_name(case["mode"].as_str().unwrap()).unwrap(),
            mixed_port: 2080,
            controller_port: 9090,
            controller_secret: "secret",
            url_test_url: "https://www.gstatic.com/generate_204",
            selected_server_tag: selected,
            selectable_tags_override: None,
            split_tunnel: None,
        })
        .unwrap();
        let got: Value = serde_json::from_str(&built.config_json).unwrap();
        assert_eq!(got, case["output"], "{}", case["name"]);
    }
}
