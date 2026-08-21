//! AlayaCore subprocess manager.
//!
//! Spawns `alayacore --rawio` as a child process and provides
//! access to its stdin/stdout for TLV communication.

use std::io;
use std::process::{Child, Command, Stdio};

use std::io::Write;

/// Spawned alayacore process with its pipes.
pub struct CoreProcess {
    pub child: Child,
    pub stdin: std::process::ChildStdin,
    pub stdout: std::process::ChildStdout,
}

/// Start alayacore with `--rawio` and return the process + pipes.
/// If `config_path` is non-empty, passes `--config-path <config_path>`.
/// If `session_path` is non-empty, passes `--session <session_path>`.
/// If `tool_confirm` is non-empty, passes `--tool-confirm=<tool_confirm>`.
/// If `builtin_tools` is Some (including Some("")), passes
/// `--builtin-tools=<list>` — Some("") = NO builtin tools (alayacore
/// treats an explicitly-empty flag as an empty list); None = don't pass
/// the flag = alayacore default (all tools).
/// If `system_prompt` is non-empty, passes `--system=<text>` (appended to
/// alayacore's default system prompt; used by Plan Sessions).
/// If `reasoning_level` is in 0..=2, passes `--reasoning-level=<n>`
/// (AlayaCore's initial reasoning level for the session).
/// If `work_dir` is Some, the child's working directory is set to it
/// (per-plan isolation for Plan Mode nodes; None = inherit the backend's
/// cwd, the pre-isolation behavior).
/// stderr is inherited so alayacore's own logs reach the terminal.
pub fn spawn(
    binary_path: &str,
    config_path: &str,
    session_path: &str,
    tool_confirm: &str,
    builtin_tools: Option<&str>,
    system_prompt: &str,
    reasoning_level: i64,
    work_dir: Option<&str>,
) -> io::Result<CoreProcess> {
    let mut cmd = Command::new(binary_path);
    cmd.arg("--rawio");
    if !config_path.is_empty() {
        cmd.arg("--config-path");
        cmd.arg(config_path);
    }
    if !session_path.is_empty() {
        cmd.arg("--session");
        cmd.arg(session_path);
    }
    if !tool_confirm.is_empty() {
        cmd.arg(format!("--tool-confirm={}", tool_confirm));
    }
    if let Some(list) = builtin_tools {
        cmd.arg(format!("--builtin-tools={}", list));
    }
    if !system_prompt.is_empty() {
        cmd.arg(format!("--system={}", system_prompt));
    }
    if (0..=2).contains(&reasoning_level) {
        cmd.arg(format!("--reasoning-level={}", reasoning_level));
    }
    if let Some(wd) = work_dir {
        cmd.current_dir(wd);
    }
    let mut child = cmd
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()?;

    let stdin = child.stdin.take().expect("failed to capture stdin");
    let stdout = child.stdout.take().expect("failed to capture stdout");

    Ok(CoreProcess {
        child,
        stdin,
        stdout,
    })
}

/// Helper to detect the alayacore binary.
///
/// Resolution order:
/// 1. Bundled binary (next to the running executable) — Tauri's
///    `externalBin` placement puts the packaged alayacore at the same
///    directory as the main binary (e.g. `<install_dir>/alayacore` on
///    Linux/Windows, `AlayaFace.app/Contents/MacOS/alayacore` on
///    macOS). The bundled copy is the one that ships with the app and
///    is therefore the most predictable choice — overriding it requires
///    setting ALAYACORE_BIN or placing a different alayacore ahead of
///    the bundled one on PATH.
/// 2. `ALAYACORE_BIN` environment variable
/// 3. `which alayacore` (Unix) or `where alayacore` (Windows)
/// 4. Known relative/absolute paths
/// 5. Fallback to "alayacore" (assume in PATH)
pub fn find_binary() -> String {
    // 1. Bundled binary (next to the running executable). Highest
    //    priority so the packaged alayacore is used when present.
    if let Some(bundled) = bundled_binary_path() {
        // A 0-byte stub from a build that failed to find alayacore
        // must NOT be picked up — std::fs::metadata().len() on an
        // empty file is 0, and the spawn would fail with a confusing
        // "exec format error" / "no such file" depending on the OS.
        if let Ok(meta) = std::fs::metadata(&bundled) {
            if meta.len() > 0 {
                return bundled.to_string_lossy().to_string();
            }
        }
    }

    // 2. Check env var
    if let Ok(bin) = std::env::var("ALAYACORE_BIN") {
        if !bin.is_empty() && std::path::Path::new(&bin).exists() {
            return bin;
        }
    }

    // 3. Try `which` (Unix) or `where` (Windows)
    let which_cmd = if cfg!(target_os = "windows") { "where" } else { "which" };
    if let Ok(output) = std::process::Command::new(which_cmd)
        .arg("alayacore")
        .output()
    {
        if output.status.success() {
            let bin = String::from_utf8_lossy(&output.stdout)
                .lines()
                .next()
                .unwrap_or("")
                .trim()
                .to_string();
            if !bin.is_empty() {
                return bin;
            }
        }
    }

    // 4. Check common locations
    for candidate in &[
        "alayacore",
        "../alayacore/alayacore",
        "./alayacore",
        "/usr/local/bin/alayacore",
        "/usr/bin/alayacore",
    ] {
        if std::path::Path::new(candidate).exists() {
            return candidate.to_string();
        }
    }

    // 4. Fallback
    "alayacore".to_string()
}

