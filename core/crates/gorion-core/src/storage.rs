//! Хранилище профилей: `profiles.json` + шаблоны в `profiles/<id>.json`.
//! Формат и раскладка совпадают с Flutter-версией, поэтому подписки
//! пользователя переезжают в нативное приложение без миграции.
//! Эталон: `lib/features/profiles/data/profile_repository.dart`.
//!
//! Δ к эталону: запись атомарная (временный файл + rename) — сбой
//! посреди записи больше не оставляет обрезанный `profiles.json`.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::error::{CoreError, CoreResult};
use crate::model::{AUTO_SELECT_SERVER_TAG, ParsedSubscription, ProxyProfile, StoredProfilesState};

#[derive(Debug, Clone)]
pub struct ProfileStore {
    root: PathBuf,
}

impl ProfileStore {
    /// `root` — каталог `…/Application Support/app.gorion.client/gorion`.
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    fn index_path(&self) -> PathBuf {
        self.root.join("profiles.json")
    }

    fn template_path(&self, file_name: &str) -> CoreResult<PathBuf> {
        // Имя файла приходит из profiles.json — не даём выйти за каталог.
        let safe = Path::new(file_name)
            .file_name()
            .filter(|name| *name == std::ffi::OsStr::new(file_name))
            .ok_or_else(|| CoreError::Storage(format!("недопустимое имя шаблона: {file_name}")))?;
        Ok(self.root.join("profiles").join(safe))
    }

    pub async fn load_state(&self) -> CoreResult<StoredProfilesState> {
        Ok(read_json(&self.index_path()).await?.unwrap_or_default())
    }

    pub async fn load_template(&self, profile: &ProxyProfile) -> CoreResult<String> {
        let path = self.template_path(&profile.template_file_name)?;
        tokio::fs::read_to_string(&path)
            .await
            .map_err(|e| CoreError::InvalidTemplate(format!("{}: {e}", path.display())))
    }

    pub async fn add_subscription(
        &self,
        url: &str,
        parsed: ParsedSubscription,
    ) -> CoreResult<StoredProfilesState> {
        let state = self.load_state().await?;
        let id = uuid::Uuid::new_v4().to_string();
        let template_file_name = format!("{id}.json");
        let now = now_iso();
        let first = parsed.servers.first().map(|s| s.tag.clone());
        let profile = ProxyProfile {
            id: id.clone(),
            name: parsed.name,
            subscription_url: url.trim().to_owned(),
            template_file_name: template_file_name.clone(),
            created_at: now.clone(),
            updated_at: now,
            servers: parsed.servers,
            subscription_info: parsed.subscription_info,
            last_selected_server_tag: first.clone(),
            last_auto_selected_server_tag: first,
        };
        write_atomic(
            &self.template_path(&template_file_name)?,
            parsed.normalized_config_json.as_bytes(),
        )
        .await?;
        let mut profiles = vec![profile];
        profiles.extend(state.profiles);
        let next = StoredProfilesState {
            active_profile_id: state.active_profile_id.or(Some(id)),
            profiles,
        };
        self.write_state(&next).await?;
        Ok(next)
    }

    /// Обновляет подписку, сохраняя выбор пользователя, если сервер остался.
    pub async fn apply_refresh(
        &self,
        profile_id: &str,
        parsed: ParsedSubscription,
    ) -> CoreResult<StoredProfilesState> {
        let mut state = self.load_state().await?;
        let index = profile_index(&state, profile_id)?;
        let current = state.profiles[index].clone();
        let has =
            |tag: Option<&str>| tag.is_some_and(|t| parsed.servers.iter().any(|s| s.tag == t));
        let first = parsed.servers.first().map(|s| s.tag.clone());
        let selection = if current.prefers_auto_selection() {
            Some(AUTO_SELECT_SERVER_TAG.to_owned())
        } else if has(current.selected_server_tag()) {
            current.selected_server_tag().map(str::to_owned)
        } else {
            first.clone()
        };
        let auto_selection = if has(current.resolved_auto_selected_server_tag()) {
            current
                .resolved_auto_selected_server_tag()
                .map(str::to_owned)
        } else {
            first
        };
        write_atomic(
            &self.template_path(&current.template_file_name)?,
            parsed.normalized_config_json.as_bytes(),
        )
        .await?;
        let profile = &mut state.profiles[index];
        profile.name = parsed.name;
        profile.updated_at = now_iso();
        profile.servers = parsed.servers;
        profile.subscription_info = parsed.subscription_info;
        profile.last_selected_server_tag = selection;
        profile.last_auto_selected_server_tag = auto_selection;
        self.write_state(&state).await?;
        Ok(state)
    }

