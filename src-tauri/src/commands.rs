//! Tauri commands for the AlayaFace application.
//!
//! These are the IPC endpoints exposed to the React frontend.
//! Each command delegates to the appropriate module for business logic.

use crate::alayacore;
use crate::session::{self, SessionMap};
use crate::tlv;
use crate::dirs;
use crate::ModelCache;

use serde::Serialize;
use std::io::Write;
use tauri::{AppHandle, State};
use uuid::Uuid;

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

// ─── Session Lifecycle ───────────────────────────────────────────────

#[tauri::command]
pub async fn create_session(
    app: AppHandle,
    binary_path: String,
    config_path: String,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let (_template_dir, sessions_dir) = dirs::ensure()?;

    let bin = resolve_binary(&binary_path);
    let session_id = Uuid::new_v4().to_string();
    let session_dir = dirs::create_session_dir(&sessions_dir, &session_id)?;

    let effective_config = if config_path.is_empty() {
        session_dir.join("config").to_string_lossy().to_string()
    } else {
        config_path
    };
    let session_file = session_dir.join("session.md").to_string_lossy().to_string();

    eprintln!("[alayaface] Spawning: {} --rawio --config-path {} --session {}", &bin, &effective_config, &session_file);

    session::create(&app, &bin, &effective_config, &session_file, session_dir, &sessions, &model_cache).await
}

#[tauri::command]
pub async fn resume_session(
    app: AppHandle,
    session_id: String,
    binary_path: String,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let sessions_dir = dirs::alayaface_dir().join("sessions").join(&session_id);
    let session_file = sessions_dir.join("session.md");
    let config_dir = sessions_dir.join("config");

    if !sessions_dir.exists() {
        return Err(format!("Session directory not found: {:?}", sessions_dir));
    }
    if !session_file.exists() {
        return Err(format!("Session file not found: {:?}", session_file));
    }
    if !config_dir.exists() {
        return Err(format!("Config directory not found: {:?}", config_dir));
    }

    // Check not already running
    if sessions.0.lock().await.contains_key(&session_id) {
        return Err("Session is already active".to_string());
    }

    let bin = resolve_binary(&binary_path);
    let config_path = config_dir.to_string_lossy().to_string();
    let session_path = session_file.to_string_lossy().to_string();

    session::create(&app, &bin, &config_path, &session_path, sessions_dir, &sessions, &model_cache).await
}

#[tauri::command]
pub async fn close_session(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    session::close(&session_id, &sessions).await
}

#[tauri::command]
pub async fn list_sessions(
    sessions: State<'_, SessionMap>,
) -> Result<Vec<String>, String> {
    let map = sessions.0.lock().await;
    Ok(map.keys().cloned().collect())
}

#[tauri::command]
pub async fn session_connected(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<bool, String> {
    let map = sessions.0.lock().await;
    let handle = session::get(&map, &session_id)?;
    Ok(handle.connected.load(std::sync::atomic::Ordering::SeqCst))
}

// ─── Session Directory Management ────────────────────────────────────

#[tauri::command]
pub async fn list_session_dirs() -> Result<Vec<SessionDirInfo>, String> {
    let sessions_dir = dirs::alayaface_dir().join("sessions");
    if !sessions_dir.exists() {
        return Ok(Vec::new());
    }

    let mut entries: Vec<_> = std::fs::read_dir(&sessions_dir)
        .map_err(|e| format!("Cannot read sessions dir: {e}"))?
        .filter_map(|e| e.ok())
        .collect();
    entries.sort_by_key(|e| std::cmp::Reverse(e.path().metadata().ok().and_then(|m| m.modified().ok())));

    let mut result = Vec::new();
    for entry in entries {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let id = entry.file_name().to_string_lossy().to_string();
        let session_file = path.join("session.md");
        let created_at = path.metadata().ok()
            .and_then(|m| m.created().ok())
            .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs().to_string())
            .unwrap_or_else(|| "0".to_string());

        result.push(SessionDirInfo {
            id,
            has_session_file: session_file.exists(),
            created_at,
        });
    }
    Ok(result)
}

