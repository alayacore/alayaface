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
    client_id: Option<String>,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let sessions_dir = dirs::ensure()?;

    let bin = resolve_binary(&binary_path);
    let session_id = Uuid::new_v4().to_string();
    let preset_name = preset.unwrap_or_default();
    // The preset is REQUIRED (there is no active preset): resolve it now
    // so a missing/unknown preset fails before any directory is created.
    dirs::resolve_config_dir(&preset_name)?;
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
        // Explicit per-session override wins; otherwise use the preset's setting.
        Some(v) if !v.trim().is_empty() => v,
        _ => crate::commands::effective_tool_confirm(&preset_name).unwrap_or_else(|e| {
            log::warn!("[settings] tool-confirm unavailable, spawning without it: {e}");
            String::new()
        }),
    };
    // Symmetric to tool_confirm: an EXPLICIT override wins — including an
    // explicit empty string, which means NO builtin tools (alayacore
    // treats `--builtin-tools=` as an empty list; Plan Sessions use this
    // so the planner physically cannot execute tools). Unspecified =
    // the session's preset's builtin_tools; an empty effective value
    // means don't pass the flag = all tools.
    let bt: Option<String> = match builtin_tools {
        Some(v) => Some(v.to_string()),
        None => crate::commands::effective_builtin_tools(&preset_name).ok().filter(|s| !s.is_empty()),
    };
    // System prompt: an explicit non-empty override wins (the frontend
    // sends only the recursion guard over the plan depth limit);
    // otherwise the session's preset's system_prompt (settings.conf) is
    // used as --system.
    let sp = match system_prompt {
        Some(v) if !v.trim().is_empty() => v,
        _ => crate::commands::effective_system_prompt(&preset_name).unwrap_or_else(|e| {
            log::warn!("[settings] system-prompt unavailable, spawning without it: {e}");
            String::new()
        }),
    };
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

    // Persist the effective spawn args so resume_session can re-apply
    // them (capability envelope: builtin-tools restriction, tool-confirm
    // policy, preset system prompt, work dir). Best-effort — a failure
    // must not prevent the session from starting. The preset name is
    // recorded too so plain forks of this session can inherit it.
    if let Err(e) = dirs::write_spawn_args(&session_dir, &dirs::SpawnArgs {
        tool_confirm: tc.clone(),
        builtin_tools: bt.clone(),
        system_prompt: sp.clone(),
        work_dir: wd.clone().unwrap_or_default(),
        preset: preset_name.clone(),
    }) {
        log::warn!("[session] cannot persist spawn args for {:?}: {e}", session_dir);
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
        owner: client_id.as_deref().unwrap_or(""),
    }).await
}

/// Build the on-disk path of a plan NODE session:
/// sessions/<originSessionId>/plans/<planId>/<nodeId>/<sessionId>.
/// Plain sessions (no planId) stay at sessions/<sessionId>. The P28
/// layout is the ONLY layout — no legacy fallbacks. originSessionDir is
/// the owning session's REAL directory (the frontend passes it — P28
/// fix: plan children never leak to the sessions/ top level).
fn plan_session_dir_for(
    sessions_root: &std::path::Path,
    origin_session_dir: &str,
    plan_id: &str,
    node_id: &str,
    session_id: &str,
) -> std::path::PathBuf {
    if !plan_id.trim().is_empty() {
        return std::path::PathBuf::from(origin_session_dir)
            .join("plans")
            .join(dirs::sanitize_dir_component(plan_id))
            .join(dirs::sanitize_dir_component(node_id))
            .join(session_id);
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
    client_id: Option<String>,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let sessions_root = dirs::alayaface_dir().join("sessions");
    // Plan node sessions are nested under the plan's owning session; the
    // frontend passes originSessionId/planId/nodeId so resume finds the
    // on-disk dir even though the session id alone is only unique per
    // plan. Plain sessions (no planId) resolve at the top level.
    let sessions_dir = plan_session_dir_for(
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

    // Re-apply the persisted spawn args so the resumed session keeps its
    // capability envelope (builtin-tools restriction, tool-confirm
    // policy, planner prompt). A missing spawn.json = legacy session →
    // old behavior (no restrictions).
    let spawn = dirs::read_spawn_args(&sessions_dir);

    // Resumed plan-node sessions keep the plan's working directory: an
    // explicit workDir from the frontend wins; otherwise the persisted one.
    let wd = match &work_dir {
        Some(d) if !d.trim().is_empty() => {
            std::fs::create_dir_all(d)
                .map_err(|e| format!("Cannot create work dir {}: {}", d, e))?;
            Some(d.clone())
        }
        _ => {
            if spawn.work_dir.is_empty() {
                None
            } else {
                std::fs::create_dir_all(&spawn.work_dir)
                    .map_err(|e| format!("Cannot create work dir {}: {}", spawn.work_dir, e))?;
                Some(spawn.work_dir.clone())
            }
        }
    };
    log::info!("Resuming {:?} with spawn args {}", sessions_dir, spawn.summary());

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
        tool_confirm: &spawn.tool_confirm,
        builtin_tools: spawn.builtin_tools.as_deref(),
        system_prompt: &spawn.system_prompt,
        work_dir: wd,
        owner: client_id.as_deref().unwrap_or(""),
    }).await
}