    pub async fn set_active_profile(&self, profile_id: &str) -> CoreResult<StoredProfilesState> {
        let mut state = self.load_state().await?;
        profile_index(&state, profile_id)?;
        state.active_profile_id = Some(profile_id.to_owned());
        self.write_state(&state).await?;
        Ok(state)
    }

    pub async fn update_selected_server(
        &self,
        profile_id: &str,
        tag: &str,
    ) -> CoreResult<StoredProfilesState> {
        self.update_profile(profile_id, |p| {
            p.last_selected_server_tag = Some(tag.to_owned())
        })
        .await
    }

    pub async fn update_auto_selected_server(
        &self,
        profile_id: &str,
        tag: &str,
    ) -> CoreResult<StoredProfilesState> {
        self.update_profile(profile_id, |p| {
            p.last_auto_selected_server_tag = Some(tag.to_owned())
        })
        .await
    }

    pub async fn rename_profile(
        &self,
        profile_id: &str,
        name: &str,
    ) -> CoreResult<StoredProfilesState> {
        self.update_profile(profile_id, |p| p.name = name.trim().to_owned())
            .await
    }

    async fn update_profile(
        &self,
        profile_id: &str,
        change: impl FnOnce(&mut ProxyProfile),
    ) -> CoreResult<StoredProfilesState> {
        let mut state = self.load_state().await?;
        if let Some(profile) = state.profiles.iter_mut().find(|p| p.id == profile_id) {
            change(profile);
        }
        self.write_state(&state).await?;
        Ok(state)
    }

    /// Удаляет профиль. Возвращает удалённый профиль и его шаблон, чтобы
    /// интерфейс мог предложить «Вернуть» (см. [`Self::restore_profile`]).
    pub async fn remove_profile(
        &self,
        profile_id: &str,
    ) -> CoreResult<(StoredProfilesState, RemovedProfile)> {
        let state = self.load_state().await?;
        let index = profile_index(&state, profile_id)?;
        let profile = state.profiles[index].clone();
        let template = self.load_template(&profile).await.ok();
        let profiles: Vec<ProxyProfile> = state
            .profiles
            .iter()
            .filter(|p| p.id != profile_id)
            .cloned()
            .collect();
        let active = if state.active_profile_id.as_deref() == Some(profile_id) {
            profiles.first().map(|p| p.id.clone())
        } else {
            state.active_profile_id.clone()
        };
        let next = StoredProfilesState {
            active_profile_id: active,
            profiles,
        };
        self.write_state(&next).await?;
        // Индекс главный: осиротевший шаблон безопаснее профиля без шаблона.
        if let Ok(path) = self.template_path(&profile.template_file_name) {
            let _ = tokio::fs::remove_file(path).await;
        }
        let was_active = state.active_profile_id.as_deref() == Some(profile_id);
        Ok((
            next,
            RemovedProfile {
                profile,
                template,
                index,
                was_active,
            },
        ))
    }

    pub async fn restore_profile(
        &self,
        removed: RemovedProfile,
    ) -> CoreResult<StoredProfilesState> {
        let mut state = self.load_state().await?;
        if state.profile(&removed.profile.id).is_some() {
            return Ok(state);
        }
        if let Some(template) = &removed.template {
            write_atomic(
                &self.template_path(&removed.profile.template_file_name)?,
                template.as_bytes(),
            )
            .await?;
        }
        let index = removed.index.min(state.profiles.len());
        if removed.was_active || state.active_profile_id.is_none() {
            state.active_profile_id = Some(removed.profile.id.clone());
        }
        state.profiles.insert(index, removed.profile);
        self.write_state(&state).await?;
        Ok(state)
    }

    async fn write_state(&self, state: &StoredProfilesState) -> CoreResult<()> {
        write_json(&self.index_path(), state).await
    }
}

/// Удалённый профиль для отмены удаления.
#[derive(Debug, Clone)]
pub struct RemovedProfile {
    pub profile: ProxyProfile,
    pub template: Option<String>,
    pub index: usize,
    pub was_active: bool,
}

fn profile_index(state: &StoredProfilesState, profile_id: &str) -> CoreResult<usize> {
    state
        .profiles
        .iter()
        .position(|p| p.id == profile_id)
        .ok_or_else(|| CoreError::ProfileNotFound(profile_id.to_owned()))
}

pub fn now_iso() -> String {
    chrono::Local::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, false)
}

