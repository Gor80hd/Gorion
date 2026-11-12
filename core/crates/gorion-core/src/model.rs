//! Модели профилей. JSON совместим с файлами Flutter-версии
//! (`profiles.json`), поэтому существующие подписки пользователя читаются
//! без миграции. Эталон: `lib/features/profiles/model/profile_models.dart`.

use serde::{Deserialize, Deserializer, Serialize};

/// Тег псевдосервера «Автовыбор».
pub const AUTO_SELECT_SERVER_TAG: &str = "gorion-auto-selector";

pub fn is_auto_select_tag(tag: Option<&str>) -> bool {
    tag == Some(AUTO_SELECT_SERVER_TAG)
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SubscriptionInfo {
    #[serde(default, deserialize_with = "lenient_i64")]
    pub upload: i64,
    #[serde(default, deserialize_with = "lenient_i64")]
    pub download: i64,
    #[serde(default, deserialize_with = "lenient_i64")]
    pub total: i64,
    /// ISO 8601, как пишет Dart (`toIso8601String`).
    #[serde(default)]
    pub expire_at: Option<String>,
    #[serde(default)]
    pub web_page_url: Option<String>,
    #[serde(default)]
    pub support_url: Option<String>,
}

impl SubscriptionInfo {
    pub fn consumed(&self) -> i64 {
        self.upload + self.download
    }

    pub fn remaining(&self) -> Option<i64> {
        (self.total > 0).then(|| self.total - self.consumed())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerEntry {
    #[serde(default, deserialize_with = "lenient_string")]
    pub tag: String,
    #[serde(default, deserialize_with = "lenient_string")]
    pub display_name: String,
    #[serde(default, deserialize_with = "lenient_string", rename = "type")]
    pub kind: String,
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default, deserialize_with = "lenient_opt_i64")]
    pub port: Option<i64>,
    #[serde(default)]
    pub config_fingerprint: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProxyProfile {
    #[serde(default, deserialize_with = "lenient_string")]
    pub id: String,
    #[serde(default, deserialize_with = "lenient_string")]
    pub name: String,
    #[serde(default, deserialize_with = "lenient_string")]
    pub subscription_url: String,
    #[serde(default, deserialize_with = "lenient_string")]
    pub template_file_name: String,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
    #[serde(default, deserialize_with = "lenient_servers")]
    pub servers: Vec<ServerEntry>,
    #[serde(default, deserialize_with = "lenient_subscription_info")]
    pub subscription_info: Option<SubscriptionInfo>,
    #[serde(default)]
    pub last_selected_server_tag: Option<String>,
    #[serde(default)]
    pub last_auto_selected_server_tag: Option<String>,
}

impl ProxyProfile {
    fn contains_tag(&self, tag: Option<&str>) -> bool {
        match tag {
            Some(tag) if !tag.is_empty() => self.servers.iter().any(|s| s.tag == tag),
            _ => false,
        }
    }

    /// Выбранный пользователем сервер или автовыбор; иначе первый.
    pub fn selected_server_tag(&self) -> Option<&str> {
        let last = self.last_selected_server_tag.as_deref();
        if is_auto_select_tag(last) {
            return Some(AUTO_SELECT_SERVER_TAG);
        }
        if self.contains_tag(last) {
            return last;
        }
        self.servers.first().map(|s| s.tag.as_str())
    }

    pub fn prefers_auto_selection(&self) -> bool {
        is_auto_select_tag(self.selected_server_tag())
    }

    pub fn resolved_auto_selected_server_tag(&self) -> Option<&str> {
        let tag = self.last_auto_selected_server_tag.as_deref();
        if self.contains_tag(tag) { tag } else { None }
    }

    /// Сервер, с которого начинается подключение.
    pub fn startup_server_tag(&self) -> Option<&str> {
        let first = self.servers.first()?.tag.as_str();
        if self.prefers_auto_selection() {
            return Some(self.resolved_auto_selected_server_tag().unwrap_or(first));
        }
        self.selected_server_tag()
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StoredProfilesState {
    #[serde(default)]
    pub active_profile_id: Option<String>,
    #[serde(default, deserialize_with = "lenient_profiles")]
    pub profiles: Vec<ProxyProfile>,
}

impl StoredProfilesState {
    pub fn active_profile(&self) -> Option<&ProxyProfile> {
        let id = self
            .active_profile_id
            .as_deref()
            .filter(|id| !id.is_empty())?;
        self.profiles.iter().find(|p| p.id == id)
    }

    pub fn profile(&self, id: &str) -> Option<&ProxyProfile> {
        self.profiles.iter().find(|p| p.id == id)
    }
}

/// Результат разбора подписки.
#[derive(Debug, Clone, PartialEq)]
pub struct ParsedSubscription {
    pub name: String,
    pub normalized_config_json: String,
    pub servers: Vec<ServerEntry>,
    pub subscription_info: Option<SubscriptionInfo>,
}

// Dart-версия читает поля через `toString()` и пропускает элементы не того
// типа. Повторяем эту терпимость, чтобы старые файлы не ломали загрузку.

fn lenient_string<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    let value = serde_json::Value::deserialize(d)?;
    Ok(match value {
        serde_json::Value::Null => String::new(),
        serde_json::Value::String(s) => s,
        other => other.to_string(),
    })
}

fn lenient_i64<'de, D: Deserializer<'de>>(d: D) -> Result<i64, D::Error> {
    Ok(lenient_opt_i64(d)?.unwrap_or(0))
}

fn lenient_opt_i64<'de, D: Deserializer<'de>>(d: D) -> Result<Option<i64>, D::Error> {
    let value = serde_json::Value::deserialize(d)?;
    Ok(match value {
        serde_json::Value::Number(n) => n.as_i64().or_else(|| n.as_f64().map(|f| f as i64)),
        _ => None,
    })
}

fn lenient_servers<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<ServerEntry>, D::Error> {
    lenient_list(d)
}

fn lenient_profiles<'de, D: Deserializer<'de>>(d: D) -> Result<Vec<ProxyProfile>, D::Error> {
    lenient_list(d)
}

fn lenient_list<'de, D: Deserializer<'de>, T: serde::de::DeserializeOwned>(
    d: D,
) -> Result<Vec<T>, D::Error> {
    let value = serde_json::Value::deserialize(d)?;
    let serde_json::Value::Array(items) = value else {
        return Ok(Vec::new());
    };
    Ok(items
        .into_iter()
        .filter(|item| item.is_object())
        .filter_map(|item| serde_json::from_value(item).ok())
        .collect())
}

fn lenient_subscription_info<'de, D: Deserializer<'de>>(
    d: D,
) -> Result<Option<SubscriptionInfo>, D::Error> {
    let value = serde_json::Value::deserialize(d)?;
    if !value.is_object() {
        return Ok(None);
    }
    Ok(serde_json::from_value(value).ok())
}