#[tauri::command]
pub async fn close_session(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    session::close(&session_id, &sessions).await
}

/// Gracefully close every active session owned by the calling client
/// (`client_id` None/empty = all — legacy clients). The frontend calls
/// this once on page load so sessions orphaned by a page refresh (their
/// windows are gone but the backend still holds the handles) are
/// reclaimed — otherwise resume_session keeps failing with "Session is
/// already active" until the backend is restarted. History is saved up
/// to each session's cancel point (same sequence as close_session).
///
/// Runs the per-session teardown IN PARALLEL (bounded by one grace
/// period regardless of session count — a hung alayacore would
/// otherwise cost its 5s timeout per session, serially).
#[tauri::command]
pub async fn close_all_sessions(
    client_id: Option<String>,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let owner = client_id.unwrap_or_default();
    let ids: Vec<String> = {
        let map = sessions.0.lock().await;
        map.iter()
            .filter(|(_, h)| owner.is_empty() || h.owner == owner)
            .map(|(id, _)| id.clone())
            .collect()
    };
    // Each close removes its own handle under the lock and releases it
    // before the blocking teardown, so concurrent commands stay
    // responsive while the closes drain.
    let mut handles = Vec::new();
    for id in ids {
        let map = sessions.0.clone();
        handles.push(tokio::spawn(async move {
            let _ = session::close(&id, &SessionMap(map)).await;
        }));
    }
    for h in handles {
        let _ = h.await;
    }
    Ok(())
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
            created_at,
            preset: dirs::read_spawn_args(&path).preset,
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
    // them (plain sessions resolve at the top level).
    let session_dir = plan_session_dir_for(
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
#[allow(clippy::too_many_arguments)]
pub async fn fork_session(
    app: AppHandle,
    source_session_id: String,
    history_id: String,
    binary_path: String,
    tool_confirm: Option<String>,
    preset: Option<String>,
    builtin_tools: Option<String>,
    system_prompt: Option<String>,
    work_dir: Option<String>,
    plan_id: Option<String>,
    node_id: Option<String>,
    origin_session_id: Option<String>,
    client_id: Option<String>,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let sessions_dir = dirs::ensure()?;
    let new_id = Uuid::new_v4().to_string();
    let mut preset_name = preset.unwrap_or_default();

    // A plain fork (no explicit preset) is a work copy of the source
    // session: it inherits the source's preset (recorded in its
    // session.spawn.json) and its spawn envelope. Node forks carry an
    // explicit preset from the DAG node.
    let (src_args, is_plain_fork) = {
        let map = sessions.0.lock().await;
        let handle = crate::session::get(&map, &source_session_id)?;
        (dirs::read_spawn_args(&handle.session_dir), preset_name.is_empty())
    };
    if is_plain_fork {
        preset_name = src_args.preset.clone();
        if preset_name.is_empty() {
            return Err("Preset is required: the source session has no recorded preset".to_string());
        }
    }
    // Resolve the preset now so a missing/unknown preset fails before
    // any directory is created.
    dirs::resolve_config_dir(&preset_name)?;

    // P38: a forked plan NODE session lands in the SAME nested subtree
    // as the original (sessions/<origin>/plans/<planId>/<nodeId>/<uuid>/)
    // and carries the node's config — so the fork replaces the node
    // session in place. Plain forks stay at sessions/<uuid>/.
    let new_session_dir = match &plan_id {
        Some(pid) if !pid.trim().is_empty() => dirs::create_session_dir_nested(
            &sessions_dir,
            origin_session_id.as_deref().unwrap_or(""),
            pid,
            node_id.as_deref().unwrap_or(""),
            &new_id,
            &preset_name,
        )?,
        _ => dirs::create_session_dir_from(&sessions_dir, &new_id, &preset_name)?,
    };
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
    // Mirror create_session's optional overrides so the fork keeps the
    // node session's tool/preset/system-prompt behavior. An explicit
    // override wins; plain forks inherit the source session's spawn
    // envelope (it is a work copy); node forks resolve the node's
    // preset settings like create_session.
    let tc = match tool_confirm {
        Some(v) if !v.trim().is_empty() => v,
        _ if is_plain_fork => src_args.tool_confirm.clone(),
        _ => crate::commands::effective_tool_confirm(&preset_name).unwrap_or_else(|e| {
            log::warn!("[settings] tool-confirm unavailable, spawning without it: {e}");
            String::new()
        }),
    };
    let bt: Option<String> = match builtin_tools {
        Some(v) => Some(v.to_string()),
        _ if is_plain_fork => src_args.builtin_tools.clone(),
        _ => crate::commands::effective_builtin_tools(&preset_name).ok().filter(|s| !s.is_empty()),
    };
    let sp = match system_prompt {
        Some(v) if !v.trim().is_empty() => v,
        _ if is_plain_fork => src_args.system_prompt.clone(),
        _ => crate::commands::effective_system_prompt(&preset_name).unwrap_or_else(|e| {
            log::warn!("[settings] system-prompt unavailable, spawning without it: {e}");
            String::new()
        }),
    };
    let wd = match &work_dir {
        Some(d) if !d.trim().is_empty() => {
            std::fs::create_dir_all(d)
                .map_err(|e| format!("Cannot create work dir {}: {}", d, e))?;
            Some(d.clone())
        }
        _ if is_plain_fork => Some(src_args.work_dir.clone()).filter(|s| !s.is_empty()),
        _ => None,
    };
    // Persist the effective spawn args so resume_session re-applies them
    // after a restart (capability envelope: builtin-tools restriction,
    // tool-confirm policy, preset system prompt, work dir, preset name).
    // Mirrors create_session above AND Go's fork_session — without this
    // a forked Plan node session resumed later would come back WITHOUT
    // its restrictions (e.g. a "no tools" planner regaining all tools).
    if let Err(e) = dirs::write_spawn_args(&new_session_dir, &dirs::SpawnArgs {
        tool_confirm: tc.clone(),
        builtin_tools: bt.clone(),
        system_prompt: sp.clone(),
        work_dir: wd.clone().unwrap_or_default(),
        preset: preset_name.clone(),
    }) {
        log::warn!("[session] cannot persist spawn args for {:?}: {e}", new_session_dir);
    }
    session::create(session::SessionConfig {
        id: &new_id,
        app: &app,
        binary: &bin,
        config_path: &config_path,
        session_file: &target_file,
        session_dir: new_session_dir,
        sessions: &sessions,
        model_cache: &model_cache,
        tool_confirm: &tc,
        builtin_tools: bt.as_deref(),
        system_prompt: &sp,
        work_dir: wd,
        owner: &client_id.unwrap_or_default(),
    }).await
}

#[cfg(test)]
mod tests {
    use super::*;

    // Parity guard: create_session AND fork_session must both persist the
    // effective spawn args (session.spawn.json) so resume_session can
    // re-apply the capability envelope after a restart. Go's fork_session
    // does this; a drift here would let a forked Plan node session resume
    // WITHOUT its builtin-tools / tool-confirm / system-prompt / work-dir
    // restrictions (e.g. a "no tools" planner coming back with all tools).
    // We can't run a real fork in unit tests (needs alayacore), so this
    // test pins the persistence helper the command uses and asserts the
    // round-trip that resume_session relies on.
    #[test]
    fn spawn_args_persist_roundtrip_for_forked_session() {
        let dir = std::env::temp_dir().join(format!("alayaface-fork-spawn-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let args = dirs::SpawnArgs {
            tool_confirm: "allow".into(),
            builtin_tools: Some("read_file,write_file".into()),
            system_prompt: "planner".into(),
            work_dir: "/tmp/wd".into(),
            preset: "Complex".into(),
        };
        dirs::write_spawn_args(&dir, &args).unwrap();
        let got = dirs::read_spawn_args(&dir);
        assert_eq!(got.tool_confirm, "allow");
        assert_eq!(got.builtin_tools.as_deref(), Some("read_file,write_file"));
        assert_eq!(got.system_prompt, "planner");
        assert_eq!(got.work_dir, "/tmp/wd");
        assert_eq!(got.preset, "Complex");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
