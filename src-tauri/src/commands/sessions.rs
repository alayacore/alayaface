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
    preset: Option<String>,
    builtin_tools: Option<String>,
    system_prompt: Option<String>,
    work_dir: Option<String>,
    plan_id: Option<String>,
    node_id: Option<String>,
    origin_session_id: Option<String>,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let (_template_dir, sessions_dir) = dirs::ensure()?;

    let bin = resolve_binary(&binary_path);
    let session_id = Uuid::new_v4().to_string();
    let preset_name = preset.unwrap_or_default();
    // Plan node sessions live NESTED under
    // sessions/<originSessionId>/plans/<planId>/<nodeId>/ — every plan
    // belongs to the session that created it, and the sessions/ top
    // level only ever contains plain sessions. Plain sessions stay at
    // sessions/<uuid>/.
    let session_dir = match &plan_id {
        Some(pid) if !pid.trim().is_empty() => dirs::create_session_dir_nested(
            &sessions_dir,
            origin_session_id.as_deref().unwrap_or(""),
            pid,
            node_id.as_deref().unwrap_or(""),
            &session_id,
            &preset_name,
        )?,
        _ => dirs::create_session_dir_from(&sessions_dir, &session_id, &preset_name)?,
    };

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
    // Symmetric to tool_confirm: an EXPLICIT override wins — including an
    // explicit empty string, which means NO builtin tools (alayacore
    // treats `--builtin-tools=` as an empty list; Plan Sessions use this
    // so the planner physically cannot execute tools). Unspecified =
    // the active preset's builtin_tools; an empty effective value means
    // don't pass the flag = all tools.
    let bt: Option<String> = match builtin_tools {
        Some(v) => Some(v.to_string()),
        None => crate::commands::effective_builtin_tools().ok().filter(|s| !s.is_empty()),
    };
    // Optional extra system prompt (Plan Sessions inject the planner
    // instructions here; empty = don't pass --system).
    let sp = system_prompt.unwrap_or_default();
    log::info!("Spawning: {} --rawio --config-path {} --session {}", &bin, &effective_config, &session_file);
    if !tc.is_empty() {
        log::info!("  with --tool-confirm={}", &tc);
    }
    if let Some(btl) = &bt {
        log::info!("  with --builtin-tools={}", if btl.is_empty() { "<none>" } else { btl });
    }
    if !sp.is_empty() {
        log::info!("  with --system ({} chars)", &sp.len());
    }
    if !preset_name.is_empty() {
        log::info!("  preset={}", &preset_name);
    }
    // Optional per-plan working directory (Plan Mode node sessions):
    // created if needed, and the child is spawned with it as cwd.
    let wd = match &work_dir {
        Some(d) if !d.trim().is_empty() => {
            std::fs::create_dir_all(d)
                .map_err(|e| format!("Cannot create work dir {}: {}", d, e))?;
            Some(d.clone())
        }
        _ => None,
    };
    if wd.is_some() {
        log::info!("  work_dir={}", wd.as_deref().unwrap());
    }

    session::create(session::SessionConfig {
        id: &session_id,
        app: &app,
        binary: &bin,
        config_path: &effective_config,
        session_file: &session_file,
        session_dir,
        sessions: &sessions,
        model_cache: &model_cache,
        tool_confirm: &tc,
        builtin_tools: bt.as_deref(),
        system_prompt: &sp,
        work_dir: wd,
    }).await
}

/// Locate an on-disk session directory by trying the current and legacy
/// layouts in order (first existing path wins; "" components skipped):
///  1. sessions/<originSessionId>/plans/<planId>/<nodeId>/<sessionId>  (P28)
///  2. sessions/<planId>/<nodeId>/<sessionId>                          (P27)
///  3. sessions/<sessionId>                                            (flat)
fn resolve_session_dir(
    sessions_root: &std::path::Path,
    origin_session_id: &str,
    plan_id: &str,
    node_id: &str,
    session_id: &str,
) -> std::path::PathBuf {
    if !origin_session_id.trim().is_empty() && !plan_id.trim().is_empty() {
        let nested = sessions_root
            .join(dirs::sanitize_dir_component(origin_session_id))
            .join("plans")
            .join(dirs::sanitize_dir_component(plan_id))
            .join(dirs::sanitize_dir_component(node_id))
            .join(session_id);
        if nested.exists() {
            return nested;
        }
    }
    if !plan_id.trim().is_empty() {
        let p27 = sessions_root
            .join(dirs::sanitize_dir_component(plan_id))
            .join(dirs::sanitize_dir_component(node_id))
            .join(session_id);
        if p27.exists() {
            return p27;
        }
    }
    sessions_root.join(session_id)
}