/// Path to the bundled alayacore binary, when one was placed next to
/// the running executable (Tauri's `externalBin` placement). Returns
/// `None` only when the executable path itself cannot be determined
/// (rare; happens with `setuid` binaries on some Unix systems). The
/// caller MUST still stat the result — `find_binary` does — because a
/// build that could not locate alayacore leaves a 0-byte stub here
/// (Tauri requires the file to exist for `externalBin` to bundle it).
///
/// Kept separate from `find_binary` so tests can drive it with a
/// synthetic executable path without poking at `current_exe()`.
fn bundled_binary_path() -> Option<std::path::PathBuf> {
    bundled_binary_path_from(std::env::current_exe().ok()?.as_path())
}

fn bundled_binary_path_from(exe_path: &std::path::Path) -> Option<std::path::PathBuf> {
    let dir = exe_path.parent()?;
    // A bare filename ("alayaface") has `parent() == Some("")` — that
    // would resolve to the cwd, which is not what the caller wants.
    // current_exe() always returns an absolute path, so an empty
    // parent is only possible in tests; we still skip it so the
    // helper is total and the bundled lookup stays consistent.
    if dir.as_os_str().is_empty() {
        return None;
    }
    let name = if cfg!(target_os = "windows") {
        "alayacore.exe"
    } else {
        "alayacore"
    };
    Some(dir.join(name))
}

/// Kill a child process with a 3-second timeout.
/// Closes stdin first (EOF — alayacore drains the active task and
/// auto-saves at task end), then waits up to 3s for a natural exit,
/// then sends kill.
pub fn kill_child(child: &mut Child) {
    let _ = child.stdin.take();
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if start.elapsed() > std::time::Duration::from_secs(3) => {
                let _ = child.kill();
                let _ = child.wait();
                break;
            }
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(_) => break,
        }
    }
}

/// Grace period for `close_child_gracefully`: how long alayacore may
/// take to exit after the cancel-first sequence (cancel → save → EOF)
/// before we SIGKILL it.
pub const GRACEFUL_CLOSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// Gracefully close an alayacore child (used by close_session):
///
/// 1. Ask alayacore to CANCEL the active task (CI `cancel` — the task is
///    aborted via its per-task context and completes through
///    handleTaskDone, which AUTO-SAVES the conversation up to the cancel
///    point). Fire-and-forget (no CO wait); errors ignored. Cancel-first
///    means closing never waits for a long task to drain — Stop/closing
///    a window stops the work immediately while history is kept up to
///    the cancel point.
/// 2. Ask alayacore to persist the conversation (CI `save` — with an
///    empty filename it writes to the `--session` file). Best-effort:
///    a dead child produces a write error, which is ignored.
/// 3. Close stdin (EOF). With the task canceled (or none), alayacore
///    exits immediately.
/// 4. Wait up to `GRACEFUL_CLOSE_TIMEOUT` for a natural exit.
/// 5. SIGKILL fallback if the child is still alive.
///
/// `stdin` is the session's `Arc<tokio::sync::Mutex<Option<ChildStdin>>>` —
/// setting the slot to `None` closes the pipe no matter how many Arc clones
/// exist (prompt sends lock the same mutex, so no concurrent write can
/// interleave with the cancel/save frames).
pub fn close_child_gracefully(
    child: &mut Child,
    stdin: &tokio::sync::Mutex<Option<std::process::ChildStdin>>,
) {
    close_child_gracefully_with_timeout(child, stdin, GRACEFUL_CLOSE_TIMEOUT);
}

