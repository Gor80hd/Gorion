//! Сквозные проверки через локальный прокси.
//! Эталон: `auto_select_network_probe.dart`, `auto_select_state.dart`,
//! `AutoSelectorService._probeServer`.
//!
//! Правило 1 AGENTS.md: здоровье сервера — только по реальным запросам
//! через прокси. TCP-коннект ничего не доказывает.

use std::time::{Duration, Instant};

use futures_util::StreamExt;

pub const DEFAULT_DOMAIN_PROBE_URL: &str = "https://www.gstatic.com/generate_204";
pub const DEFAULT_IP_PROBE_URL: &str = "http://1.1.1.1";
pub const DEFAULT_THROUGHPUT_PROBE_URL: &str = "https://speed.cloudflare.com/__down?bytes=131072";
pub const DEFAULT_DOMAIN_PROBE_URLS: &[&str] = &[
    DEFAULT_DOMAIN_PROBE_URL,
    "https://cp.cloudflare.com/generate_204",
    "https://www.msftconnecttest.com/connecttest.txt",
];
pub const DEFAULT_IP_PROBE_URLS: &[&str] = &[
    DEFAULT_IP_PROBE_URL,
    "http://1.0.0.1",
    "http://1.1.1.1/cdn-cgi/trace",
];
pub const DEFAULT_THROUGHPUT_PROBE_URLS: &[&str] = &[
    DEFAULT_THROUGHPUT_PROBE_URL,
    "https://httpbingo.org/bytes/131072",
    "https://httpbin.org/bytes/131072",
];
/// Меньше этого — канал считается непригодным (байт/с).
pub const MINIMUM_USABLE_THROUGHPUT: u64 = 24 * 1024;

/// Порядок адресов проверки с устойчивым сдвигом по ключу: разные серверы
/// проверяются разными адресами первыми, чтобы один заблокированный адрес
/// не «убил» все серверы сразу.
pub fn resolve_probe_urls(
    configured: &str,
    default_url: &str,
    defaults: &[&str],
    rotation_key: &str,
) -> Vec<String> {
    let configured = configured.trim();
    let normalized = if configured.is_empty() {
        default_url
    } else {
        configured
    };
    let base: Vec<&str> = if normalized == default_url {
        defaults.to_vec()
    } else {
        vec![normalized]
    };
    let mut urls: Vec<String> = Vec::new();
    for candidate in base {
        let candidate = candidate.trim();
        if !candidate.is_empty() && !urls.iter().any(|u| u == candidate) {
            urls.push(candidate.to_owned());
        }
    }
    if urls.len() <= 1 {
        return urls;
    }
    let start = stable_rotation_index(rotation_key, urls.len());
    (0..urls.len())
        .map(|offset| urls[(start + offset) % urls.len()].clone())
        .collect()
}

pub fn domain_probe_urls(configured: &str, rotation_key: &str) -> Vec<String> {
    resolve_probe_urls(
        configured,
        DEFAULT_DOMAIN_PROBE_URL,
        DEFAULT_DOMAIN_PROBE_URLS,
        rotation_key,
    )
}

pub fn ip_probe_urls(configured: &str, rotation_key: &str) -> Vec<String> {
    resolve_probe_urls(
        configured,
        DEFAULT_IP_PROBE_URL,
        DEFAULT_IP_PROBE_URLS,
        rotation_key,
    )
}

pub fn throughput_probe_urls(configured: &str, rotation_key: &str) -> Vec<String> {
    resolve_probe_urls(
        configured,
        DEFAULT_THROUGHPUT_PROBE_URL,
        DEFAULT_THROUGHPUT_PROBE_URLS,
        rotation_key,
    )
}

/// Первый адрес для URLTest ядра.
pub fn url_test_url(configured: &str, rotation_key: &str) -> String {
    domain_probe_urls(configured, rotation_key)
        .into_iter()
        .next()
        .unwrap_or_else(|| DEFAULT_DOMAIN_PROBE_URL.into())
}