#[tauri::command]
pub async fn resume_session(
    app: AppHandle,
    session_id: String,
    binary_path: String,
    work_dir: Option<String>,
    plan_id: Option<String>,
    node_id: Option<String>,
    origin_session_id: Option<String>,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let sessions_root = dirs::alayaface_dir().join("sessions");
    // Plan node sessions are nested under the plan's owning session; the
    // frontend passes originSessionId/planId/nodeId so resume finds the
    // on-disk dir even though the session id alone is only unique per
    // plan. resolve_session_dir falls back to older layouts for sessions
    // created before this change.
    let sessions_dir = resolve_session_dir(
        &sessions_root,
        origin_session_id.as_deref().unwrap_or(""),
        plan_id.as_deref().unwrap_or(""),
        node_id.as_deref().unwrap_or(""),
        &session_id,
    );
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

    // Check not already running. Resumed sessions are keyed by a fresh
    // UUID each time (session::create), so compare by directory rather
    // than by the on-disk id to catch double-resumes of the same dir.
    if sessions.0.lock().await.iter().any(|(_, h)| h.session_dir == sessions_dir) {
        return Err("Session is already active".to_string());
    }

    let bin = resolve_binary(&binary_path);
    let config_path = config_dir.to_string_lossy().to_string();
    let session_path = session_file.to_string_lossy().to_string();

    // Resumed plan-node sessions keep the plan's working directory.
    let wd = match &work_dir {
        Some(d) if !d.trim().is_empty() => {
            std::fs::create_dir_all(d)
                .map_err(|e| format!("Cannot create work dir {}: {}", d, e))?;
            Some(d.clone())
        }
        _ => None,
    };

    // Resumed sessions get a FRESH id (matching Go) while keeping the
    // original on-disk directory. The client must keep the node bound to
    // the ORIGINAL id (the dir name); the fresh id only identifies the
    // live process.
    let new_id = Uuid::new_v4().to_string();
    session::create(session::SessionConfig {
        id: &new_id,
        app: &app,
        binary: &bin,
        config_path: &config_path,
        session_file: &session_path,
        session_dir: sessions_dir,
        sessions: &sessions,
        model_cache: &model_cache,
        tool_confirm: "",
        builtin_tools: None,
        system_prompt: "",
        work_dir: wd,
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
        // ONLY top-level session dirs are listed. Plan Mode nests its
        // node sessions under sessions/<planId>/<nodeId>/ (which contain
        // no session.alaya at the top level), so the manager never shows
        // plan child sessions — a top-level entry is guaranteed not to be
        // a plan's child session.
        if !session_file.exists() {
            continue;
        }
        let created_at = path.metadata().ok()
            .and_then(|m| m.created().ok())
            .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs().to_string())
            .unwrap_or_else(|| "0".to_string());

        result.push(SessionDirInfo {
            id,
            has_session_file: true,
            created_at,
        });
    }
    Ok(result)
}

#[tauri::command]
pub async fn delete_session_dir(
    session_id: String,
    plan_id: Option<String>,
    node_id: Option<String>,
    origin_session_id: Option<String>,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    // Close if running
    let _ = session::close(&session_id, &sessions).await;

    let sessions_root = dirs::alayaface_dir().join("sessions");
    // Plan node sessions are nested; originSessionId/planId/nodeId locate
    // them (resolve_session_dir also tries the older layouts).
    let session_dir = resolve_session_dir(
        &sessions_root,
        origin_session_id.as_deref().unwrap_or(""),
        plan_id.as_deref().unwrap_or(""),
        node_id.as_deref().unwrap_or(""),
        &session_id,
    );
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
        id: &new_id,
        app: &app,
        binary: &bin,
        config_path: &config_path,
        session_file: &target_file,
        session_dir: new_session_dir,
        sessions: &sessions,
        model_cache: &model_cache,
        tool_confirm: "",
        builtin_tools: None,
        system_prompt: "",
        work_dir: None,
    }).await
}
