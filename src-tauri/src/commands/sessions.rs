//! Session lifecycle Tauri commands.
//!
//! Commands for creating, resuming, closing, and forking sessions,
//! plus listing/deleting session directories.

use crate::commands::{resolve_binary, wait_for_file, SessionDirInfo};
use crate::dirs;
use crate::session::{self, SessionMap};
use crate::ModelCache;

use tauri::{AppHandle, State};
use uuid::Uuid;

#[tauri::command]
pub async fn create_session(
    app: AppHandle,
    binary_path: String,
    config_path: String,
    tool_confirm: Option<String>,
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
    let session_file = session_dir.join("session.alaya").to_string_lossy().to_string();

    let tc = match tool_confirm {
        // Explicit per-session override wins; otherwise use the global setting.
        Some(v) if !v.trim().is_empty() => v,
        _ => crate::commands::effective_tool_confirm().unwrap_or_else(|e| {
            log::warn!("[settings] tool-confirm unavailable, spawning without it: {e}");
            String::new()
        }),
    };
    log::info!("Spawning: {} --rawio --config-path {} --session {}", &bin, &effective_config, &session_file);
    if !tc.is_empty() {
        log::info!("  with --tool-confirm={}", &tc);
    }

    session::create(session::SessionConfig {
        app: &app,
        binary: &bin,
        config_path: &effective_config,
        session_file: &session_file,
        session_dir,
        sessions: &sessions,
        model_cache: &model_cache,
        tool_confirm: &tc,
    }).await
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
    let session_file = sessions_dir.join("session.alaya");
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

    session::create(session::SessionConfig {
        app: &app,
        binary: &bin,
        config_path: &config_path,
        session_file: &session_path,
        session_dir: sessions_dir,
        sessions: &sessions,
        model_cache: &model_cache,
        tool_confirm: "",
    }).await
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
        let session_file = path.join("session.alaya");
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
    let target_file = new_session_dir.join("session.alaya").to_string_lossy().to_string();
    let config_path = new_session_dir.join("config").to_string_lossy().to_string();

    log::info!("Forking {} up to history {} → {}", &source_session_id, &history_id, &target_file);

    // Tell source alayacore to fork
    {
        let map = sessions.0.lock().await;
        let input = format!("{} {}", history_id, target_file);
        crate::commands::send_cmd(&map, &source_session_id, "fork", &input).await?;
    }

    // Wait for session file to stabilize
    wait_for_file(&target_file).await?;

    let bin = resolve_binary(&binary_path);
    session::create(session::SessionConfig {
        app: &app,
        binary: &bin,
        config_path: &config_path,
        session_file: &target_file,
        session_dir: new_session_dir,
        sessions: &sessions,
        model_cache: &model_cache,
        tool_confirm: "",
    }).await
}