/// JSON-файл или `None`, если файла нет или он пустой.
pub async fn read_json<T: DeserializeOwned>(path: &Path) -> CoreResult<Option<T>> {
    let text = match tokio::fs::read_to_string(path).await {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(CoreError::Storage(format!("{}: {e}", path.display()))),
    };
    if text.trim().is_empty() {
        return Ok(None);
    }
    serde_json::from_str(&text)
        .map(Some)
        .map_err(|e| CoreError::Storage(format!("{}: {e}", path.display())))
}

pub async fn write_json<T: Serialize>(path: &Path, value: &T) -> CoreResult<()> {
    let text =
        serde_json::to_string_pretty(value).map_err(|e| CoreError::Internal(e.to_string()))?;
    write_atomic(path, text.as_bytes()).await
}

/// Запись через временный файл и rename: файл либо старый, либо новый целиком.
pub async fn write_atomic(path: &Path, bytes: &[u8]) -> CoreResult<()> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent).await?;
    }
    let mut pending = path.as_os_str().to_owned();
    pending.push(".tmp");
    let pending = PathBuf::from(pending);
    {
        use tokio::io::AsyncWriteExt;
        let mut file = tokio::fs::File::create(&pending).await?;
        file.write_all(bytes).await?;
        file.sync_all().await?;
    }
    tokio::fs::rename(&pending, path).await?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used)]

    use super::*;
    use crate::model::ServerEntry;

    fn parsed(tags: &[&str]) -> ParsedSubscription {
        ParsedSubscription {
            name: "Sub".into(),
            normalized_config_json: "{\"outbounds\":[]}".into(),
            servers: tags
                .iter()
                .map(|t| ServerEntry {
                    tag: (*t).into(),
                    display_name: (*t).into(),
                    kind: "vless".into(),
                    host: None,
                    port: None,
                    config_fingerprint: None,
                })
                .collect(),
            subscription_info: None,
        }
    }

    #[tokio::test]
    async fn add_refresh_remove_restore() {
        let dir = tempfile::tempdir().unwrap();
        let store = ProfileStore::new(dir.path());
        let state = store
            .add_subscription(" https://x/sub ", parsed(&["a", "b"]))
            .await
            .unwrap();
        let id = state.profiles[0].id.clone();
        assert_eq!(state.active_profile_id.as_deref(), Some(id.as_str()));
        assert_eq!(state.profiles[0].subscription_url, "https://x/sub");

        store.update_selected_server(&id, "b").await.unwrap();
        let state = store.apply_refresh(&id, parsed(&["b", "c"])).await.unwrap();
        assert_eq!(
            state.profiles[0].last_selected_server_tag.as_deref(),
            Some("b")
        );
        assert_eq!(
            state.profiles[0].last_auto_selected_server_tag.as_deref(),
            Some("b")
        );

        let state = store.apply_refresh(&id, parsed(&["c"])).await.unwrap();
        assert_eq!(
            state.profiles[0].last_selected_server_tag.as_deref(),
            Some("c")
        );

        let (state, removed) = store.remove_profile(&id).await.unwrap();
        assert!(state.profiles.is_empty());
        assert_eq!(state.active_profile_id, None);
        let state = store.restore_profile(removed).await.unwrap();
        assert_eq!(state.active_profile_id.as_deref(), Some(id.as_str()));
        assert!(store.load_template(&state.profiles[0]).await.is_ok());
    }

    #[tokio::test]
    async fn reads_flutter_written_index() {
        let dir = tempfile::tempdir().unwrap();
        let json = r#"{"activeProfileId":"p1","profiles":[{"id":"p1","name":"Old","subscriptionUrl":"https://s","templateFileName":"p1.json","createdAt":"2026-09-01T10:00:00.000","updatedAt":"2026-09-01T10:00:00.000","servers":[{"tag":"a","displayName":"a","type":"vless","host":"h","port":443,"configFingerprint":"-1"},"junk"],"subscriptionInfo":null,"lastSelectedServerTag":"gorion-auto-selector","lastAutoSelectedServerTag":"a"}]}"#;
        tokio::fs::write(dir.path().join("profiles.json"), json)
            .await
            .unwrap();
        let state = ProfileStore::new(dir.path()).load_state().await.unwrap();
        let profile = state.active_profile().unwrap();
        assert_eq!(profile.servers.len(), 1);
        assert!(profile.prefers_auto_selection());
        assert_eq!(profile.startup_server_tag(), Some("a"));
    }

    #[tokio::test]
    async fn rejects_template_path_traversal() {
        let dir = tempfile::tempdir().unwrap();
        let store = ProfileStore::new(dir.path());
        assert!(store.template_path("../evil.json").is_err());
        assert!(store.template_path("ok.json").is_ok());
    }
}
