//! Разбор ссылок `scheme://userinfo@host:port?query#fragment` с семантикой,
//! близкой к `Uri` из Dart, на которой построен эталон.

use percent_encoding::percent_decode_str;
use url::{Host, Url};

#[derive(Debug, Clone)]
pub struct ShareUri {
    /// `userinfo` как в исходной строке (с %-кодированием).
    pub user_info: String,
    /// Хост в нижнем регистре, IPv6 без скобок.
    pub host: String,
    pub port: Option<u16>,
    /// Пары запроса в порядке появления, уже декодированные.
    pub query_pairs: Vec<(String, String)>,
    /// Фрагмент как в исходной строке.
    pub fragment: Option<String>,
}

impl ShareUri {
    pub fn parse(line: &str) -> Option<Self> {
        let (head, fragment) = match line.find('#') {
            Some(index) => (&line[..index], Some(line[index + 1..].to_owned())),
            None => (line, None),
        };
        let url = Url::parse(head).ok()?;
        let host = match url.host()? {
            Host::Domain(domain) => decode_component(domain).unwrap_or_else(|| domain.to_owned()),
            Host::Ipv4(addr) => addr.to_string(),
            Host::Ipv6(addr) => addr.to_string(),
        }
        .to_lowercase();
        let user_info = match url.password() {
            Some(password) => format!("{}:{password}", url.username()),
            None => url.username().to_owned(),
        };
        Some(Self {
            user_info,
            host,
            port: url.port(),
            query_pairs: url
                .query_pairs()
                .map(|(k, v)| (k.into_owned(), v.into_owned()))
                .collect(),
            fragment,
        })
    }

    /// `Uri.port`: 0, если порт не указан.
    pub fn port_or_zero(&self) -> u16 {
        self.port.unwrap_or(0)
    }

    /// Параметры с ключами в нижнем регистре; для каждого исходного ключа
    /// берётся первое непустое значение (как `_queryParameters`).
    pub fn query(&self) -> Query {
        let mut grouped: Vec<(String, Vec<String>)> = Vec::new();
        for (key, value) in &self.query_pairs {
            match grouped.iter_mut().find(|(k, _)| k == key) {
                Some((_, values)) => values.push(value.clone()),
                None => grouped.push((key.clone(), vec![value.clone()])),
            }
        }
        let mut query = Query::default();
        for (key, values) in grouped {
            if let Some(value) = values.iter().map(|v| v.trim()).find(|v| !v.is_empty()) {
                query.set(key.to_lowercase(), value.to_owned());
            }
        }
        query
    }
}

/// Упорядоченный словарь параметров запроса.
#[derive(Debug, Clone, Default)]
pub struct Query(Vec<(String, String)>);

impl Query {
    pub fn set(&mut self, key: String, value: String) {
        match self.0.iter_mut().find(|(k, _)| *k == key) {
            Some(entry) => entry.1 = value,
            None => self.0.push((key, value)),
        }
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.0
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }

    pub fn contains(&self, key: &str) -> bool {
        self.get(key).is_some()
    }

    /// Первое непустое значение среди ключей (`_firstNonEmpty`).
    pub fn first(&self, keys: &[&str]) -> Option<String> {
        keys.iter()
            .filter_map(|key| self.get(key))
            .map(str::trim)
            .find(|v| !v.is_empty())
            .map(str::to_owned)
    }
}

/// `Uri.splitQueryString` + фильтр пустых (`_parseRawQuery`).
pub fn parse_raw_query(raw: &str) -> Query {
    let mut query = Query::default();
    if raw.trim().is_empty() {
        return query;
    }
    let mut last: Vec<(String, String)> = Vec::new();
    for (key, value) in url::form_urlencoded::parse(raw.as_bytes()) {
        match last.iter_mut().find(|(k, _)| *k == key) {
            Some(entry) => entry.1 = value.into_owned(),
            None => last.push((key.into_owned(), value.into_owned())),
        }
    }
    for (key, value) in last {
        let trimmed = value.trim();
        if !trimmed.is_empty() {
            query.set(key.to_lowercase(), trimmed.to_owned());
        }
    }
    query
}

/// `Uri.decodeComponent` без исключений: `None`, если строка пустая или
/// не декодируется.
pub fn decode_component(value: &str) -> Option<String> {
    let decoded = percent_decode_str(value).decode_utf8().ok()?.into_owned();
    Some(decoded)
}

/// `_decodeUriComponent`: декодированное значение без пробелов по краям,
/// при ошибке — исходное; пустое → `None`.
pub fn decode_component_or_raw(value: &str) -> Option<String> {
    if value.trim().is_empty() {
        return None;
    }
    let decoded = match decode_component(value) {
        Some(decoded) if is_strict_percent_encoding(value) => decoded,
        _ => value.to_owned(),
    };
    let trimmed = decoded.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_owned())
}

/// В Dart `Uri.decodeComponent` бросает исключение на «%» без двух
/// шестнадцатеричных цифр, и эталон тогда берёт исходную строку.
fn is_strict_percent_encoding(value: &str) -> bool {
    let bytes = value.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let valid = bytes.get(index + 1).is_some_and(u8::is_ascii_hexdigit)
                && bytes.get(index + 2).is_some_and(u8::is_ascii_hexdigit);
            if !valid {
                return false;
            }
            index += 3;
        } else {
            index += 1;
        }
    }
    true
}
