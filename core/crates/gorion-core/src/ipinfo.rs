//! Внешний IP и его место: напрямую и через локальный прокси.
//! Эталон: `lib/features/proxy/notifier/ip_info_notifier.dart`,
//! `lib/features/proxy/utils/ip_info_display.dart`.

use std::time::Duration;

use serde_json::{Map, Value};

const LOOKUP_TIMEOUT: Duration = Duration::from_secs(4);
const USER_AGENT: &str = concat!("Gorion/", env!("CARGO_PKG_VERSION"));

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct IpInfo {
    pub ip: String,
    pub country_code: String,
    pub country: Option<String>,
    pub region: Option<String>,
    pub city: Option<String>,
    pub timezone: Option<String>,
    pub asn: Option<String>,
    pub org: Option<String>,
}

#[derive(Clone, Copy)]
enum Endpoint {
    Sb,
    WhoIs,
    ApiCo,
}

impl Endpoint {
    const ALL: [Endpoint; 3] = [Endpoint::Sb, Endpoint::WhoIs, Endpoint::ApiCo];

    fn url(self) -> &'static str {
        match self {
            Endpoint::Sb => "https://api.ip.sb/geoip",
            Endpoint::WhoIs => "https://ipwho.is/",
            Endpoint::ApiCo => "https://ipapi.co/json/",
        }
    }

    fn parse(self, body: &str) -> Option<IpInfo> {
        let value: Value = serde_json::from_str(body).ok()?;
        let map = value.as_object()?;
        match self {
            Endpoint::Sb => build(
                read(Some(map), &["ip", "query"]),
                read(Some(map), &["country_code", "countryCode"]),
                IpInfo {
                    country: read(Some(map), &["country"]),
                    region: read(Some(map), &["region", "region_name", "regionName"]),
                    city: read(Some(map), &["city"]),
                    timezone: read_timezone(map.get("timezone")),
                    asn: read(Some(map), &["asn"]),
                    org: read(Some(map), &["organization", "org", "isp"]),
                    ..IpInfo::default()
                },
            ),
            Endpoint::WhoIs => {
                if map.get("success").and_then(Value::as_bool) == Some(false) {
                    return None;
                }
                let connection = map.get("connection").and_then(Value::as_object);
                let timezone = map.get("timezone").and_then(Value::as_object);
                build(
                    read(Some(map), &["ip"]),
                    read(Some(map), &["country_code", "countryCode"]),
                    IpInfo {
                        country: read(Some(map), &["country"]),
                        region: read(Some(map), &["region"]),
                        city: read(Some(map), &["city"]),
                        timezone: read(timezone, &["id"])
                            .or_else(|| read(Some(map), &["timezone"])),
                        asn: read(connection, &["asn"]).or_else(|| read(Some(map), &["asn"])),
                        org: read(connection, &["org", "isp"])
                            .or_else(|| read(Some(map), &["connection", "organization"])),
                        ..IpInfo::default()
                    },
                )
            }
            Endpoint::ApiCo => {
                if map.get("error").and_then(Value::as_bool) == Some(true) {
                    return None;
                }
                build(
                    read(Some(map), &["ip"]),
                    read(Some(map), &["country_code", "countryCode"]),
                    IpInfo {
                        country: read(Some(map), &["country_name", "country"]),
                        region: read(Some(map), &["region", "region_name", "regionName"]),
                        city: read(Some(map), &["city"]),
                        timezone: read(Some(map), &["timezone"]),
                        asn: read(Some(map), &["asn"]),
                        org: read(Some(map), &["org", "organization"]),
                        ..IpInfo::default()
                    },
                )
            }
        }
    }
}

fn build(ip: Option<String>, country_code: Option<String>, rest: IpInfo) -> Option<IpInfo> {
    Some(IpInfo {
        ip: ip?,
        country_code: country_code?,
        ..rest
    })
}

/// Первое непустое значение по ключам; строка "null" — тоже пусто.
fn read(map: Option<&Map<String, Value>>, keys: &[&str]) -> Option<String> {
    let map = map?;
    keys.iter().find_map(|key| {
        let value = match map.get(*key)? {
            Value::Null => return None,
            Value::String(s) => s.trim().to_owned(),
            other => other.to_string().trim().to_owned(),
        };
        (!value.is_empty() && !value.eq_ignore_ascii_case("null")).then_some(value)
    })
}

