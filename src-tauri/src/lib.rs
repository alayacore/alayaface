//! AlayaFace — A Tauri GUI frontend for AlayaCore.
//!
//! Architecture:
//!   lib.rs        — App entry point, Tauri builder, shared state types
//!   tlv.rs        — TLV wire protocol encoding/decoding
//!   alayacore.rs  — Subprocess spawn & binary discovery
//!   session.rs    — Session lifecycle (create, close, fork)
//!   reader.rs     — Background stdout/stderr readers, frame dispatch
//!   commands.rs   — All Tauri IPC commands
//!   dirs.rs       — Directory structure & config management
//!   event.rs      — Tauri event payload types

pub mod alayacore;
pub mod commands;
pub mod dirs;
pub mod event;
pub mod reader;
pub mod session;
pub mod tlv;

use std::collections::HashMap;
use std::sync::Arc;

/// Shared model cache — populated from `model_list` SM messages.
/// Uses std::sync::Mutex because it's accessed from sync stdout reader
/// threads. Set wakes waiters (tokio::sync::Notify) so list_models can
/// wait instead of polling — wait_non_empty re-checks after registering
/// the waiter, so a model list that arrived just before cannot be
/// missed (M6/D6; mirrors the Go session.ModelCache guard).
pub struct ModelCache(pub Arc<ModelCacheInner>);

pub struct ModelCacheInner {
    models: std::sync::Mutex<Vec<serde_json::Value>>,
    notify: tokio::sync::Notify,
}

impl ModelCache {
    pub fn new() -> Self {
        Self(Arc::new(ModelCacheInner {
            models: std::sync::Mutex::new(Vec::new()),
            notify: tokio::sync::Notify::new(),
        }))
    }

    /// Replace the cached models and wake every waiter.
    pub fn set(&self, models: Vec<serde_json::Value>) {
        self.0.set(models);
    }

    /// Copy of the cached models.
    pub fn get(&self) -> Vec<serde_json::Value> {
        self.0.get()
    }

    /// True while the cache holds no models.
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    /// Wait until the cache holds models.
    pub async fn wait_non_empty(&self) {
        self.0.wait_non_empty().await;
    }
}

impl ModelCacheInner {
    /// Replace the cached models and wake every waiter.
    pub fn set(&self, models: Vec<serde_json::Value>) {
        {
            let mut m = self.models.lock().unwrap();
            *m = models;
        }
        self.notify.notify_waiters();
    }

    /// Copy of the cached models.
    pub fn get(&self) -> Vec<serde_json::Value> {
        self.models.lock().unwrap().clone()
    }

    /// True while the cache holds no models.
    pub fn is_empty(&self) -> bool {
        self.models.lock().unwrap().is_empty()
    }

    /// Wait until the cache holds models. Race-free: the condition is
    /// re-checked AFTER the waiter is registered, so a Set that landed
    /// between the first check and registration is observed (either the
    /// re-check sees it, or notify_waiters wakes the registered waiter).
    pub async fn wait_non_empty(&self) {
        loop {
            {
                let m = self.models.lock().unwrap();
                if !m.is_empty() {
                    return;
                }
            }
            let notified = self.notify.notified();
            tokio::pin!(notified);
            {
                let m = self.models.lock().unwrap();
                if !m.is_empty() {
                    return;
                }
            }
            notified.as_mut().await;
        }
    }
}

impl Default for ModelCache {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(session::SessionMap(Arc::new(tokio::sync::Mutex::new(HashMap::new()))))
        .manage(ModelCache::new())
        .invoke_handler(tauri::generate_handler![
            commands::create_session,
            commands::resume_session,
            commands::close_session,
            commands::close_all_sessions,
            commands::list_session_dirs,
            commands::delete_session_dir,
            commands::alayacore_send_prompt,
            commands::alayacore_model_set,
            commands::alayacore_cancel,
            commands::alayacore_model_sync,
            commands::alayacore_confirm,
            commands::alayacore_mcp_decline,
            commands::alayacore_mcp_cancel,
            commands::fork_session,
            commands::list_models,
            commands::list_default_models,
            commands::sync_default_models,
            commands::fs_list_dir,
            commands::fs_home_dir,
            commands::fs_resolve_path,
            commands::fs_read_file_data_uri,
            commands::fs_write_file_text,
            commands::fs_read_file_text,
            commands::fs_delete_file,
            commands::start_mcp_auth_flow,
            commands::fill_mcp_auth_url,
            commands::list_default_mcp,
            commands::sync_default_mcp,
            commands::list_presets,
            commands::copy_preset,
            commands::rename_preset,
            commands::delete_preset,
            commands::set_active_preset,
            commands::get_global_settings,
            commands::sync_global_settings,
            commands::get_global_config,
            commands::sync_global_config,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}

#[cfg(test)]
mod tests {
    use super::*;

    // M6 (D6): wait semantics — set() wakes waiters instead of
    // polling; wait_non_empty can never miss a model list that arrived
    // while the waiter was registering (re-check after registration).
    // Mirrors the Go model_cache_test.go cases.

    #[tokio::test]
    async fn model_cache_set_wakes_waiters() {
        let c = ModelCache::new();
        let inner = c.0.clone();
        let waiter = tokio::spawn(async move {
            tokio::time::timeout(std::time::Duration::from_secs(1), inner.wait_non_empty()).await
        });
        // Give the waiter time to register.
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        c.set(vec![serde_json::json!({"id": 1})]);
        assert!(waiter.await.unwrap().is_ok(), "waiter was not woken by set");
        assert!(!c.is_empty());
        assert_eq!(c.get()[0]["id"], 1);
    }

    #[tokio::test]
    async fn model_cache_wait_returns_immediately_when_non_empty() {
        let c = ModelCache::new();
        c.set(vec![serde_json::json!({"id": 1})]);
        tokio::time::timeout(std::time::Duration::from_millis(100), c.wait_non_empty())
            .await
            .expect("wait_non_empty on a non-empty cache must return immediately");
    }

    #[tokio::test]
    async fn model_cache_set_between_check_and_registration_is_not_missed() {
        let c = ModelCache::new();
        let inner = c.0.clone();
        let waiter = tokio::spawn(async move {
            tokio::time::timeout(std::time::Duration::from_secs(1), inner.wait_non_empty()).await
        });
        // Let the waiter run its first (empty) check, then set — the
        // race window a poll-free waiter must close.
        tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        c.set(vec![serde_json::json!({"id": 1})]);
        assert!(waiter.await.unwrap().is_ok(), "set after the first check was missed");
    }

    #[tokio::test]
    async fn model_cache_get_returns_a_copy() {
        let c = ModelCache::new();
        c.set(vec![serde_json::json!({"id": 1})]);
        let mut got = c.get();
        got[0] = serde_json::json!({"id": 9});
        assert_eq!(c.get()[0]["id"], 1, "get returned a shared vector");
    }
}