/// FNV-1a по UTF-16 кодам, как `_stableProbeRotationIndex` в Dart.
fn stable_rotation_index(key: &str, length: usize) -> usize {
    if length <= 1 {
        return 0;
    }
    let mut hash: u64 = 0x811C_9DC5;
    for unit in key.encode_utf16() {
        hash ^= u64::from(unit);
        hash = hash.wrapping_mul(0x0100_0193) & 0x7fff_ffff;
    }
    (hash % length as u64) as usize
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProbeResult {
    pub server_tag: String,
    pub url_test_delay: Option<i64>,
    pub domain_ok: bool,
    pub ip_ok: bool,
    pub throughput: u64,
}

impl ProbeResult {
    pub fn fully_healthy(&self) -> bool {
        self.throughput > 0 && self.domain_ok && self.ip_ok
    }

    pub fn health_score(&self) -> u8 {
        match (self.throughput > 0, self.domain_ok, self.ip_ok) {
            (true, true, true) => 5,
            (true, true, false) | (true, false, true) => 4,
            (true, false, false) => 3,
            (false, true, true) => 2,
            (false, true, false) | (false, false, true) => 1,
            _ => 0,
        }
    }

    pub fn has_end_to_end_connectivity(&self) -> bool {
        self.health_score() > 0
    }
}

/// Сортировка как `_compareProbesByPriority`: здоровье, затем задержка;
/// при близких задержках (окно 90 мс) — скорость.
pub fn rank_probes(probes: &mut [ProbeResult]) {
    const THROUGHPUT_WINDOW_MS: i64 = 90;
    probes.sort_by(|left, right| {
        right
            .health_score()
            .cmp(&left.health_score())
            .then_with(|| {
                let l = left.url_test_delay.unwrap_or(1 << 30);
                let r = right.url_test_delay.unwrap_or(1 << 30);
                if (l - r).abs() <= THROUGHPUT_WINDOW_MS && left.throughput != right.throughput {
                    return right.throughput.cmp(&left.throughput);
                }
                l.cmp(&r)
            })
    });
}

fn proxied_client(mixed_port: u16, timeout: Duration) -> Option<reqwest::Client> {
    let proxy = reqwest::Proxy::all(format!("http://127.0.0.1:{mixed_port}")).ok()?;
    reqwest::Client::builder()
        .proxy(proxy)
        .connect_timeout(timeout)
        .timeout(timeout)
        .build()
        .ok()
}

/// HTTP(S)-запрос через локальный прокси; успех — ответ 2xx.
pub async fn probe_http(mixed_port: u16, url: &str, timeout: Duration) -> bool {
    let Some(client) = proxied_client(mixed_port, timeout) else {
        return false;
    };
    match client.get(url).send().await {
        Ok(response) => {
            let ok = response.status().is_success();
            let _ = response.bytes().await;
            ok
        }
        Err(_) => false,
    }
}

pub async fn probe_http_any(mixed_port: u16, urls: &[String], timeout: Duration) -> bool {
    for url in urls {
        if probe_http(mixed_port, url, timeout).await {
            return true;
        }
    }
    false
}

/// Скорость загрузки через прокси, байт/с; 0 — не удалось.
pub async fn measure_throughput(mixed_port: u16, url: &str, timeout: Duration) -> u64 {
    let Some(client) = proxied_client(mixed_port, timeout) else {
        return 0;
    };
    let started = Instant::now();
    let Ok(response) = client.get(url).send().await else {
        return 0;
    };
    if !response.status().is_success() {
        return 0;
    }
    let mut stream = response.bytes_stream();
    let mut bytes: u64 = 0;
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(chunk) => bytes += chunk.len() as u64,
            Err(_) => return 0,
        }
    }
    let elapsed = started.elapsed().as_millis() as u64;
    if bytes == 0 {
        return 0;
    }
    (bytes * 1000 + elapsed / 2)
        .checked_div(elapsed)
        .unwrap_or(bytes)
}

pub async fn measure_throughput_any(mixed_port: u16, urls: &[String], timeout: Duration) -> u64 {
    for url in urls {
        let value = measure_throughput(mixed_port, url, timeout).await;
        if value > 0 {
            return value;
        }
    }
    0
}

#[derive(Debug, Clone)]
pub struct ProbeSettings {
    pub domain_probe_url: String,
    pub ip_probe_url: String,
    pub check_ip: bool,
}

impl Default for ProbeSettings {
    fn default() -> Self {
        Self {
            domain_probe_url: DEFAULT_DOMAIN_PROBE_URL.into(),
            ip_probe_url: DEFAULT_IP_PROBE_URL.into(),
            check_ip: true,
        }
    }
}

/// Полная проверка выбранного сервера через локальный прокси:
/// домен, IP и реальная загрузка.
pub async fn probe_server(
    mixed_port: u16,
    profile_id: &str,
    server_tag: &str,
    url_test_delay: Option<i64>,
    settings: &ProbeSettings,
) -> ProbeResult {
    let key = |kind: &str| format!("{profile_id}::{server_tag}::live::{kind}");
    let domain_ok = probe_http_any(
        mixed_port,
        &domain_probe_urls(&settings.domain_probe_url, &key("domain")),
        Duration::from_secs(6),
    )
    .await;
    let ip_ok = if settings.check_ip {
        probe_http_any(
            mixed_port,
            &ip_probe_urls(&settings.ip_probe_url, &key("ip")),
            Duration::from_secs(6),
        )
        .await
    } else {
        true
    };
    let measured = measure_throughput_any(
        mixed_port,
        &throughput_probe_urls(DEFAULT_THROUGHPUT_PROBE_URL, &key("throughput")),
        Duration::from_secs(2),
    )
    .await;
    ProbeResult {
        server_tag: server_tag.to_owned(),
        url_test_delay,
        domain_ok,
        ip_ok,
        throughput: if measured >= MINIMUM_USABLE_THROUGHPUT {
            measured
        } else {
            0
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn custom_url_is_used_alone() {
        assert_eq!(
            resolve_probe_urls(
                " https://x/y ",
                DEFAULT_DOMAIN_PROBE_URL,
                DEFAULT_DOMAIN_PROBE_URLS,
                "k"
            ),
            vec!["https://x/y".to_owned()]
        );
    }

    #[test]
    fn default_urls_rotate_but_keep_all_entries() {
        let urls = domain_probe_urls("", "profile::server::live::domain");
        assert_eq!(urls.len(), 3);
        for expected in DEFAULT_DOMAIN_PROBE_URLS {
            assert!(urls.iter().any(|u| u == expected));
        }
    }

    #[test]
    fn health_score_matches_reference_order() {
        let probe = |t, d, i| ProbeResult {
            server_tag: String::new(),
            url_test_delay: None,
            domain_ok: d,
            ip_ok: i,
            throughput: t,
        };
        assert_eq!(probe(1, true, true).health_score(), 5);
        assert_eq!(probe(1, false, true).health_score(), 4);
        assert_eq!(probe(1, false, false).health_score(), 3);
        assert_eq!(probe(0, true, true).health_score(), 2);
        assert_eq!(probe(0, true, false).health_score(), 1);
        assert!(!probe(0, false, false).has_end_to_end_connectivity());
    }
}
