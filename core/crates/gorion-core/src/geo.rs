//! Где на планете сервер и пользователь.
//! Эталон: `lib/features/home/utils/map_location_resolver.dart`,
//! `lib/features/home/utils/globe_country_codes.dart`.

use std::sync::LazyLock;

use regex::Regex;

use crate::display::{extract_country_code, sanitize_server_display_text};
use crate::geo_data::{
    COUNTRY_CODE_ALIASES, COUNTRY_LAT_LON, DEFAULT_MAP_FALLBACK, DEFAULT_SOURCE_FALLBACK,
    GLOBE_COUNTRY_CODES, LOCATION_KEYWORDS,
};
use crate::ipinfo::IpInfo;

/// Широта и долгота в градусах.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct GeoPoint {
    pub lat: f64,
    pub lon: f64,
}

impl From<(f64, f64)> for GeoPoint {
    fn from((lat, lon): (f64, f64)) -> Self {
        Self { lat, lon }
    }
}

pub const MAP_FALLBACK: GeoPoint = GeoPoint {
    lat: DEFAULT_MAP_FALLBACK.0,
    lon: DEFAULT_MAP_FALLBACK.1,
};
pub const SOURCE_FALLBACK: GeoPoint = GeoPoint {
    lat: DEFAULT_SOURCE_FALLBACK.0,
    lon: DEFAULT_SOURCE_FALLBACK.1,
};

/// Коды стран карты планеты по порядку индексов (индекс пикселя − 1).
pub fn globe_country_codes() -> &'static [&'static str] {
    GLOBE_COUNTRY_CODES
}

/// Код ISO, если для страны известны координаты (с учётом синонимов EL, UK).
pub fn normalize_country_code(code: &str) -> Option<String> {
    let upper = code.trim().to_uppercase();
    if upper.chars().count() != 2 {
        return None;
    }
    let resolved = COUNTRY_CODE_ALIASES
        .iter()
        .find(|(alias, _)| *alias == upper)
        .map_or(upper.as_str(), |(_, target)| target);
    COUNTRY_LAT_LON
        .iter()
        .any(|(c, _)| *c == resolved)
        .then(|| resolved.to_owned())
}

pub fn country_location(code: &str) -> Option<GeoPoint> {
    let code = normalize_country_code(code)?;
    COUNTRY_LAT_LON
        .iter()
        .find(|(c, _)| *c == code)
        .map(|(_, p)| GeoPoint::from(*p))
}

static LOOSE_CODE: LazyLock<Regex> = LazyLock::new(|| {
    // `\b` эталона (Dart) — граница по ASCII.
    Regex::new(r"\[([A-Za-z]{2})\]|(?-u:\b)([A-Za-z]{2})(?-u:\b)").expect("регулярка задана в коде")
});
static LOCATION_SEPARATORS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"[_\-|/:,;()\[\]{}.]+").expect("регулярка задана в коде"));
static SPACES: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s+").expect("регулярка задана в коде"));

/// Страна сервера для карты: код в начале имени, флаг, затем любой
/// двухбуквенный токен. Первый найденный токен решает, как в эталоне.
pub fn extract_mappable_country_code(value: &str) -> Option<String> {
    if let Some(code) = extract_country_code(value).and_then(|c| normalize_country_code(&c)) {
        return Some(code);
    }
    if let Some(code) = flag_country_code(value) {
        return Some(code);
    }
    let caps = LOOSE_CODE.captures(value)?;
    let token = caps.get(1).or_else(|| caps.get(2))?;
    normalize_country_code(token.as_str())
}

fn flag_country_code(value: &str) -> Option<String> {
    let chars: Vec<char> = value.chars().collect();
    let indicator = |c: char| ('\u{1F1E6}'..='\u{1F1FF}').contains(&c);
    chars.windows(2).find_map(|pair| {
        if !indicator(pair[0]) || !indicator(pair[1]) {
            return None;
        }
        let code: String = pair
            .iter()
            .map(|c| char::from(b'A' + (*c as u32 - 0x1F1E6) as u8))
            .collect();
        normalize_country_code(&code)
    })
}

fn normalize_location_text(value: &str) -> String {
    let lower = value.to_lowercase();
    let spaced = LOCATION_SEPARATORS.replace_all(&lower, " ");
    SPACES.replace_all(&spaced, " ").trim().to_owned()
}

