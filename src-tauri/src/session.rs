//! Session lifecycle management.
//!
//! Each session corresponds to one `alayacore --rawio` subprocess.
//! This module manages creating, resuming, closing, and forking sessions.

use crate::alayacore;
use crate::event::StatusEvent;
use crate::ModelCache;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex;
use uuid::Uuid;

/// Internal handle to a running alayacore session.
pub struct SessionHandle {
    /// stdin pipe; `None` once closed (graceful close / EOF sent).
    /// The Option lets close_session drop the pipe even while other
    /// Arcs exist (in-flight prompt sends lock the same mutex).
    pub stdin: Arc<Mutex<Option<std::process::ChildStdin>>>,
    pub connected: Arc<AtomicBool>,
    /// Pending command call IDs → command names (CI sent, CO not yet received).
    /// Used by the stdout reader to attach the command name to CO frames
    /// (CO carries only the call ID; the name comes from the CI we sent).
    pub pending_commands: Arc<Mutex<std::collections::HashMap<String, String>>>,
    /// The child process — kept for explicit cleanup on close.
    /// Uses std::sync::Mutex so Drop can access it (sync context).
    pub child: Arc<std::sync::Mutex<Option<std::process::Child>>>,
    /// Path to the session's directory (~/.alayaface/sessions/<uuid>/).
    pub session_dir: PathBuf,
}

impl Drop for SessionHandle {
    fn drop(&mut self) {
        // Best-effort EOF so alayacore can drain + auto-save before the
        // kill below gives it a short grace period (kill_child now waits
        // for a natural exit before SIGKILL).
        if let Ok(mut guard) = self.stdin.try_lock() {
            *guard = None;
        }
        if let Ok(mut guard) = self.child.lock() {
            if let Some(mut child) = guard.take() {
                alayacore::kill_child(&mut child);
            }
        }
    }
}

/// Shared map of session_id → SessionHandle.
pub struct SessionMap(pub Arc<Mutex<HashMap<String, SessionHandle>>>);

/// Configuration for creating a new session.
pub struct SessionConfig<'a> {
    pub app: &'a AppHandle,
    pub binary: &'a str,
    pub config_path: &'a str,
    pub session_file: &'a str,
    pub session_dir: PathBuf,
    pub sessions: &'a SessionMap,
    pub model_cache: &'a ModelCache,
    pub tool_confirm: &'a str,
    pub builtin_tools: &'a str,
    pub system_prompt: &'a str,
    /// Child process working directory (per-plan isolation; None =
    /// inherit the backend's cwd).
    pub work_dir: Option<String>,
}

// ─── Factory ──────────────────────────────────────────────────────────

/// Create a new session: spawn alayacore and start background readers.
pub async fn create(cfg: SessionConfig<'_>) -> Result<String, String> {
    let session_id = Uuid::new_v4().to_string();

    let proc = alayacore::spawn(
        cfg.binary,
        cfg.config_path,
        cfg.session_file,
        cfg.tool_confirm,
        cfg.builtin_tools,
        cfg.system_prompt,
        cfg.work_dir.as_deref(),
    )
    .map_err(|e| format!("Failed to start alayacore: {e}"))?;

    let connected = Arc::new(AtomicBool::new(true));
    let stdin = Arc::new(Mutex::new(Some(proc.stdin)));
    let child = Arc::new(std::sync::Mutex::new(Some(proc.child)));
    let pending_commands = Arc::new(Mutex::new(std::collections::HashMap::new()));

    let handle = SessionHandle {
        stdin: stdin.clone(),
        connected: connected.clone(),
        pending_commands: pending_commands.clone(),
        child: child.clone(),
        session_dir: cfg.session_dir,
    };

    cfg.sessions.0.lock().await.insert(session_id.clone(), handle);

    // Background reader for stdout
    crate::reader::spawn_stdout_reader(
        cfg.app.clone(),
        session_id.clone(),
        proc.stdout,
        connected,
        cfg.model_cache.0.clone(),
        child.clone(),
        pending_commands,
    );

    let _ = cfg.app.emit("core-status", StatusEvent {
        session_id: session_id.clone(),
        connected: true,
        message: format!("Connected to alayacore ({})", cfg.binary),
    });

    Ok(session_id)
}

/// Close a session gracefully: ask alayacore to save, send EOF (it
/// drains the active task — auto-saving at task end — then exits), and
/// only SIGKILL after a grace period. See `alayacore::close_child_gracefully`.
pub async fn close(session_id: &str, sessions: &SessionMap) -> Result<(), String> {
    let mut map = sessions.0.lock().await;
    if let Some(handle) = map.remove(session_id) {
        let child_opt = handle.child.lock().unwrap().take();
        let stdin = handle.stdin.clone();
        let _ = tokio::task::spawn_blocking(move || {
            if let Some(mut child) = child_opt {
                alayacore::close_child_gracefully(&mut child, &stdin);
            }
        })
        .await;
        Ok(())
    } else {
        Err("Session not found".to_string())
    }
}

/// Helper: get a session handle by ID.
pub fn get<'a>(
    map: &'a HashMap<String, SessionHandle>,
    session_id: &str,
) -> Result<&'a SessionHandle, String> {
    map.get(session_id).ok_or_else(|| "Session not found".to_string())
}