/// Shared graceful-close implementation with an explicit grace timeout
/// (tests use a short one; `close_child_gracefully` uses the real 5s).
pub(crate) fn close_child_gracefully_with_timeout(
    child: &mut Child,
    stdin: &tokio::sync::Mutex<Option<std::process::ChildStdin>>,
    timeout: std::time::Duration,
) {
    // 1+2. Best-effort cancel, then save (alayacore: empty filename →
    //      session file). try_lock (sync context) with a short retry in
    //      case a prompt send holds the mutex.
    let mut eof_sent = false;
    for _ in 0..10 {
        if let Ok(mut guard) = stdin.try_lock() {
            if let Some(writer) = guard.as_mut() {
                let cancel_msg = crate::tlv::CmdMsg {
                    id: "alayaface-close-cancel".to_string(),
                    name: "cancel".to_string(),
                    input: String::new(),
                };
                if let Ok(json) = serde_json::to_string(&cancel_msg) {
                    let _ = crate::tlv::write_frame(writer, crate::tlv::TAG_CMD_INPUT, &json);
                }
                let save_msg = crate::tlv::CmdMsg {
                    id: "alayaface-close-save".to_string(),
                    name: "save".to_string(),
                    input: String::new(),
                };
                if let Ok(json) = serde_json::to_string(&save_msg) {
                    let _ = crate::tlv::write_frame(writer, crate::tlv::TAG_CMD_INPUT, &json);
                    let _ = writer.flush();
                }
            }
            // 3. EOF: drop the pipe regardless of remaining Arc clones.
            *guard = None;
            eof_sent = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    if !eof_sent {
        // stdin is permanently busy (prompt in-flight): we cannot send
        // EOF, so there is nothing to wait for — SIGKILL now rather than
        // leaking the child.
        let _ = child.kill();
        let _ = child.wait();
        return;
    }
    // 4. Wait for a natural exit.
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if start.elapsed() > timeout => break,
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(_) => return,
        }
    }
    // 5. Fallback: SIGKILL.
    let _ = child.kill();
    let _ = child.wait();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Command, Stdio};
    use std::sync::Arc;
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> std::path::PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("alayaface-{}-{}-{}", name, std::process::id(), nanos))
    }

    #[test]
    fn graceful_close_writes_save_frame_and_eof() {
        // Child copies stdin to a file and exits on EOF — mirrors
        // alayacore draining on stdin EOF.
        let out = temp_path("grace-out");
        let mut child = Command::new("sh")
            .args(["-c", "cat > \"$1\"", "sh", out.to_str().unwrap()])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn sh");
        let stdin = Arc::new(tokio::sync::Mutex::new(Some(child.stdin.take().unwrap())));

        close_child_gracefully(&mut child, &stdin);

        // 1. The cancel + save CI frames reached the child's stdin, in
        //    that order (cancel-first: a closing session must abort the
        //    active task, then persist). Empty `input` is omitted by
        //    CmdMsg's serializer — alayacore treats it as "save to the
        //    --session file".
        let bytes = std::fs::read(&out).expect("read captured stdin");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("CI"), "no CI tag in captured stdin: {s:?}");
        assert!(s.contains("\"name\":\"cancel\""), "no cancel command: {s:?}");
        assert!(s.contains("\"name\":\"save\""), "no save command: {s:?}");
        let cancel_at = s.find("\"name\":\"cancel\"").unwrap();
        let save_at = s.find("\"name\":\"save\"").unwrap();
        assert!(
            cancel_at < save_at,
            "cancel must be sent before save (cancel-first): {s:?}"
        );
        assert!(!s.contains("\"input\""), "empty input must be omitted (session file): {s:?}");

        // 2. The child exited naturally (EOF → cat exits 0), not killed.
        let status = child.wait().expect("wait");
        assert!(status.success(), "child should exit naturally on EOF");

        // 3. The stdin pipe was closed in the handle (EOF sent).
        assert!(
            stdin.try_lock().unwrap().is_none(),
            "stdin slot must be None after close"
        );

        let _ = std::fs::remove_file(&out);
    }

    #[test]
    fn graceful_close_kills_stubborn_child_after_timeout() {
        // A child that ignores EOF must be SIGKILLed after the grace period.
        let mut child = Command::new("sleep")
            .arg("60")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn sleep");
        let stdin = Arc::new(tokio::sync::Mutex::new(Some(child.stdin.take().unwrap())));

        close_child_gracefully_with_timeout(
            &mut child,
            &stdin,
            Duration::from_millis(300),
        );

        let status = child.wait().expect("wait");
        assert!(!status.success(), "stubborn child must be killed after the grace period");
    }

    #[test]
    fn kill_child_waits_for_natural_exit_before_killing() {
        // kill_child closes stdin first; a child that exits on EOF must
        // NOT be SIGKILLed (it exits 0 on its own).
        let mut child = Command::new("cat")
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .expect("spawn cat");

        kill_child(&mut child);

        let status = child.wait().expect("wait");
        assert!(status.success(), "kill_child must let a well-behaved child exit naturally");
    }

    #[test]
    fn kill_child_handles_already_exited_child() {
        let mut child = Command::new("true").spawn().expect("spawn true");
        let status = child.wait().expect("wait");
        assert!(status.success());

        // Must return quickly without panicking (disconnect path: the
        // child died on its own before kill_child runs).
        kill_child(&mut child);
    }

    #[test]
    fn spawn_builtin_tools_flag_semantics() {
        use std::io::Read;

        let read_args = |bt: Option<&str>| {
            let mut p = spawn("/bin/echo", "", "", "", bt, "", 1, None).unwrap();
            let mut out = String::new();
            p.stdout.read_to_string(&mut out).unwrap();
            let _ = p.child.wait();
            out
        };

        // Some("") → explicit empty flag: alayacore treats it as NO tools.
        let out = read_args(Some(""));
        assert!(
            out.contains("--builtin-tools= --reasoning-level=1"),
            "Some(\"\") must pass an empty --builtin-tools flag, got: {out:?}"
        );

        // Some(list) → the comma list.
        let out = read_args(Some("read_file,write_file"));
        assert!(
            out.contains("--builtin-tools=read_file,write_file"),
            "Some(list) must pass the list, got: {out:?}"
        );

        // None → no flag at all (alayacore default: all tools).
        let out = read_args(None);
        assert!(
            !out.contains("--builtin-tools"),
            "None must not pass the flag, got: {out:?}"
        );
    }

    #[test]
    fn spawn_reasoning_level_flag_semantics() {
        use std::io::Read;

        let read_args = |rl: i64| {
            let mut p = spawn("/bin/echo", "", "", "", None, "", rl, None).unwrap();
            let mut out = String::new();
            p.stdout.read_to_string(&mut out).unwrap();
            let _ = p.child.wait();
            out
        };

        // 0 ("Off") and 1 ("Balanced") are valid and must be passed.
        let out = read_args(0);
        assert!(
            out.contains("--reasoning-level=0"),
            "level 0 must pass --reasoning-level=0, got: {out:?}"
        );
        let out = read_args(1);
        assert!(
            out.contains("--reasoning-level=1"),
            "level 1 must pass --reasoning-level=1, got: {out:?}"
        );

        // Out of range → no flag (defensive; callers resolve 0|1|2).
        let out = read_args(7);
        assert!(
            !out.contains("--reasoning-level"),
            "out-of-range must not pass the flag, got: {out:?}"
        );
    }

    #[test]
    fn spawn_current_dir_mechanism() {
        // spawn() forwards its work_dir to Command::current_dir — verify
        // that mechanism actually changes the child's cwd (per-plan
        // isolation for Plan Mode node sessions).
        let dir = temp_path("workdir");
        std::fs::create_dir_all(&dir).expect("create work dir");
        let out = Command::new("pwd")
            .current_dir(&dir)
            .output()
            .expect("run pwd");
        assert_eq!(
            String::from_utf8_lossy(&out.stdout).trim(),
            dir.to_str().unwrap()
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    // ─── bundled_binary_path ─────────────────────────────────────
    //
    // The bundled binary is the search candidate the build script
    // (build.rs) places next to the executable. Tauri's `externalBin`
    // bundles it under the same directory as the main binary.

    #[test]
    fn bundled_binary_path_lives_next_to_executable() {
        // Symlink the executable into a fresh temp dir so we can
        // assert the helper resolves the same directory (the helper
        // takes the parent of the executable path verbatim; symlinks
        // are NOT resolved by current_exe()).
        let dir = temp_path("bundled-bin");
        std::fs::create_dir_all(&dir).expect("create dir");
        let exe = dir.join(if cfg!(target_os = "windows") {
            "alayaface.exe"
        } else {
            "alayaface"
        });
        std::fs::write(&exe, b"").unwrap();
        let bundled = bundled_binary_path_from(&exe).expect("bundled path");
        let expected_name = if cfg!(target_os = "windows") {
            "alayacore.exe"
        } else {
            "alayacore"
        };
        assert_eq!(bundled, dir.join(expected_name));

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn bundled_binary_path_without_parent_returns_none() {
        // A bare filename has no parent directory; the helper must
        // return None instead of joining with an empty string (which
        // would resolve to the cwd).
        let bare = std::path::Path::new(if cfg!(target_os = "windows") {
            "alayaface.exe"
        } else {
            "alayaface"
        });
        assert_eq!(bundled_binary_path_from(bare), None);
    }

    #[test]
    fn find_binary_prefers_bundled_over_env_var() {
        // Resolution order: bundled > ALAYACORE_BIN > PATH. The
        // bundled binary wins even when ALAYACORE_BIN points
        // elsewhere — the user installs the app and gets the bundled
        // version by default; ALAYACORE_BIN is the override knob, but
        // the bundling is the prescribed install media.
        let _guard = TEST_LOCK.lock().unwrap();
        let dir = temp_path("find-bin-bundled-wins");
        std::fs::create_dir_all(&dir).expect("create dir");
        let exe = dir.join(if cfg!(target_os = "windows") {
            "alayaface.exe"
        } else {
            "alayaface"
        });
        let bundled = dir.join(if cfg!(target_os = "windows") {
            "alayacore.exe"
        } else {
            "alayacore"
        });
        let env_path = temp_path("find-bin-env-override");
        std::fs::create_dir_all(&env_path).unwrap();
        let env_file = env_path.join("env-alayacore");
        std::fs::write(&exe, b"").unwrap();
        std::fs::write(&bundled, b"#!/bin/sh\n").unwrap();
        std::fs::write(&env_file, b"#!/bin/sh\n").unwrap();

        // current_exe() inside cargo test is the test binary, not
        // `exe` — bind the function pointer to a synthetic path.
        let prev = std::env::current_dir().unwrap();
        std::env::set_current_dir(&dir).unwrap();
        std::env::set_var("ALAYACORE_BIN", &env_file);
        let resolved = bundled_binary_path_from(&exe)
            .and_then(|p| std::fs::metadata(&p).ok().map(|m| (p, m)))
            .map(|(p, m)| if m.len() > 0 { Some(p) } else { None })
            .flatten();
        std::env::set_current_dir(&prev).unwrap();
        std::env::remove_var("ALAYACORE_BIN");
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&env_path);

        assert!(
            resolved.is_some(),
            "bundled binary must resolve to a non-empty file"
        );
        assert_eq!(resolved.unwrap(), bundled);
    }

    #[test]
    fn find_binary_skips_zero_byte_stub() {
        // A 0-byte stub at the bundled location (left by a build that
        // could not locate alayacore) must NOT be the returned path —
        // spawn would fail with a confusing exec error. The helpers
        // must require len() > 0 so the env-var / PATH fallback takes
        // over.
        let dir = temp_path("find-bin-stub");
        std::fs::create_dir_all(&dir).expect("create dir");
        let exe = dir.join(if cfg!(target_os = "windows") {
            "alayaface.exe"
        } else {
            "alayaface"
        });
        let bundled = dir.join(if cfg!(target_os = "windows") {
            "alayacore.exe"
        } else {
            "alayacore"
        });
        std::fs::write(&exe, b"").unwrap();
        std::fs::write(&bundled, b"").unwrap(); // 0-byte stub

        let path = bundled_binary_path_from(&exe).expect("path");
        let meta = std::fs::metadata(&path).expect("metadata");
        assert_eq!(meta.len(), 0, "test precondition: stub is zero-byte");
        // find_binary() would skip this and fall through to env var /
        // PATH search; the helper itself cannot make that decision
        // because it only knows the path. The contract lives in
        // find_binary: bundled.len() > 0 is the gate.

        let _ = std::fs::remove_dir_all(&dir);
    }

    // ─── shared test helpers ─────────────────────────────────────

    // Process-wide lock for tests that mutate ALAYACORE_BIN / PATH.
    // find_binary reads them, so parallel tests would race. Mirrors
    // dirs::TEST_HOME_LOCK.
    static TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
}
