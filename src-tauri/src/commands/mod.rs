//! Tauri commands for the AlayaFace application.
//!
//! Re-exports from sub-modules. Shared helpers live here.

pub mod sessions;
pub mod io;
pub mod cmd;
pub mod mcp;
pub mod fs;
pub mod models;
pub mod presets;
pub mod settings;
pub mod global_config;
pub mod objects;

pub use crate::session::SessionMap;
pub use sessions::*;
pub use io::*;
pub use cmd::*;
pub use mcp::*;
pub use fs::*;
pub use models::*;
pub use presets::*;
pub use settings::*;
pub use global_config::*;
pub use objects::*;

use crate::alayacore;
use crate::tlv;

use serde::Serialize;
use std::io::Write;

#[derive(Serialize)]
pub struct SessionDirInfo {
    pub id: String,
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
    let mut guard = handle.stdin.lock().await;
    let stdin = guard
        .as_mut()
        .ok_or_else(|| "Session is disconnected".to_string())?;
    tlv::write_frame(stdin, tag, value).map_err(|e| format!("Write error: {e}"))?;
    stdin.flush().map_err(|e| format!("Flush error: {e}"))?;

    // Log outgoing frame for debugging
    let preview: String = value.chars().take(200).collect();
    log::info!("[tlv] >> {} {} {}b {}", session_id, tag, value.len(), preview);

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
    handle.pending_commands.insert(id.clone(), name.to_string()).await;
    let payload = serde_json::json!({ "id": id, "name": name, "input": input });
    if let Err(e) = send_raw(map, session_id, tlv::TAG_CMD_INPUT, &payload.to_string()).await {
        handle.pending_commands.remove(&id).await;
        return Err(e);
    }
    Ok(id)
}

/// Wait for a file to stabilize (size unchanged for ~300ms), with a
/// 10-second deadline. Requiring several consecutive unchanged polls
/// (instead of one 50ms tick) prevents returning on a file that is
/// still being written in chunks; the longer deadline accommodates
/// large session forks.
pub(crate) async fn wait_for_file(path: &str) -> Result<(), String> {
    let target_path = std::path::Path::new(path);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    let mut seen_size = 0u64;
    let mut stable_ticks = 0u32;
    const STABLE_WINDOW: u32 = 6; // 6 × 50ms ≈ 300ms unchanged

    loop {
        if let Ok(meta) = target_path.metadata() {
            let len = meta.len();
            if len > 0 {
                if len == seen_size {
                    stable_ticks += 1;
                    if stable_ticks >= STABLE_WINDOW {
                        return Ok(());
                    }
                } else {
                    seen_size = len;
                    stable_ticks = 1;
                }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn wait_for_file_waits_for_stability() {
        let dir = std::env::temp_dir().join(format!(
            "alayaface-wff-{}-{}",
            std::process::id(),
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("fork.out");
        let path_str = path.to_string_lossy().to_string();
        let final_text = "chunk1-chunk2";

        std::fs::write(&path, "chunk1").unwrap();
        let handle = tokio::spawn(async move { wait_for_file(&path_str).await });
        // The second chunk lands while wait_for_file is mid-polling.
        tokio::time::sleep(std::time::Duration::from_millis(120)).await;
        std::fs::write(&path, final_text).unwrap();
        handle.await.unwrap().unwrap();

        assert_eq!(
            std::fs::metadata(&path).unwrap().len(),
            final_text.len() as u64,
            "wait_for_file returned with a partially-written file"
        );
        let _ = std::fs::remove_dir_all(&dir);
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
