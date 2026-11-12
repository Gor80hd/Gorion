//! Отображаемые имена серверов: префикс страны → флаг.
//! Эталон: `lib/utils/server_display_text.dart`.

use std::sync::LazyLock;

use regex::Regex;

static HIDDEN_MARKER: LazyLock<Regex> = LazyLock::new(|| re(r"§[^§]*"));
static BRACKET_CODE: LazyLock<Regex> = LazyLock::new(|| re(r"^\[([A-Za-z]{2})\](?:\s+|$)"));
static BRACKET_STRIP: LazyLock<Regex> = LazyLock::new(|| re(r"^\[[A-Za-z]{2}\](.*)$"));
static PLAIN_PREFIX: LazyLock<Regex> = LazyLock::new(|| re(r"^([A-Za-z]{2})([\s_\-:|/]+)(.+)$"));

#[allow(clippy::unwrap_used)] // Шаблоны выше — константы и проверены тестами.
fn re(pattern: &str) -> Regex {
    Regex::new(pattern).unwrap()
}

/// Убирает служебные метки `§…` и, по желанию, подчёркивания.
pub fn sanitize_server_display_text(value: &str, replace_underscores: bool) -> String {
    let mut sanitized = HIDDEN_MARKER.replace_all(value, "").into_owned();
    if replace_underscores {
        sanitized = sanitized.replace('_', " ");
    }
    sanitized.trim().to_owned()
}

/// «NL Amsterdam» → «🇳🇱 Amsterdam».
pub fn normalize_server_display_text(value: &str, replace_underscores: bool) -> String {
    let sanitized = sanitize_server_display_text(value, replace_underscores);
    if sanitized.is_empty() {
        return String::new();
    }
    let Some(code) = extract_country_code(&sanitized) else {
        return sanitized;
    };
    let stripped = strip_country_prefix(&sanitized);
    if stripped.is_empty() {
        return sanitized;
    }
    let flag = country_code_to_flag(&code);
    if flag.is_empty() {
        stripped
    } else {
        format!("{flag} {stripped}")
    }
}

/// Код страны из имени сервера: «[DE] …», «🇩🇪 …», «DE-…».
pub fn extract_country_code(value: &str) -> Option<String> {
    let sanitized = sanitize_server_display_text(value, false);
    if sanitized.is_empty() {
        return None;
    }
    if let Some(caps) = BRACKET_CODE.captures(&sanitized) {
        return normalize_code(&caps[1]);
    }
    if let Some(code) = leading_flag_code(&sanitized) {
        return Some(code);
    }
    let caps = PLAIN_PREFIX.captures(&sanitized)?;
    let token = &caps[1];
    let code = normalize_code(token)?;
    looks_like_country_prefix(token, &caps[2], caps[3].trim()).then_some(code)
}

pub fn strip_country_prefix(value: &str) -> String {
    let sanitized = sanitize_server_display_text(value, false);
    if sanitized.is_empty() {
        return String::new();
    }
    if let Some(caps) = BRACKET_STRIP.captures(&sanitized) {
        return caps[1].trim_start().to_owned();
    }
    if let Some(offset) = leading_flag_prefix_len(&sanitized) {
        return sanitized[offset..].trim_start().to_owned();
    }
    let Some(caps) = PLAIN_PREFIX.captures(&sanitized) else {
        return sanitized;
    };
    let token = &caps[1];
    let remainder = caps[3].trim();
    if normalize_code(token).is_none() || !looks_like_country_prefix(token, &caps[2], remainder) {
        return sanitized;
    }
    remainder.to_owned()
}

pub fn country_code_to_flag(code: &str) -> String {
    let Some(code) = normalize_code(code) else {
        return String::new();
    };
    code.chars()
        .filter_map(|c| char::from_u32(0x1F1E6 + (c as u32 - 'A' as u32)))
        .collect()
}

fn normalize_code(code: &str) -> Option<String> {
    let normalized = code.trim().to_uppercase();
    (normalized.len() == 2 && SUPPORTED_COUNTRY_CODES.contains(&normalized.as_str()))
        .then_some(normalized)
}

