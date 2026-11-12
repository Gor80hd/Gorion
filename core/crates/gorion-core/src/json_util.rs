//! Мелкие помощники для работы с JSON в стиле Dart-эталона, где значения
//! читаются через `toString()`.

use serde_json::{Map, Value};

pub fn as_object(value: &Value) -> Option<&Map<String, Value>> {
    value.as_object()
}

/// `value?.toString().trim() ?? ''`.
pub fn value_to_trimmed_string(value: Option<&Value>) -> String {
    match value {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.trim().to_owned(),
        Some(other) => other.to_string().trim().to_owned(),
    }
}

/// `_trimToNull`: строковое представление без пробелов или `None`.
pub fn trim_to_none(value: Option<&Value>) -> Option<String> {
    let text = value_to_trimmed_string(value);
    (!text.is_empty()).then_some(text)
}

/// Копия объекта или пустой объект (`_cloneMap`).
pub fn clone_map(value: Option<&Value>) -> Map<String, Value> {
    value
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default()
}

/// Только объекты из массива (`_cloneList`).
pub fn clone_list(value: Option<&Value>) -> Vec<Map<String, Value>> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|v| v.as_object().cloned())
                .collect()
        })
        .unwrap_or_default()
}

pub fn objects_to_values(items: Vec<Map<String, Value>>) -> Value {
    Value::Array(items.into_iter().map(Value::Object).collect())
}