#[tauri::command]
pub async fn delete_session_dir(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    // Close if running
    let _ = session::close(&session_id, &sessions).await;

    let session_dir = dirs::alayaface_dir().join("sessions").join(&session_id);
    if session_dir.exists() {
        std::fs::remove_dir_all(&session_dir)
            .map_err(|e| format!("Cannot delete {:?}: {}", session_dir, e))?;
    }
    Ok(())
}

#[tauri::command]
pub async fn fork_session(
    app: AppHandle,
    source_session_id: String,
    history_id: String,
    binary_path: String,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let (_template_dir, sessions_dir) = dirs::ensure()?;
    let new_id = Uuid::new_v4().to_string();
    let new_session_dir = dirs::create_session_dir(&sessions_dir, &new_id)?;
    let target_file = new_session_dir.join("session.md").to_string_lossy().to_string();
    let config_path = new_session_dir.join("config").to_string_lossy().to_string();

    eprintln!("[alayaface] Forking {} up to history {} → {}", &source_session_id, &history_id, &target_file);

    // Tell source alayacore to fork
    {
        let map = sessions.0.lock().await;
        let cmd = format!(":fork {} {}", history_id, target_file);
        send_raw(&map, &source_session_id, tlv::TAG_USER_TEXT, &cmd).await?;
        send_raw(&map, &source_session_id, tlv::TAG_USER_END, "").await?;
    }

    // Wait for session file to stabilize
    wait_for_file(&target_file).await?;

    let bin = resolve_binary(&binary_path);
    session::create(&app, &bin, &config_path, &target_file, new_session_dir, &sessions, &model_cache).await
}

async fn wait_for_file(path: &str) -> Result<(), String> {
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

// ─── Session I/O ─────────────────────────────────────────────────────

async fn send_raw(
    map: &std::collections::HashMap<String, crate::session::SessionHandle>,
    session_id: &str,
    tag: &str,
    value: &str,
) -> Result<(), String> {
    let handle = session::get(map, session_id)?;
    if !handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("Session is disconnected".to_string());
    }
    let mut stdin = handle.stdin.lock().await;
    tlv::write_frame(&mut *stdin, tag, value).map_err(|e| format!("Write error: {e}"))?;
    stdin.flush().map_err(|e| format!("Flush error: {e}"))?;
    Ok(())
}

#[tauri::command]
pub async fn alayacore_send_message(
    session_id: String,
    text: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &text).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_send_prompt(
    session_id: String,
    text: String,
    media: Vec<MediaItem>,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let handle = session::get(&map, &session_id)?;
    if !handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("Session is disconnected".to_string());
    }

    let mut stdin = handle.stdin.lock().await;
    for item in &media {
        let tag = match item.media_type.as_str() {
            "image" => tlv::TAG_USER_IMAGE,
            "audio" => tlv::TAG_USER_AUDIO,
            "video" => tlv::TAG_USER_VIDEO,
            "document" => tlv::TAG_USER_DOC,
            _ => return Err(format!("Unknown media type: {}", item.media_type)),
        };
        tlv::write_frame(&mut *stdin, tag, &item.uri).map_err(|e| format!("Write error: {e}"))?;
    }
    if !text.is_empty() {
        tlv::write_frame(&mut *stdin, tlv::TAG_USER_TEXT, &text).map_err(|e| format!("Write error: {e}"))?;
    }
    tlv::write_frame(&mut *stdin, tlv::TAG_USER_END, "").map_err(|e| format!("Write error: {e}"))?;
    stdin.flush().map_err(|e| format!("Flush error: {e}"))?;
    Ok(())
}

#[tauri::command]
pub async fn alayacore_send_raw_frame(
    session_id: String,
    tag: String,
    value: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, &tag, &value).await
}

// ─── Commands ────────────────────────────────────────────────────────

