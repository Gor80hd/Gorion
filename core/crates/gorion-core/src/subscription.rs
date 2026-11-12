//! Загрузка подписки по сети. Эталон: `ProfileParser.fetchAndParse`.

use std::time::Duration;

use url::Url;

use crate::error::{CoreError, CoreResult};
use crate::model::ParsedSubscription;
use crate::parser::{Headers, decode_response_body, parse_subscription};

const USER_AGENT: &str = "Gorion/1.0";

/// Проверяет, что строка — абсолютный URL с хостом.
pub fn validate_subscription_url(url: &str) -> CoreResult<Url> {
    let parsed = Url::parse(url.trim()).map_err(|_| CoreError::InvalidSubscriptionUrl)?;
    if parsed.host_str().is_none_or(str::is_empty) {
        return Err(CoreError::InvalidSubscriptionUrl);
    }
    Ok(parsed)
}

pub async fn fetch_and_parse(url: &str) -> CoreResult<ParsedSubscription> {
    let source = validate_subscription_url(url)?;
    // Напрямую, мимо системного прокси, — как в эталоне.
    let client = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(40))
        .connect_timeout(Duration::from_secs(20))
        .no_proxy()
        .build()
        .map_err(|e| CoreError::Internal(e.to_string()))?;
    let response = client
        .get(source.clone())
        .header(reqwest::header::ACCEPT, "*/*")
        .send()
        .await
        .map_err(|e| CoreError::SubscriptionFetch(describe(&e)))?;
    let status = response.status();
    if !status.is_success() {
        return Err(CoreError::SubscriptionFetch(format!(
            "HTTP {}",
            status.as_u16()
        )));
    }
    let headers: Headers = response
        .headers()
        .iter()
        .filter_map(|(k, v)| {
            v.to_str()
                .ok()
                .map(|v| (k.as_str().to_lowercase(), v.to_owned()))
        })
        .fold(Headers::new(), |mut map, (k, v)| {
            map.entry(k).or_insert(v);
            map
        });
    let bytes = response
        .bytes()
        .await
        .map_err(|e| CoreError::SubscriptionFetch(describe(&e)))?;
    let body = decode_response_body(&bytes);
    parse_subscription(&body, &source, &headers)
}

fn describe(error: &reqwest::Error) -> String {
    if error.is_timeout() {
        "тайм-аут".into()
    } else if error.is_connect() {
        "нет соединения с сервером подписки".into()
    } else {
        error.to_string()
    }
}
