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
    /// Bounded — see PendingCommands (M5/D6).
    pub pending_commands: Arc<PendingCommands>,
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

/// Bounded pending-command registry: call ID → command name (CI sent,
/// CO not yet received). If a CO reply never arrives (protocol anomaly
/// / killed core), an entry must not grow the map forever — insert
/// evicts the OLDEST entries beyond the cap (FIFO), so the newest
/// calls — the ones most likely to still get a reply — survive.
/// Mirrors the Go internal/session/pendingCmds guard (M5/D6).
/// `pub` because it appears in the signature of the public
/// `spawn_stdout_reader` and the public `SessionHandle::pending_commands`
/// field; its internals stay private.
pub struct PendingCommands {
    inner: tokio::sync::Mutex<PendingCommandsInner>,
}

struct PendingCommandsInner {
    map: std::collections::HashMap<String, String>,
    order: std::collections::VecDeque<String>,
}

/// Maximum pending CI→CO entries per session.
pub(crate) const MAX_PENDING_COMMANDS: usize = 512;

impl PendingCommands {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: tokio::sync::Mutex::new(PendingCommandsInner {
                map: std::collections::HashMap::new(),
                order: std::collections::VecDeque::new(),
            }),
        })
    }

    /// Record id → name, evicting the oldest entries beyond the cap.
    pub(crate) async fn insert(&self, id: String, name: String) {
        let mut g = self.inner.lock().await;
        let is_new = g.map.insert(id.clone(), name).is_none();
        if is_new {
            g.order.push_back(id);
        }
        while g.order.len() > MAX_PENDING_COMMANDS {
            if let Some(old) = g.order.pop_front() {
                g.map.remove(&old);
            }
        }
    }

    /// Remove and return the name for id.
    pub(crate) async fn remove(&self, id: &str) -> Option<String> {
        let mut g = self.inner.lock().await;
        let v = g.map.remove(id);
        if v.is_some() {
            g.order.retain(|x| x != id);
        }
        v
    }

    /// Remove and return the name for id, from a non-async context
    /// (the stdout reader thread).
    pub(crate) fn blocking_remove(&self, id: &str) -> Option<String> {
        let mut g = self.inner.blocking_lock();
        let v = g.map.remove(id);
        if v.is_some() {
            g.order.retain(|x| x != id);
        }
        v
    }

    #[cfg(test)]
    async fn len(&self) -> usize {
        self.inner.lock().await.map.len()
    }

    #[cfg(test)]
    async fn contains(&self, id: &str) -> bool {
        self.inner.lock().await.map.contains_key(id)
    }
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
    /// Initial reasoning level (0|1|2), passed to alayacore as
    /// `--reasoning-level=<n>`.
    pub reasoning_level: i64,
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
        cfg.reasoning_level,
        cfg.work_dir.as_deref(),
    )
    .map_err(|e| format!("Failed to start alayacore: {e}"))?;

    let connected = Arc::new(AtomicBool::new(true));
    let stdin = Arc::new(Mutex::new(Some(proc.stdin)));
    let child = Arc::new(std::sync::Mutex::new(Some(proc.child)));
    let pending_commands = PendingCommands::new();

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

    // M5 (D6): the pending-commands registry must stay BOUNDED — a CO
    // reply that never arrives (protocol anomaly / killed core) must
    // not grow the map forever. Insert evicts the OLDEST entries beyond
    // the cap (FIFO), so the newest calls — the ones most likely to
    // still get a reply — always survive. Mirrors the Go
    // pending_cmds_test.go cases.

    #[tokio::test]
    async fn pending_commands_bounded_by_cap() {
        let pc = PendingCommands::new();
        for i in 1..=(MAX_PENDING_COMMANDS + 100) {
            pc.insert(format!("call-{i}"), "cmd".to_string()).await;
        }
        assert_eq!(pc.len().await, MAX_PENDING_COMMANDS);
        // The 100 OLDEST entries were evicted; the newest survive.
        assert!(!pc.contains("call-1").await, "oldest entry survived the cap eviction");
        assert!(!pc.contains("call-100").await, "entry at the eviction boundary survived");
        assert!(pc.contains("call-101").await, "first surviving entry was evicted");
        assert!(pc.contains(&format!("call-{}", MAX_PENDING_COMMANDS + 100)).await, "newest entry was evicted");
    }

    #[tokio::test]
    async fn pending_commands_async_remove() {
        let pc = PendingCommands::new();
        pc.insert("call-1".to_string(), "model_set".to_string()).await;
        assert_eq!(pc.remove("call-1").await.as_deref(), Some("model_set"));
        assert!(pc.remove("call-1").await.is_none());
        assert_eq!(pc.len().await, 0);
    }

    #[test]
    fn pending_commands_blocking_remove_works_off_runtime() {
        // blocking_remove is the stdout-reader path: the reader runs on
        // a plain std thread with NO tokio runtime — blocking_lock must
        // work there (it panics when called inside a runtime).
        let pc = PendingCommands::new();
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            pc.insert("call-2".to_string(), "read_file".to_string()).await;
        });
        drop(rt);
        assert_eq!(pc.blocking_remove("call-2"), Some("read_file".to_string()));
        assert!(pc.blocking_remove("call-2").is_none());
    }

    #[tokio::test]
    async fn pending_commands_reinsert_does_not_duplicate_order() {
        let pc = PendingCommands::new();
        pc.insert("call-1".to_string(), "a".to_string()).await;
        pc.insert("call-1".to_string(), "a2".to_string()).await; // same id, new name
        for i in 1..=MAX_PENDING_COMMANDS {
            pc.insert(format!("call-{i}"), "cmd".to_string()).await;
        }
        // A duplicated order queue would evict two entries instead of one.
        assert_eq!(pc.len().await, MAX_PENDING_COMMANDS);
    }
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
                    pending_commands: PendingCommands::new(),
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
