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
/// Uses std::sync::Mutex because it's accessed from sync stdout reader threads.
pub struct ModelCache(pub Arc<std::sync::Mutex<Vec<serde_json::Value>>>);

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info"))
        .format_timestamp_millis()
        .init();

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .manage(session::SessionMap(Arc::new(tokio::sync::Mutex::new(HashMap::new()))))
        .manage(ModelCache(Arc::new(std::sync::Mutex::new(Vec::new()))))
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
