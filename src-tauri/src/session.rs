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
    pub stdin: Arc<Mutex<std::process::ChildStdin>>,
    pub connected: Arc<AtomicBool>,
    pub stderr_log: Arc<Mutex<Vec<String>>>,
    /// The child process — kept for explicit cleanup on close.
    /// Uses std::sync::Mutex so Drop can access it (sync context).
    pub child: Arc<std::sync::Mutex<Option<std::process::Child>>>,
    /// Path to the session's directory (~/.alayaface/sessions/<uuid>/).
    pub session_dir: PathBuf,
}

impl Drop for SessionHandle {
    fn drop(&mut self) {
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
}

// ─── Factory ──────────────────────────────────────────────────────────

/// Create a new session: spawn alayacore and start background readers.
pub async fn create(cfg: SessionConfig<'_>) -> Result<String, String> {
    let session_id = Uuid::new_v4().to_string();

    let proc = alayacore::spawn(cfg.binary, cfg.config_path, cfg.session_file, cfg.tool_confirm)
        .map_err(|e| format!("Failed to start alayacore: {e}"))?;

    let connected = Arc::new(AtomicBool::new(true));
    let stderr_log = Arc::new(Mutex::new(Vec::new()));
    let stdin = Arc::new(Mutex::new(proc.stdin));
    let child = Arc::new(std::sync::Mutex::new(Some(proc.child)));

    let handle = SessionHandle {
        stdin: stdin.clone(),
        connected: connected.clone(),
        stderr_log: stderr_log.clone(),
        child: child.clone(),
        session_dir: cfg.session_dir,
    };

    cfg.sessions.0.lock().await.insert(session_id.clone(), handle);

    // Background readers
    crate::reader::spawn_stderr_collector(proc.stderr, stderr_log);
    crate::reader::spawn_stdout_reader(
        cfg.app.clone(),
        session_id.clone(),
        proc.stdout,
        connected,
        cfg.model_cache.0.clone(),
        child.clone(),
    );

    let _ = cfg.app.emit("core-status", StatusEvent {
        session_id: session_id.clone(),
        connected: true,
        message: format!("Connected to alayacore ({})", cfg.binary),
    });

    Ok(session_id)
}

/// Close a session: kill the subprocess and remove from map.
pub async fn close(session_id: &str, sessions: &SessionMap) -> Result<(), String> {
    let mut map = sessions.0.lock().await;
    if let Some(handle) = map.remove(session_id) {
        let child_opt = handle.child.lock().unwrap().take();
        if let Some(mut child) = child_opt {
            let _ = tokio::task::spawn_blocking(move || {
                alayacore::kill_child(&mut child);
            })
            .await;
        }
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
