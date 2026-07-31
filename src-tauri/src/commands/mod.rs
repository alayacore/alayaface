//! Tauri commands for the AlayaFace application.
//!
//! Re-exports from sub-modules. Shared helpers live here.

pub mod sessions;
pub mod io;
pub mod cmd;
pub mod mcp;
pub mod fs;
pub mod models;

pub use crate::session::SessionMap;
pub use sessions::*;
pub use io::*;
pub use cmd::*;
pub use mcp::*;
pub use fs::*;
pub use models::*;

use crate::alayacore;
use crate::tlv;

use serde::Serialize;
use std::io::Write;

#[derive(Serialize)]
pub struct SessionDirInfo {
    pub id: String,
    pub has_session_file: bool,
    pub created_at: String,
}

#[derive(serde::Deserialize)]
pub struct MediaItem {
    pub media_type: String,
    pub uri: String,
}

// ─── Shared Helpers ──────────────────────────────────────────────────

/// Send a raw TLV frame to a session's stdin.
pub(crate) async fn send_raw(
    map: &std::collections::HashMap<String, crate::session::SessionHandle>,
    session_id: &str,
    tag: &str,
    value: &str,
) -> Result<(), String> {
    let handle = crate::session::get(map, session_id)?;
    if !handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("Session is disconnected".to_string());
    }
    let mut stdin = handle.stdin.lock().await;
    tlv::write_frame(&mut *stdin, tag, value).map_err(|e| format!("Write error: {e}"))?;
    stdin.flush().map_err(|e| format!("Flush error: {e}"))?;

    // Log outgoing frame for debugging
    let preview: String = value.chars().take(200).collect();
    log::debug!("[tlv] >> {} {} {}b {}", session_id, tag, value.len(), preview);

    Ok(())
}

/// Resolve the alayacore binary path.
pub(crate) fn resolve_binary(binary_path: &str) -> String {
    if binary_path.is_empty() {
        alayacore::find_binary()
    } else {
        binary_path.to_string()
    }
}

/// Send a command to a session as a CI frame (the new command RPC protocol).
///
/// Generates a call ID, serializes `{"id","name","input"}` into a CI frame,
/// and records the call ID → name mapping so the stdout reader can attach
/// the command name to the matching CO frame (CO carries only the ID).
/// Returns the generated call ID on success.
pub(crate) async fn send_cmd(
    map: &std::collections::HashMap<String, crate::session::SessionHandle>,
    session_id: &str,
    name: &str,
    input: &str,
) -> Result<String, String> {
    let id = uuid::Uuid::new_v4().to_string();
    // Register the mapping BEFORE writing the frame — the CO reply can
    // arrive as soon as the CI frame is flushed.
    let handle = crate::session::get(map, session_id)?;
    handle.pending_commands.lock().await.insert(id.clone(), name.to_string());
    let payload = serde_json::json!({ "id": id, "name": name, "input": input });
    if let Err(e) = send_raw(map, session_id, tlv::TAG_CMD_INPUT, &payload.to_string()).await {
        handle.pending_commands.lock().await.remove(&id);
        return Err(e);
    }
    Ok(id)
}

/// Wait for a file to stabilize (size unchanged for a short period).
pub(crate) async fn wait_for_file(path: &str) -> Result<(), String> {
    let target_path = std::path::Path::new(path);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut seen_size = 0u64;

    loop {
        if let Ok(meta) = target_path.metadata() {
            let len = meta.len();
            if len > 0 && len == seen_size {
                return Ok(());
            }
            if len > 0 {
                seen_size = len;
            }
        }
        if std::time::Instant::now() > deadline {
            if seen_size > 0 {
                return Ok(());
            }
            return Err("Timeout waiting for fork to complete".to_string());
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

/// Macro to generate simple command functions that send a fixed command
/// (no arguments) to the session as a CI frame.
#[macro_export]
macro_rules! send_cmd {
    ($name:ident, $cmd_name:expr) => {
        #[tauri::command]
        pub async fn $name(
            session_id: String,
            sessions: State<'_, SessionMap>,
        ) -> Result<(), String> {
            let map = sessions.0.lock().await;
            $crate::commands::send_cmd(&map, &session_id, $cmd_name, "")
                .await
                .map(|_| ())
        }
    };
}
