//! Управление движком — подмножество Clash API sing-box, которым пользуется
//! ядро Gorion: `/version`, `/proxies`, выбор сервера, URL-тест, `/traffic`.
//! Благодаря этому ядро управляет движком и sing-box одним и тем же кодом.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};
use subtle::ConstantTimeEq;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinSet;

use crate::config::Plan;
use crate::outbound::Outbound;
use crate::selector::{Selector, Traffic};
use crate::urltest;

const MAX_REQUEST: usize = 64 * 1024;
const DEFAULT_DELAY_TIMEOUT: Duration = Duration::from_secs(5);
const TRAFFIC_INTERVAL: Duration = Duration::from_secs(1);

pub struct Control {
    secret: String,
    selector_tag: String,
    members: Vec<String>,
    outbounds: HashMap<String, Arc<Outbound>>,
    selected: Mutex<String>,
    /// Последняя задержка сервера, мс.
    history: Mutex<HashMap<String, u64>>,
    selector: Arc<Selector>,
    traffic: Arc<Traffic>,
}

impl Control {
    pub fn new(
        plan: &Plan,
        secret: String,
        selector: Arc<Selector>,
        traffic: Arc<Traffic>,
    ) -> Self {
        Self {
            secret,
            selector_tag: plan.selector_tag.clone(),
            members: plan.members.clone(),
            outbounds: plan.outbounds.iter().cloned().collect(),
            selected: Mutex::new(plan.selected.clone()),
            history: Mutex::new(HashMap::new()),
            selector,
            traffic,
        }
    }

    fn selected(&self) -> String {
        self.selected.lock().map(|s| s.clone()).unwrap_or_default()
    }

    fn select(&self, tag: &str) -> bool {
        let Some(outbound) = self.outbounds.get(tag) else {
            return false;
        };
        if let Ok(mut selected) = self.selected.lock() {
            if *selected == tag {
                return true;
            }
            *selected = tag.to_owned();
        }
        self.selector.set(Arc::clone(outbound));
        true
    }

    fn proxies(&self) -> Value {
        let history = self.history.lock().map(|h| h.clone()).unwrap_or_default();
        let mut proxies = serde_json::Map::new();
        proxies.insert(
            self.selector_tag.clone(),
            json!({
                "type": "Selector",
                "name": self.selector_tag,
                "now": self.selected(),
                "all": self.members,
                "history": [],
            }),
        );
        for tag in &self.members {
            let kind = match self.outbounds.get(tag).map(AsRef::as_ref) {
                Some(Outbound::Direct) => "Direct",
                Some(Outbound::Shadowsocks(_) | Outbound::Shadowsocks2022(_)) => "Shadowsocks",
                Some(Outbound::Trojan(_)) => "Trojan",
                Some(Outbound::Vless(_)) => "VLESS",
                None => "Unknown",
            };
            let history = history
                .get(tag)
                .map(|delay| json!([{ "delay": delay }]))
                .unwrap_or_else(|| json!([]));
            proxies.insert(
                tag.clone(),
                json!({ "type": kind, "name": tag, "history": history }),
            );
        }
        json!({ "proxies": proxies })
    }
}

/// Обслуживает управление, пока задачу не отменят.
pub async fn serve(listener: TcpListener, control: Arc<Control>) {
    let mut tasks = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => match accepted {
                Ok((stream, _)) => {
                    let control = Arc::clone(&control);
                    tasks.spawn(async move {
                        let _ = handle(stream, &control).await;
                    });
                }
                Err(_) => tokio::time::sleep(Duration::from_millis(50)).await,
            },
            Some(_) = tasks.join_next(), if !tasks.is_empty() => {}
        }
    }
}

struct Request {
    method: String,
    path: Vec<String>,
    query: HashMap<String, String>,
    authorization: Option<String>,
    body: Vec<u8>,
}

async fn read_request(stream: &mut TcpStream) -> std::io::Result<Option<Request>> {
    let mut buf = Vec::with_capacity(1024);
    let mut chunk = [0u8; 4096];
    let head_end = loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            return Ok(None);
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break end;
        }
        if buf.len() > MAX_REQUEST {
            return Ok(None);
        }
    };
    let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut first = lines.next().unwrap_or_default().split(' ');
    let method = first.next().unwrap_or_default().to_owned();
    let target = first.next().unwrap_or_default();
    let mut authorization = None;
    let mut content_length = 0usize;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        match name.trim().to_ascii_lowercase().as_str() {
            "authorization" => authorization = Some(value.to_owned()),
            "content-length" => content_length = value.parse().unwrap_or(0),
            _ => {}
        }
    }
    if content_length > MAX_REQUEST {
        return Ok(None);
    }
    let mut body = buf[head_end + 4..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(content_length);
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    Ok(Some(Request {
        method,
        path: path
            .split('/')
            .filter(|s| !s.is_empty())
            .map(percent_decode)
            .collect(),
        query: query
            .split('&')
            .filter_map(|pair| pair.split_once('='))
            .map(|(k, v)| (percent_decode(k), percent_decode(v)))
            .collect(),
        authorization,
        body,
    }))
}

