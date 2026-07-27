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
            commands::list_sessions,
            commands::list_session_dirs,
            commands::delete_session_dir,
            commands::session_connected,
            commands::alayacore_send_message,
            commands::alayacore_send_prompt,
            commands::alayacore_model_set,
            commands::alayacore_cancel,
            commands::alayacore_save,
            commands::alayacore_fork,
            commands::fork_session,
            commands::alayacore_reason,
            commands::alayacore_theme_set,
            commands::alayacore_model_load,
            commands::alayacore_model_sync,
            commands::alayacore_video_config,
            commands::alayacore_continue,
            commands::alayacore_summarize,
            commands::alayacore_confirm,
            commands::alayacore_send_raw_frame,
            commands::get_stderr_log,
            commands::list_models,
            commands::fs_list_dir,
            commands::fs_home_dir,
            commands::fs_resolve_path,
            commands::fs_read_file_data_uri,
            commands::start_mcp_auth_flow,
            commands::fill_mcp_auth_url,
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