fn read_timezone(value: Option<&Value>) -> Option<String> {
    match value? {
        Value::String(s) => Some(s.trim().to_owned()).filter(|s| !s.is_empty()),
        Value::Object(map) => read(Some(map), &["id"]),
        _ => None,
    }
}

/// `proxy_port: None` — напрямую, мимо системного прокси.
pub async fn lookup(proxy_port: Option<u16>) -> Option<IpInfo> {
    let mut builder = reqwest::Client::builder()
        .timeout(LOOKUP_TIMEOUT)
        .connect_timeout(LOOKUP_TIMEOUT)
        .user_agent(USER_AGENT);
    builder = match proxy_port {
        Some(port) => builder.proxy(reqwest::Proxy::all(format!("http://127.0.0.1:{port}")).ok()?),
        None => builder.no_proxy(),
    };
    let client = builder.build().ok()?;
    for endpoint in Endpoint::ALL {
        let Ok(response) = client
            .get(endpoint.url())
            .header("Accept", "application/json, text/plain;q=0.9, */*;q=0.1")
            .send()
            .await
        else {
            continue;
        };
        let status = response.status().as_u16();
        if !(200..500).contains(&status) {
            continue;
        }
        let Ok(body) = response.text().await else {
            continue;
        };
        if body.trim().is_empty() {
            continue;
        }
        if let Some(info) = endpoint.parse(&body) {
            return Some(info);
        }
    }
    None
}

/// Самая понятная подпись места: «город, регион», «город, страна»…
pub fn best_location(info: &IpInfo) -> Option<String> {
    fn part(v: &Option<String>) -> Option<&str> {
        v.as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("null"))
    }
    let same = |a: &str, b: &str| a.to_lowercase() == b.to_lowercase();
    let city = part(&info.city);
    let region = part(&info.region);
    let country = part(&info.country);
    let org = part(&info.org);
    let code =
        Some(info.country_code.trim()).filter(|s| !s.is_empty() && !s.eq_ignore_ascii_case("null"));
    match (city, region, country) {
        (Some(c), Some(r), _) if !same(c, r) => return Some(format!("{c}, {r}")),
        (Some(c), _, Some(k)) if !same(c, k) => return Some(format!("{c}, {k}")),
        (_, Some(r), Some(k)) if !same(r, k) => return Some(format!("{r}, {k}")),
        _ => {}
    }
    city.or(region)
        .or(country)
        .or(org)
        .or(code)
        .map(str::to_owned)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_each_endpoint() {
        let sb = Endpoint::Sb
            .parse(r#"{"ip":"198.51.100.1","country_code":"DE","country":"Germany","city":"Berlin","timezone":"Europe/Berlin","organization":"Example"}"#)
            .expect("ip.sb");
        assert_eq!(sb.country_code, "DE");
        assert_eq!(sb.org.as_deref(), Some("Example"));

        let who = Endpoint::WhoIs
            .parse(r#"{"success":true,"ip":"198.51.100.2","country_code":"NL","region":"North Holland","city":"Amsterdam","timezone":{"id":"Europe/Amsterdam"},"connection":{"asn":64500,"org":"Example BV"}}"#)
            .expect("ipwho.is");
        assert_eq!(who.asn.as_deref(), Some("64500"));
        assert_eq!(who.timezone.as_deref(), Some("Europe/Amsterdam"));
        assert!(Endpoint::WhoIs.parse(r#"{"success":false}"#).is_none());

        let api = Endpoint::ApiCo
            .parse(r#"{"ip":"198.51.100.3","country_code":"FI","country_name":"Finland","city":"null"}"#)
            .expect("ipapi.co");
        assert_eq!(api.country.as_deref(), Some("Finland"));
        assert_eq!(api.city, None);
        assert!(Endpoint::ApiCo.parse(r#"{"error":true}"#).is_none());
        assert!(Endpoint::Sb.parse(r#"{"ip":"198.51.100.4"}"#).is_none());
    }

    #[test]
    fn location_label_matches_reference() {
        let mut info = IpInfo {
            ip: "x".into(),
            country_code: "RU".into(),
            city: Some("Kazan".into()),
            region: Some("Tatarstan".into()),
            country: Some("Russia".into()),
            ..IpInfo::default()
        };
        assert_eq!(best_location(&info).as_deref(), Some("Kazan, Tatarstan"));
        info.region = Some("kazan".into());
        assert_eq!(best_location(&info).as_deref(), Some("Kazan, Russia"));
        info.city = None;
        info.region = None;
        info.country = None;
        assert_eq!(best_location(&info).as_deref(), Some("RU"));
    }
}