macro_rules! send_cmd {
    ($name:ident, $fmt:expr) => {
        #[tauri::command]
        pub async fn $name(
            session_id: String,
            sessions: State<'_, SessionMap>,
        ) -> Result<(), String> {
            let map = sessions.0.lock().await;
            send_raw(&map, &session_id, tlv::TAG_USER_TEXT, $fmt).await?;
            send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
        }
    };
}

send_cmd!(alayacore_cancel, ":cancel");
send_cmd!(alayacore_model_load, ":model_load");
send_cmd!(alayacore_continue, ":continue");
send_cmd!(alayacore_summarize, ":summarize");

#[tauri::command]
pub async fn alayacore_model_set(
    session_id: String,
    model_id: u32,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":model_set {}", model_id)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_save(
    session_id: String,
    filename: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let cmd = if filename.is_empty() { ":save".to_string() } else { format!(":save {}", filename) };
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &cmd).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_fork(
    session_id: String,
    history_id: String,
    filename: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let cmd = format!(":fork {} {}", history_id, filename);
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &cmd).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_reason(
    session_id: String,
    level: u32,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":reason {}", level)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_theme_set(
    session_id: String,
    name: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":theme_set {}", name)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_model_sync(
    session_id: String,
    config: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":model_sync {}", config)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_video_config(
    session_id: String,
    fps: u32,
    res: u32,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":video_config {} {}", fps, res)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_confirm(
    session_id: String,
    id: String,
    allowed: bool,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let answer = if allowed { "yes" } else { "no" };
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":confirm {} {}", id, answer)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn get_stderr_log(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<Vec<String>, String> {
    let map = sessions.0.lock().await;
    let handle = session::get(&map, &session_id)?;
    let log = handle.stderr_log.lock().await.clone();
    Ok(log)
}

#[tauri::command]
pub async fn list_models(
    binary_path: String,
    config_path: String,
    model_cache: State<'_, ModelCache>,
    sessions: State<'_, SessionMap>,
) -> Result<Vec<serde_json::Value>, String> {
    // Try cache first
    {
        let cache = model_cache.0.lock().unwrap();
        if !cache.is_empty() {
            return Ok(cache.clone());
        }
    }

    // Ask any connected session
    {
        let map = sessions.0.lock().await;
        for (_sid, handle) in map.iter() {
            if handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
                let mut stdin = handle.stdin.lock().await;
                let _ = tlv::write_frame(&mut *stdin, tlv::TAG_USER_TEXT, ":model_load");
                let _ = tlv::write_frame(&mut *stdin, tlv::TAG_USER_END, "");
                let _ = stdin.flush();
                let cache = model_cache.0.lock().unwrap();
                if !cache.is_empty() {
                    return Ok(cache.clone());
                }
                break;
            }
        }
    }

    // Fallback: spawn temp process
    let bin = resolve_binary(&binary_path);
    let mut cmd = std::process::Command::new(&bin);
    cmd.arg("--rawio");
    if !config_path.is_empty() {
        cmd.arg("--config-path").arg(&config_path);
    }
    let mut child = cmd
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to start alayacore: {e}"))?;

    drop(child.stdin.take());

    let mut stdout = child.stdout.take().ok_or_else(|| "Failed to capture stdout".to_string())?;
    let mut models = Vec::new();
    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(5);

    loop {
        if start.elapsed() > timeout {
            break;
        }
        match tlv::read_frame(&mut stdout) {
            Ok(Some(frame)) => {
                if frame.tag == "SM" {
                    if let Ok(env) = serde_json::from_str::<tlv::SystemMsgEnvelope>(&frame.value) {
                        if env.msg_type == "model_list" {
                            if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                                models = arr.clone();
                                let mut cache = model_cache.0.lock().unwrap();
                                *cache = models.clone();
                            }
                            break;
                        }
                    }
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    drop(stdout);
    let _ = child.kill();
    let _ = child.wait();
    Ok(models)
}

// ─── Helpers ──────────────────────────────────────────────────────────

fn resolve_binary(binary_path: &str) -> String {
    if binary_path.is_empty() {
        alayacore::find_binary()
    } else {
        binary_path.to_string()
    }
}
