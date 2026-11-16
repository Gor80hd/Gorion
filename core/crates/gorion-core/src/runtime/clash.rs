//! Клиент Clash API работающего движка.
//! Эталон: `lib/features/runtime/data/clash_api_client.dart`.

use std::collections::HashMap;
use std::time::Duration;

use futures_util::StreamExt;
use serde_json::Value;

use crate::error::{CoreError, CoreResult};

#[derive(Debug, Clone)]
pub struct ClashClient {
    base_url: String,
    secret: String,
    http: reqwest::Client,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ClashSnapshot {
    pub selected_tag: Option<String>,
    pub delay_by_tag: HashMap<String, i64>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TrafficSample {
    pub up: u64,
    pub down: u64,
}

impl ClashClient {
    pub fn new(controller_port: u16, secret: &str) -> CoreResult<Self> {
        let http = reqwest::Client::builder()
            .no_proxy()
            .connect_timeout(Duration::from_secs(3))
            .build()
            .map_err(|e| CoreError::Internal(e.to_string()))?;
        Ok(Self {
            base_url: format!("http://127.0.0.1:{controller_port}"),
            secret: secret.to_owned(),
            http,
        })
    }

    fn request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.http
            .request(method, format!("{}{path}", self.base_url))
            .bearer_auth(&self.secret)
    }

    /// Ждёт готовности контроллера. `exited` — закончился ли процесс ядра:
    /// тогда ждать дальше бессмысленно.
    pub async fn wait_until_ready(
        &self,
        timeout: Duration,
        exited: impl Fn() -> Option<i32>,
    ) -> CoreResult<()> {
        let deadline = tokio::time::Instant::now() + timeout;
        let mut last_error = String::new();
        while tokio::time::Instant::now() < deadline {
            if let Some(code) = exited() {
                return Err(CoreError::CoreStartFailed(format!(
                    "ядро завершилось до готовности контроллера, код {code}"
                )));
            }
            match self
                .request(reqwest::Method::GET, "/version")
                .timeout(Duration::from_secs(2))
                .send()
                .await
            {
                Ok(response) if response.status().is_success() => return Ok(()),
                Ok(response) => last_error = format!("HTTP {}", response.status().as_u16()),
                Err(error) => last_error = error.to_string(),
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        Err(CoreError::ControllerUnavailable(format!(
            "тайм-аут ожидания контроллера: {last_error}"
        )))
    }

    pub async fn snapshot(&self, selector_tag: &str) -> CoreResult<ClashSnapshot> {
        let body = self.get_json("/proxies", &[]).await?;
        let mut snapshot = ClashSnapshot::default();
        let Some(proxies) = body.get("proxies").and_then(Value::as_object) else {
            return Ok(snapshot);
        };
        for (tag, entry) in proxies {
            if tag == selector_tag
                && let Some(now) = entry
                    .get("now")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
            {
                snapshot.selected_tag = Some(now.to_owned());
            }
            if let Some(delay) = entry
                .get("history")
                .and_then(Value::as_array)
                .and_then(|h| h.first())
                .and_then(|first| first.get("delay"))
                .and_then(Value::as_f64)
            {
                snapshot.delay_by_tag.insert(tag.clone(), delay as i64);
            }
        }
        Ok(snapshot)
    }

    pub async fn select_proxy(&self, selector_tag: &str, server_tag: &str) -> CoreResult<()> {
        let path = format!("/proxies/{}", encode(selector_tag));
        let response = self
            .request(reqwest::Method::PUT, &path)
            .timeout(Duration::from_secs(5))
            .json(&serde_json::json!({"name": server_tag}))
            .send()
            .await
            .map_err(|e| CoreError::ControllerUnavailable(e.to_string()))?;
        if !response.status().is_success() {
            return Err(CoreError::ControllerUnavailable(format!(
                "выбор сервера: HTTP {}",
                response.status().as_u16()
            )));
        }
        Ok(())
    }

    /// URL-тест одного сервера через само ядро — сквозная проверка.
    /// `None` — сервер не ответил за `timeout_ms` или ответил ошибкой.
    pub async fn proxy_delay(&self, tag: &str, test_url: &str, timeout_ms: u64) -> Option<i64> {
        let path = format!("/proxies/{}/delay", encode(tag));
        let timeout = timeout_ms.to_string();
        let body = self
            .get_json_with_timeout(
                &path,
                &[("url", test_url), ("timeout", &timeout)],
                Duration::from_millis(timeout_ms + 2000),
            )
            .await
            .ok()?;
        body.get("delay")
            .and_then(Value::as_f64)
            .map(|d| d as i64)
            .filter(|d| *d > 0)
    }

    /// URL-тест всех серверов группы через само ядро — сквозная проверка.
    /// Сервер, не ответивший за `timeout_ms`, в ответ не попадает.
    pub async fn group_delay(
        &self,
        group_tag: &str,
        test_url: &str,
        timeout_ms: u64,
    ) -> CoreResult<HashMap<String, i64>> {
        let path = format!("/group/{}/delay", encode(group_tag));
        let timeout = timeout_ms.to_string();
        let body = self
            .get_json_with_timeout(
                &path,
                &[("url", test_url), ("timeout", &timeout)],
                Duration::from_millis(timeout_ms + 5000),
            )
            .await?;
        Ok(body
            .as_object()
            .map(|map| {
                map.iter()
                    .filter_map(|(k, v)| v.as_f64().map(|d| (k.clone(), d as i64)))
                    .collect()
            })
            .unwrap_or_default())
    }

    /// Поток трафика (байт/с), раз в секунду. Возвращается, когда
    /// соединение закрылось.
    pub async fn stream_traffic(&self, mut on_sample: impl FnMut(TrafficSample)) -> CoreResult<()> {
        let response = self
            .request(reqwest::Method::GET, "/traffic")
            .send()
            .await
            .map_err(|e| CoreError::ControllerUnavailable(e.to_string()))?;
        let mut stream = response.bytes_stream();
        let mut buffer = Vec::new();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.map_err(|e| CoreError::ControllerUnavailable(e.to_string()))?;
            buffer.extend_from_slice(&chunk);
            while let Some(position) = buffer.iter().position(|b| *b == b'\n') {
                let line: Vec<u8> = buffer.drain(..=position).collect();
                if let Ok(value) = serde_json::from_slice::<Value>(&line) {
                    on_sample(TrafficSample {
                        up: value.get("up").and_then(Value::as_u64).unwrap_or(0),
                        down: value.get("down").and_then(Value::as_u64).unwrap_or(0),
                    });
                }
            }
        }
        Ok(())
    }

    async fn get_json(&self, path: &str, query: &[(&str, &str)]) -> CoreResult<Value> {
        self.get_json_with_timeout(path, query, Duration::from_secs(10))
            .await
    }

    async fn get_json_with_timeout(
        &self,
        path: &str,
        query: &[(&str, &str)],
        timeout: Duration,
    ) -> CoreResult<Value> {
        let mut target = path.to_owned();
        for (index, (key, value)) in query.iter().enumerate() {
            target.push(if index == 0 { '?' } else { '&' });
            target.push_str(&format!("{}={}", encode(key), encode(value)));
        }
        let response = self
            .request(reqwest::Method::GET, &target)
            .timeout(timeout)
            .send()
            .await
            .map_err(|e| CoreError::ControllerUnavailable(e.to_string()))?;
        let text = response
            .text()
            .await
            .map_err(|e| CoreError::ControllerUnavailable(e.to_string()))?;
        Ok(serde_json::from_str(&text).unwrap_or(Value::Object(Default::default())))
    }
}

fn encode(segment: &str) -> String {
    percent_encoding::utf8_percent_encode(segment, percent_encoding::NON_ALPHANUMERIC).to_string()
}