fn percent_decode(value: &str) -> String {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(byte) = value
                .get(i + 1..i + 3)
                .and_then(|hex| u8::from_str_radix(hex, 16).ok())
        {
            out.push(byte);
            i += 3;
            continue;
        }
        out.push(if bytes[i] == b'+' { b' ' } else { bytes[i] });
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

async fn respond(stream: &mut TcpStream, status: u16, body: Option<Value>) -> std::io::Result<()> {
    let reason = match status {
        200 => "OK",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        404 => "Not Found",
        503 => "Service Unavailable",
        504 => "Gateway Timeout",
        _ => "Error",
    };
    let body = body.map(|b| b.to_string()).unwrap_or_default();
    let head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    stream.write_all(head.as_bytes()).await?;
    stream.write_all(body.as_bytes()).await?;
    stream.shutdown().await
}

fn message(text: &str) -> Option<Value> {
    Some(json!({ "message": text }))
}

async fn handle(mut stream: TcpStream, control: &Control) -> std::io::Result<()> {
    let Some(request) = read_request(&mut stream).await? else {
        return Ok(());
    };
    if !control.secret.is_empty() {
        let expected = format!("Bearer {}", control.secret);
        let given = request.authorization.as_deref().unwrap_or_default();
        if !bool::from(given.as_bytes().ct_eq(expected.as_bytes())) {
            return respond(&mut stream, 401, message("Unauthorized")).await;
        }
    }
    let path: Vec<&str> = request.path.iter().map(String::as_str).collect();
    match (request.method.as_str(), path.as_slice()) {
        ("GET", ["version"]) => {
            let body = json!({ "version": concat!("gorion-engine ", env!("CARGO_PKG_VERSION")), "meta": true });
            respond(&mut stream, 200, Some(body)).await
        }
        ("GET", ["proxies"]) => respond(&mut stream, 200, Some(control.proxies())).await,
        ("PUT", ["proxies", tag]) => {
            if *tag != control.selector_tag {
                return respond(&mut stream, 400, message("Must be a Selector")).await;
            }
            let name = serde_json::from_slice::<Value>(&request.body)
                .ok()
                .and_then(|v| v.get("name").and_then(Value::as_str).map(str::to_owned));
            match name {
                Some(name) if control.members.contains(&name) && control.select(&name) => {
                    respond(&mut stream, 204, None).await
                }
                _ => {
                    respond(
                        &mut stream,
                        400,
                        message("Selector update error: not found"),
                    )
                    .await
                }
            }
        }
        ("GET", ["proxies", tag, "delay"]) => {
            let Some(outbound) = control.outbounds.get(*tag).cloned() else {
                return respond(&mut stream, 404, message("Resource not found")).await;
            };
            let Some(url) = request.query.get("url").filter(|u| !u.is_empty()) else {
                return respond(&mut stream, 400, message("Body invalid")).await;
            };
            let timeout = request
                .query
                .get("timeout")
                .and_then(|t| t.parse::<u64>().ok())
                .map_or(DEFAULT_DELAY_TIMEOUT, Duration::from_millis);
            match urltest::delay(&outbound, url, timeout).await {
                Ok(delay) => {
                    if let Ok(mut history) = control.history.lock() {
                        history.insert((*tag).to_owned(), delay);
                    }
                    respond(&mut stream, 200, Some(json!({ "delay": delay }))).await
                }
                Err(crate::EngineError::Io(e)) if e.kind() == std::io::ErrorKind::TimedOut => {
                    respond(&mut stream, 504, message("Timeout")).await
                }
                Err(_) => {
                    respond(
                        &mut stream,
                        503,
                        message("An error occurred in the delay test"),
                    )
                    .await
                }
            }
        }
        ("GET", ["traffic"]) => stream_traffic(stream, &control.traffic).await,
        _ => respond(&mut stream, 404, message("Resource not found")).await,
    }
}

/// Скорость раз в секунду строками JSON — как `/traffic` в Clash API.
async fn stream_traffic(mut stream: TcpStream, traffic: &Traffic) -> std::io::Result<()> {
    stream
        .write_all(
            b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
        )
        .await?;
    let mut last = traffic.totals();
    let mut ticker = tokio::time::interval(TRAFFIC_INTERVAL);
    ticker.tick().await;
    loop {
        ticker.tick().await;
        let now = traffic.totals();
        let line = format!(
            "{}\n",
            json!({ "up": now.0.saturating_sub(last.0), "down": now.1.saturating_sub(last.1) })
        );
        last = now;
        stream
            .write_all(format!("{:x}\r\n{line}\r\n", line.len()).as_bytes())
            .await?;
    }
}