/// Самое длинное ключевое слово места, встретившееся в тексте целиком.
pub fn location_from_text(value: &str) -> Option<GeoPoint> {
    let normalized = normalize_location_text(value);
    if normalized.is_empty() {
        return None;
    }
    let haystack = format!(" {normalized} ");
    let mut best: Option<(usize, GeoPoint)> = None;
    for (key, point) in LOCATION_KEYWORDS {
        if haystack.contains(&format!(" {key} ")) {
            let len = key.chars().count();
            if best.is_none_or(|(l, _)| len > l) {
                best = Some((len, GeoPoint::from(*point)));
            }
        }
    }
    best.map(|(_, p)| p)
}

/// Точка назначения на планете: по имени сервера, иначе по стране выхода.
pub fn resolve_destination(server_name: Option<&str>, routed_country: Option<&str>) -> GeoPoint {
    let routed = routed_country.and_then(country_location);
    let Some(name) = server_name else {
        return routed.unwrap_or(MAP_FALLBACK);
    };
    if let Some(point) = location_from_text(name) {
        return point;
    }
    if let Some(code) = extract_mappable_country_code(name) {
        return country_location(&code).unwrap_or(MAP_FALLBACK);
    }
    if let Some(point) = routed {
        return point;
    }
    location_from_text(&sanitize_server_display_text(name, true)).unwrap_or(MAP_FALLBACK)
}

/// Откуда идёт трафик: город или страна из данных IP.
pub fn resolve_source(ip: Option<&IpInfo>) -> GeoPoint {
    let Some(ip) = ip else {
        return SOURCE_FALLBACK;
    };
    let parts: Vec<&str> = [
        ip.city.as_deref(),
        ip.region.as_deref(),
        ip.country.as_deref(),
        Some(ip.country_code.as_str()),
    ]
    .into_iter()
    .flatten()
    .collect();
    if let Some(point) = location_from_text(&parts.join(", ")) {
        return point;
    }
    country_location(&ip.country_code).unwrap_or(SOURCE_FALLBACK)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mappable_code_prefers_prefix_then_flag_then_token() {
        assert_eq!(
            extract_mappable_country_code("DE Frankfurt").as_deref(),
            Some("DE")
        );
        assert_eq!(
            extract_mappable_country_code("Fast \u{1F1F3}\u{1F1F1} node").as_deref(),
            Some("NL")
        );
        assert_eq!(
            extract_mappable_country_code("Server [fi] 2").as_deref(),
            Some("FI")
        );
        assert_eq!(
            extract_mappable_country_code("node uk-1").as_deref(),
            Some("GB")
        );
        // Первый двухбуквенный токен неизвестен — дальше не ищем.
        assert_eq!(extract_mappable_country_code("xx de"), None);
    }

    #[test]
    fn keywords_pick_longest_match() {
        let spb = location_from_text("RU | Saint Petersburg #3").expect("город");
        assert!((spb.lat - 59.9343).abs() < 1e-6);
        let moscow = location_from_text("москва-1").expect("город");
        assert!((moscow.lon - 37.6173).abs() < 1e-6);
        assert!(location_from_text("nothing here").is_none());
    }

    #[test]
    fn destination_falls_back_in_order() {
        let by_name = resolve_destination(Some("Amsterdam fast"), Some("US"));
        assert!((by_name.lat - 52.3676).abs() < 1e-6);
        let by_code = resolve_destination(Some("DE 1"), None);
        assert_eq!(
            by_code,
            GeoPoint {
                lat: 51.0,
                lon: 9.0
            }
        );
        let by_route = resolve_destination(Some("Node 1"), Some("JP"));
        assert_eq!(by_route, country_location("JP").expect("JP"));
        assert_eq!(resolve_destination(None, None), MAP_FALLBACK);
    }

    #[test]
    fn source_uses_ip_city() {
        let ip = IpInfo {
            ip: "198.51.100.7".into(),
            country_code: "RU".into(),
            city: Some("Kazan".into()),
            ..IpInfo::default()
        };
        let point = resolve_source(Some(&ip));
        assert!((point.lat - 55.7961).abs() < 1e-6);
        assert_eq!(resolve_source(None), SOURCE_FALLBACK);
    }

    #[test]
    fn globe_codes_are_indexed() {
        assert_eq!(globe_country_codes().first(), Some(&"AD"));
        assert!(globe_country_codes().contains(&"RU"));
    }
}
