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
    /// Client identity that created/resumed this session (empty =
    /// legacy). close_all_sessions reclaims only the caller's own
    /// sessions, so one client's page load never kills another client's
    /// live sessions (the Go backend is reachable from several clients).
    pub owner: String,
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
    /// Session id — also names the on-disk directory
    /// (~/.alayaface/sessions/<id>/), matching the Go backend.
    pub id: &'a str,
    pub app: &'a AppHandle,
    pub binary: &'a str,
    pub config_path: &'a str,
    pub session_file: &'a str,
    pub session_dir: PathBuf,
    pub sessions: &'a SessionMap,
    pub model_cache: &'a ModelCache,
    pub tool_confirm: &'a str,
    /// Built-in tools: Some(list) → `--builtin-tools=<list>` (Some("") =
    /// NO builtin tools — used by Plan Sessions so the planner cannot
    /// execute tools); None = don't pass the flag = all tools.
    pub builtin_tools: Option<&'a str>,
    pub system_prompt: &'a str,
    /// Child process working directory (per-plan isolation; None =
    /// inherit the backend's cwd).
    pub work_dir: Option<String>,
    /// Client identity that created the session (empty = legacy). Used
    /// by close_all_sessions to reclaim only one client's orphaned
    /// sessions.
    pub owner: &'a str,
}

// ─── Factory ──────────────────────────────────────────────────────────

/// Create a new session: spawn alayacore and start background readers.
/// The session id comes from the caller (cfg.id) so the returned id
/// always equals the on-disk directory name — resume_session depends on
/// this (it looks up the dir by the id it is handed).
pub async fn create(cfg: SessionConfig<'_>) -> Result<String, String> {
    let session_id = cfg.id.to_string();

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
        owner: cfg.owner.to_string(),
    };

    cfg.sessions.0.lock().await.insert(session_id.clone(), handle);

    // Emit connected:true BEFORE spawning the stdout reader: a child
    // that dies instantly makes the reader emit connected:false right
    // away — with the old ordering (reader first) the false could land
    // before the true, leaving the client believing a dead session is
    // connected.
    let _ = cfg.app.emit("core-status", StatusEvent {
        session_id: session_id.clone(),
        connected: true,
        message: format!("Connected to alayacore ({})", cfg.binary),
    });

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

    Ok(session_id)
}

/// Close a session gracefully: ask alayacore to save, send EOF (it
/// drains the active task — auto-saving at task end — then exits), and
/// only SIGKILL after a grace period. See `alayacore::close_child_gracefully`.
pub async fn close(session_id: &str, sessions: &SessionMap) -> Result<(), String> {
    close_with_timeout(session_id, sessions, alayacore::GRACEFUL_CLOSE_TIMEOUT).await
}

/// Shared close implementation with an explicit grace timeout (tests
/// use a short one; `close` uses the real 5s constant).
///
/// The map lock is taken ONLY to remove the handle, and released before
/// the graceful close runs (the `spawn_blocking` await). Holding it
/// across the close would block every other command (send_prompt,
/// create_session, resume, ...) for up to the timeout on every session
/// close — a hung alayacore would freeze the whole backend.
pub async fn close_with_timeout(
    session_id: &str,
    sessions: &SessionMap,
    timeout: std::time::Duration,
) -> Result<(), String> {
    let handle = {
        let mut map = sessions.0.lock().await;
        map.remove(session_id)
    };
    let Some(handle) = handle else {
        return Err("Session not found".to_string());
    };
    let child_opt = handle.child.lock().unwrap().take();
    let stdin = handle.stdin.clone();
    let _ = tokio::task::spawn_blocking(move || {
        if let Some(mut child) = child_opt {
            alayacore::close_child_gracefully_with_timeout(&mut child, &stdin, timeout);
        }
    })
    .await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    use std::time::Duration;

    /// Build a SessionMap with one handle backed by a real child process.
    fn map_with_session(
        mut child: std::process::Child,
        sid: &str,
    ) -> (SessionMap, Arc<tokio::sync::Mutex<Option<std::process::ChildStdin>>>) {
        let stdin = Arc::new(tokio::sync::Mutex::new(Some(child.stdin.take().unwrap())));
        let map = SessionMap(Arc::new(tokio::sync::Mutex::new(HashMap::new())));
        {
            let mut inner = map.0.try_lock().unwrap();
            inner.insert(
                sid.to_string(),
                SessionHandle {
                    stdin: stdin.clone(),
                    connected: Arc::new(AtomicBool::new(true)),
                    pending_commands: Arc::new(tokio::sync::Mutex::new(HashMap::new())),
                    child: Arc::new(std::sync::Mutex::new(Some(child))),
                    session_dir: PathBuf::from("/tmp/alayaface-test-session"),
                    owner: String::new(),
                },
            );
        }
        (map, stdin)
    }

    #[tokio::test]
    async fn close_releases_map_lock_while_graceful_close_runs() {
        // A child that ignores EOF: the graceful close must wait out its
        // timeout, which gives the test a deterministic window to observe
        // whether the SessionMap lock is still held.
        let child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn sleep");
        let (map, _stdin) = map_with_session(child, "s1");

        let map_arc = map.0.clone();
        let closer = tokio::spawn(async move {
            close_with_timeout("s1", &SessionMap(map_arc), Duration::from_millis(600)).await
        });

        // Give the closer time to remove the handle and enter the
        // blocking graceful close.
        tokio::time::sleep(Duration::from_millis(150)).await;
        assert!(
            map.0.try_lock().is_ok(),
            "SessionMap lock must NOT be held while a session is closing \
             (graceful close can take seconds; holding it would freeze \
             every other command)"
        );

        closer.await.expect("close task panicked").expect("close should succeed");
    }

    #[tokio::test]
    async fn close_unknown_session_returns_not_found() {
        let map = SessionMap(Arc::new(tokio::sync::Mutex::new(HashMap::new())));
        let err = close("nope", &map).await.unwrap_err();
        assert_eq!(err, "Session not found");
    }
}

/// Helper: get a session handle by ID.
pub fn get<'a>(
    map: &'a HashMap<String, SessionHandle>,
    session_id: &str,
) -> Result<&'a SessionHandle, String> {
    map.get(session_id).ok_or_else(|| "Session not found".to_string())
}