fn is_regional_indicator(c: char) -> bool {
    ('\u{1F1E6}'..='\u{1F1FF}').contains(&c)
}

fn leading_flag_code(value: &str) -> Option<String> {
    let mut chars = value.chars();
    let (a, b) = (chars.next()?, chars.next()?);
    if !is_regional_indicator(a) || !is_regional_indicator(b) {
        return None;
    }
    let to_ascii = |c: char| char::from_u32('A' as u32 + (c as u32 - 0x1F1E6));
    let code: String = [to_ascii(a)?, to_ascii(b)?].iter().collect();
    normalize_code(&code)
}

fn leading_flag_prefix_len(value: &str) -> Option<usize> {
    let mut chars = value.char_indices();
    let (_, a) = chars.next()?;
    let (_, b) = chars.next()?;
    if !is_regional_indicator(a) || !is_regional_indicator(b) {
        return None;
    }
    let mut offset = a.len_utf8() + b.len_utf8();
    while value[offset..].starts_with(' ') {
        offset += 1;
    }
    Some(offset)
}

fn looks_like_country_prefix(token: &str, separator: &str, remainder: &str) -> bool {
    if remainder.is_empty() {
        return false;
    }
    if token == token.to_uppercase() {
        return true;
    }
    if separator.contains(['_', '-', ':', '|', '/']) {
        return true;
    }
    !remainder
        .chars()
        .next()
        .is_some_and(|c| c.is_ascii_lowercase())
}

const SUPPORTED_COUNTRY_CODES: &[&str] = &[
    "AD", "AE", "AF", "AG", "AI", "AL", "AM", "AO", "AQ", "AR", "AS", "AT", "AU", "AW", "AX", "AZ",
    "BA", "BB", "BD", "BE", "BF", "BG", "BH", "BI", "BJ", "BL", "BM", "BN", "BO", "BQ", "BR", "BS",
    "BT", "BV", "BW", "BY", "BZ", "CA", "CC", "CD", "CF", "CG", "CH", "CI", "CK", "CL", "CM", "CN",
    "CO", "CR", "CU", "CV", "CW", "CX", "CY", "CZ", "DE", "DJ", "DK", "DM", "DO", "DZ", "EC", "EE",
    "EG", "EH", "ER", "ES", "ET", "EU", "FI", "FJ", "FK", "FM", "FO", "FR", "GA", "GB", "GD", "GE",
    "GF", "GG", "GH", "GI", "GL", "GM", "GN", "GP", "GQ", "GR", "GS", "GT", "GU", "GW", "GY", "HK",
    "HM", "HN", "HR", "HT", "HU", "ID", "IE", "IL", "IM", "IN", "IO", "IQ", "IR", "IS", "IT", "JE",
    "JM", "JO", "JP", "KE", "KG", "KH", "KI", "KM", "KN", "KP", "KR", "KW", "KY", "KZ", "LA", "LB",
    "LC", "LI", "LK", "LR", "LS", "LT", "LU", "LV", "LY", "MA", "MC", "MD", "ME", "MF", "MG", "MH",
    "MK", "ML", "MM", "MN", "MO", "MP", "MQ", "MR", "MS", "MT", "MU", "MV", "MW", "MX", "MY", "MZ",
    "NA", "NC", "NE", "NF", "NG", "NI", "NL", "NO", "NP", "NR", "NU", "NZ", "OM", "PA", "PE", "PF",
    "PG", "PH", "PK", "PL", "PM", "PN", "PR", "PS", "PT", "PW", "PY", "QA", "RE", "RO", "RS", "RU",
    "RW", "SA", "SB", "SC", "SD", "SE", "SG", "SH", "SI", "SJ", "SK", "SL", "SM", "SN", "SO", "SR",
    "SS", "ST", "SV", "SX", "SY", "SZ", "TC", "TD", "TF", "TG", "TH", "TJ", "TK", "TL", "TM", "TN",
    "TO", "TR", "TT", "TV", "TW", "TZ", "UA", "UG", "UM", "UN", "US", "UY", "UZ", "VA", "VC", "VE",
    "VG", "VI", "VN", "VU", "WF", "WS", "XK", "YE", "YT", "ZA", "ZM", "ZW",
];
