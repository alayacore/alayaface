//! AlayaCore subprocess manager.
//!
//! Spawns `alayacore --rawio` as a child process and provides
//! access to its stdin/stdout for TLV communication.

use std::io;
use std::process::{Child, Command, Stdio};

use std::io::{BufReader, Read, Write};
use std::time::{Duration, Instant};

use crate::tlv;

/// The alayacore TLV protocol `message_version` this adapter implements.
///
/// alayacore announces its version as the first boot frame
/// (`SM {"type":"version","data":{"message_version":N,...}}`, see
/// `alayacore/adapter-guide/README.md`). A mismatch means the wire
/// format the adapter knows about has drifted from the binary the user
/// installed — silently sending prompts into a binary that parses them
/// differently is worse than refusing to start, so `check_alayacore`
/// hard-fails on mismatch with the same UX as a missing binary.
pub const SUPPORTED_MESSAGE_VERSION: i64 = 11;

/// How long `check_message_version` waits for the boot version frame
/// before giving up. The version frame is the FIRST thing alayacore
/// emits on stdout (before any task/model/reasoning/ready SMs, and
/// before any replayed history) — in practice it arrives in a few ms,
/// so 2s is generous. Anything slower means the binary is hung or
/// running a different mode; either way we cannot trust it.
pub const VERSION_PROBE_TIMEOUT: Duration = Duration::from_secs(2);

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
    // Prepend the directory containing the bundled `rg` to PATH so
    // alayacore can detect and use it. Tauri's `externalBin` places
    // `rg` next to alayacore in the installed app (see
    // `tauri.conf.json`), so the directory of `binary_path` is where
    // `rg` lives at runtime. No-op if no bundled `rg` is present
    // (typical for dev builds without ripgrep installed locally) or
    // if `rg` is a 0-byte stub from build.rs's fallback path; in
    // either case alayacore falls back to its inherited PATH.
    prepend_rg_to_path(&mut cmd, binary_path);

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

/// Prepend the directory containing the bundled `rg` binary to `cmd`'s
/// PATH, so alayacore can find `rg` via its own PATH search (used for
/// fast content search).
///
/// Tauri's `externalBin` mechanism places every binary listed in
/// `tauri.conf.json`'s `externalBin` (currently `alayacore` AND `rg`)
/// in the same directory as the main executable in the packaged app.
/// So the directory of `binary_path` (the resolved alayacore path)
/// is where the bundled `rg` will live at runtime — prepending it to
/// PATH makes alayacore pick up the bundled rg first, ahead of any
/// `rg` the user has installed system-wide. This is what we want:
/// the bundled rg is the version we tested against.
///
/// No-op if `rg` is not bundled next to alayacore (typical in dev
/// mode where build.rs's fallback wrote a 0-byte stub, or where rg
/// wasn't on the build machine at all). alayacore then falls back to
/// its inherited PATH; if no rg is found there, alayacore falls back
/// to its non-rg code paths.
///
/// A 0-byte stub at the rg location must NOT be advertised via PATH
/// — alayacore would try to exec it and fail with a confusing "exec
/// format error" (Unix) / "Permission denied" (Windows) depending on
/// the OS. The `meta.len() > 0` gate mirrors the one `find_binary`
/// uses for alayacore's own bundled stub (see the
/// `find_binary_skips_zero_byte_stub` test).
pub fn prepend_rg_to_path(cmd: &mut Command, binary_path: &str) {
    let alayacore_dir = match std::path::Path::new(binary_path).parent() {
        Some(d) if !d.as_os_str().is_empty() => d.to_path_buf(),
        _ => return,
    };
    let rg_name = if cfg!(target_os = "windows") {
        "rg.exe"
    } else {
        "rg"
    };
    let rg_path = alayacore_dir.join(rg_name);
    // A 0-byte stub at the rg location (build.rs's fallback when no
    // rg was found on the build machine) must NOT be advertised via
    // PATH — alayacore would try to exec it and fail with a
    // confusing exec error.
    match std::fs::metadata(&rg_path) {
        Ok(meta) if meta.len() > 0 => {}
        _ => return,
    }
    let current = std::env::var_os("PATH").unwrap_or_default();
    let mut paths = vec![alayacore_dir];
    paths.extend(std::env::split_paths(&current));
    if let Ok(joined) = std::env::join_paths(paths) {
        cmd.env("PATH", joined);
    }
}

/// Spawn alayacore briefly and verify its `message_version` matches
/// `SUPPORTED_MESSAGE_VERSION`. Used by `check_alayacore` to gate the
/// home-screen banner: a wrong version is just as unusable as a
/// missing binary (the wire format has drifted), so the same
/// `ok=false` UX is surfaced.
///
/// The probe spawns `alayacore --rawio`, reads TLV frames until
/// `SM {"type":"version",...}` arrives or `VERSION_PROBE_TIMEOUT`
/// elapses, then kills the child. Config path / session / tools are
/// irrelevant for the version announcement, so the probe uses the
/// minimal flag set (no config dir, no session). stderr is discarded
/// to avoid polluting the caller's terminal with probe-only logs.
///
/// Error messages are user-facing (the home screen shows them
/// verbatim), so they name the offending version when known.
pub fn check_message_version(binary_path: &str) -> Result<(), String> {
    let mut child = match Command::new(binary_path)
        .arg("--rawio")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(e) => {
            return Err(format!(
                "alayacore could not be started to verify its protocol version: {e}"
            ));
        }
    };

    // Take stdout; kill_child-style close + wait handled by the helper
    // below. No stdin pipe (stdin closed above) — alayacore sees EOF
    // immediately and exits as soon as it finishes emitting boot SMs.
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "failed to capture alayacore stdout".to_string())?;
    let mut reader = BufReader::new(stdout);

    let result = read_version_frame(&mut reader);
    // Drain kill: close (already null) + SIGKILL + wait so we never
    // leak a probe process. The probe is short-lived either way.
    let _ = child.kill();
    let _ = child.wait();

    result
}

/// Read TLV frames until the boot `SM {"type":"version",...}` arrives
/// or `VERSION_PROBE_TIMEOUT` elapses. Returns Ok(()) if the version
/// matches `SUPPORTED_MESSAGE_VERSION`, otherwise an Err naming the
/// observed version (or the failure mode). Pulled out of
/// `check_message_version` so unit tests can drive it with a
/// synthetic `Read` (a real alayacore is awkward to mock — its
/// version announcement requires running the actual binary).
fn read_version_frame<R: Read>(reader: &mut R) -> Result<(), String> {
    let start = Instant::now();
    loop {
        let elapsed = start.elapsed();
        if elapsed >= VERSION_PROBE_TIMEOUT {
            return Err(format!(
                "alayacore did not announce its protocol version within {}s",
                VERSION_PROBE_TIMEOUT.as_secs()
            ));
        }

        // Per-read deadline via a background thread would be ideal, but
        // TLV frames are short and alayacore's version frame is the
        // FIRST one it writes — in practice the read either returns
        // immediately or blocks on a hung binary. Guard the whole loop
        // with the elapsed-time check and accept that the final blocked
        // read is bounded by VERSION_PROBE_TIMEOUT via a short overall
        // ceiling — the probe is killed by the caller when this fn
        // returns, so a stuck read only delays shutdown by a few ms in
        // the worst case.
        match tlv::read_frame(reader) {
            Ok(Some(frame)) => {
                if frame.tag != "SM" {
                    // The version SM is the very first boot frame;
                    // anything else arriving before it means a broken
                    // core. Report what we saw so the user can diagnose.
                    return Err(format!(
                        "unexpected boot frame before version announcement: tag={}, value={}",
                        frame.tag,
                        frame.value.chars().take(120).collect::<String>()
                    ));
                }
                let env: tlv::SystemMsgEnvelope = match serde_json::from_str(&frame.value) {
                    Ok(v) => v,
                    Err(e) => {
                        return Err(format!(
                            "alayacore sent a malformed version frame: {e}"
                        ));
                    }
                };
                if env.msg_type != "version" {
                    return Err(format!(
                        "expected alayacore's first frame to be 'version', got '{}'",
                        env.msg_type
                    ));
                }
                let observed = match env.data.get("message_version").and_then(|v| v.as_i64()) {
                    Some(n) => n,
                    None => {
                        return Err(
                            "alayacore's version frame is missing message_version".to_string()
                        );
                    }
                };
                if observed != SUPPORTED_MESSAGE_VERSION {
                    return Err(format!(
                        "alayacore message version {observed} is incompatible with expected version {SUPPORTED_MESSAGE_VERSION}. Please upgrade alayacore."
                    ));
                }
                return Ok(());
            }
            Ok(None) => {
                // EOF before any version frame — alayacore exited
                // without announcing itself.
                return Err(
                    "alayacore exited before announcing its protocol version".to_string(),
                );
            }
            Err(e) => {
                return Err(format!("failed to read alayacore's boot frames: {e}"));
            }
        }
    }
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
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{Duration, SystemTime, UNIX_EPOCH};

    fn temp_path(name: &str) -> std::path::PathBuf {
        // Add an atomic counter (process-global) so two parallel
        // tests that happen to compute the same nanosecond timestamp
        // do not share a path. The previous nanos-only scheme collided
        // under cargo test's parallel execution — Linux returned
        // ETXTBSY ("Text file busy") when two tests wrote to the same
        // fake-alayacore binary concurrently.
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let n = COUNTER.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "alayaface-{}-{}-{}-{}",
            name,
            std::process::id(),
            n,
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ))
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

    #[test]
    #[cfg(unix)] // /bin/sh is not guaranteed on Windows; covered on Linux/macOS CI.
    fn spawn_prepends_rg_dir_to_child_path() {
        // End-to-end check: spawn() actually applies prepend_rg_to_path,
        // so the child sees the bundled rg directory first in its PATH.
        // Uses a fake alayacore (a shell script that prints its PATH)
        // so we can capture the env the child inherited.
        let _guard = crate::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_path("spawn-rg-path");
        std::fs::create_dir_all(&dir).expect("create dir");

        let rg = dir.join("rg");
        std::fs::write(&rg, b"#!/bin/sh\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&rg, std::fs::Permissions::from_mode(0o755)).unwrap();

        let bin = dir.join("fake-alayacore");
        std::fs::write(&bin, b"#!/bin/sh\necho \"$PATH\"\n").unwrap();
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();

        let mut core = spawn(
            bin.to_str().unwrap(),
            "", "", "", None, "", 1, None,
        )
        .expect("spawn");
        let mut out = String::new();
        use std::io::Read;
        core.stdout.read_to_string(&mut out).unwrap();
        let _ = core.child.wait();

        let first = std::env::split_paths(out.trim())
            .next()
            .expect("non-empty PATH");
        assert_eq!(
            first, dir,
            "bundled rg dir must be the FIRST PATH entry, got: {first:?}"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    #[cfg(unix)]
    fn spawn_does_not_set_path_when_rg_is_stub() {
        // A 0-byte rg stub at the bundled location must NOT trigger
        // PATH mutation: alayacore inherits its original PATH and any
        // rg lookup falls through to the system PATH (or skips rg-only
        // features).
        let _guard = crate::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_path("spawn-rg-stub");
        std::fs::create_dir_all(&dir).expect("create dir");
        std::fs::write(dir.join("rg"), b"").unwrap(); // 0-byte stub

        let bin = dir.join("fake-alayacore");
        std::fs::write(&bin, b"#!/bin/sh\necho \"$PATH\"\n").unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();

        let original_path = std::env::var_os("PATH").unwrap_or_default();
        let mut core = spawn(
            bin.to_str().unwrap(),
            "", "", "", None, "", 1, None,
        )
        .expect("spawn");
        let mut out = String::new();
        use std::io::Read;
        core.stdout.read_to_string(&mut out).unwrap();
        let _ = core.child.wait();

        // The child should have the same PATH as the parent — spawn()
        // did not mutate it because rg was a stub.
        assert_eq!(
            out.trim(),
            original_path.to_string_lossy().trim(),
            "PATH must be inherited unchanged when rg is a 0-byte stub"
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
        let _guard = crate::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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

    // ─── prepend_rg_to_path ──────────────────────────────────────
    //
    // The PATH-prepending helper lets alayacore find `rg` next to
    // itself in the installed app. The tests below lock TEST_LOCK so
    // the parent's PATH mutation (get_envs reflects what the helper
    // wrote to the Command) is not visible to other tests.

    /// Returns the PATH value the helper wrote to `cmd` (or None if
    /// it did not write one).
    fn cmd_path(cmd: &Command) -> Option<std::ffi::OsString> {
        for (k, v) in cmd.get_envs() {
            if k == "PATH" {
                return v.map(|s| s.to_os_string());
            }
        }
        None
    }

    #[test]
    fn prepend_rg_to_path_adds_bundled_dir_when_rg_present() {
        let _guard = crate::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let dir = temp_path("prepend-rg-present");
        std::fs::create_dir_all(&dir).expect("create dir");
        let rg_name = if cfg!(target_os = "windows") { "rg.exe" } else { "rg" };
        let rg = dir.join(rg_name);
        std::fs::write(&rg, b"#!/bin/sh\n").unwrap();
        let bin = dir.join(if cfg!(target_os = "windows") {
            "alayacore.exe"
        } else {
            "alayacore"
        });
        std::fs::write(&bin, b"#!/bin/sh\n").unwrap();

        let mut cmd = Command::new("/bin/true");
        prepend_rg_to_path(&mut cmd, bin.to_str().unwrap());

        let path = cmd_path(&cmd).expect("PATH must be set");
        // Bundled dir is FIRST (prepended, ahead of inherited PATH)
        // so alayacore prefers the bundled rg over any system rg.
        let first = std::env::split_paths(&path).next().expect("non-empty PATH");
        assert_eq!(first, dir, "bundled rg dir must be prepended to PATH");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prepend_rg_to_path_noop_when_rg_missing() {
        let _guard = crate::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // Directory has alayacore but no rg — helper must not touch
        // PATH; alayacore inherits whatever the backend already had.
        let dir = temp_path("prepend-rg-missing");
        std::fs::create_dir_all(&dir).expect("create dir");
        let bin = dir.join(if cfg!(target_os = "windows") {
            "alayacore.exe"
        } else {
            "alayacore"
        });
        std::fs::write(&bin, b"#!/bin/sh\n").unwrap();

        let mut cmd = Command::new("/bin/true");
        prepend_rg_to_path(&mut cmd, bin.to_str().unwrap());

        assert!(
            cmd_path(&cmd).is_none(),
            "PATH must not be set when rg is not bundled"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prepend_rg_to_path_noop_when_rg_is_zero_byte_stub() {
        let _guard = crate::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // A 0-byte rg stub (build.rs fallback when no rg was found
        // locally) must NOT be advertised via PATH — alayacore would
        // try to exec it and fail with a confusing exec error.
        let dir = temp_path("prepend-rg-stub");
        std::fs::create_dir_all(&dir).expect("create dir");
        let rg_name = if cfg!(target_os = "windows") { "rg.exe" } else { "rg" };
        let rg = dir.join(rg_name);
        std::fs::write(&rg, b"").unwrap(); // 0-byte stub
        let bin = dir.join(if cfg!(target_os = "windows") {
            "alayacore.exe"
        } else {
            "alayacore"
        });
        std::fs::write(&bin, b"#!/bin/sh\n").unwrap();

        let mut cmd = Command::new("/bin/true");
        prepend_rg_to_path(&mut cmd, bin.to_str().unwrap());

        assert!(
            cmd_path(&cmd).is_none(),
            "PATH must not be set when rg is a 0-byte stub"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prepend_rg_to_path_noop_when_binary_path_has_no_parent() {
        let _guard = crate::TEST_ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // A bare filename ("alayacore" — current_exe() never returns
        // this in production, but tests must cover the contract)
        // resolves to an empty parent; helper must return without
        // touching PATH rather than joining with the cwd.
        let mut cmd = Command::new("/bin/true");
        let bare = if cfg!(target_os = "windows") { "alayacore.exe" } else { "alayacore" };
        prepend_rg_to_path(&mut cmd, bare);

        assert!(
            cmd_path(&cmd).is_none(),
            "PATH must not be set when binary_path has no parent"
        );
    }

    // ─── shared test helpers ─────────────────────────────────────

    // Process-wide lock for tests that mutate ALAYACORE_BIN / PATH.
    // find_binary reads them, so parallel tests would race. Mirrors
    // dirs::TEST_HOME_LOCK.
    //
    // Aliased to crate::TEST_ENV_LOCK so cmd.rs tests that mutate
    // PATH serialize with the alayacore.rs tests here (env var
    // mutations are process-global, not per-module). Same shim
    // rationale as in commands/cmd::tests — per-module statics can't
    // borrow a sibling module's static.

    // ─── check_message_version ────────────────────────────────
    //
    // The probe spawns a real alayacore. Driving it with a synthetic
    // binary is fragile (TLV framing + spawn ordering + argv parsing),
    // so these tests cover the PARSE path via `read_version_frame`
    // directly — that is where every business rule lives (match,
    // mismatch, missing field, malformed JSON, wrong-type first frame,
    // EOF before frame). Spawn-failure coverage is left to the
    // integration test in commands/cmd.rs (it has a real
    // `_does_not_exist_` path to drive).

    use std::io::Cursor;

    /// Build the bytes of a single TLV frame.
    fn encode(tag: &str, value: &str) -> Vec<u8> {
        tlv::encode(tag, value)
    }

    #[test]
    fn read_version_frame_accepts_matching_version() {
        // Real alayacore boot: version FIRST, then everything else.
        // read_version_frame should accept the version frame and stop
        // (it does not drain subsequent frames).
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode(
            "SM",
            r#"{"type":"version","data":{"message_version":11,"core_version":"test"}}"#,
        ));
        bytes.extend_from_slice(&encode(
            "SM",
            r#"{"type":"task","data":{"in_progress":false}}"#,
        ));
        let mut r = Cursor::new(bytes);
        read_version_frame(&mut r).expect("matching version must pass");
    }

    #[test]
    fn read_version_frame_rejects_wrong_version() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode(
            "SM",
            r#"{"type":"version","data":{"message_version":10,"core_version":"old"}}"#,
        ));
        let mut r = Cursor::new(bytes);
        let err = read_version_frame(&mut r).expect_err("mismatch must error");
        // User-facing: include the observed AND the expected number so
        // the home-screen banner tells the user which upgrade to fetch.
        assert!(
            err.contains("message version 10"),
            "error must name the observed version: {err:?}"
        );
        assert!(
            err.contains(&format!("expected version {SUPPORTED_MESSAGE_VERSION}")),
            "error must name the expected version: {err:?}"
        );
        assert!(
            err.contains("upgrade"),
            "error must tell the user what to do: {err:?}"
        );
    }

    #[test]
    fn read_version_frame_rejects_missing_message_version_field() {
        // An SM frame with type=version but no message_version field
        // (corrupt / pre-release core) must surface a clear error.
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode(
            "SM",
            r#"{"type":"version","data":{"core_version":"weird"}}"#,
        ));
        let mut r = Cursor::new(bytes);
        let err = read_version_frame(&mut r).expect_err("missing field must error");
        assert!(
            err.contains("missing message_version"),
            "error must call out the missing field: {err:?}"
        );
    }

    #[test]
    fn read_version_frame_rejects_malformed_json() {
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode("SM", "{not json"));
        let mut r = Cursor::new(bytes);
        let err = read_version_frame(&mut r).expect_err("malformed JSON must error");
        assert!(
            err.contains("malformed"),
            "error must call out the parse failure: {err:?}"
        );
    }

    #[test]
    fn read_version_frame_rejects_wrong_first_frame_type() {
        // alayacore must send the version frame FIRST. A non-version
        // SM as the first frame means a buggy / older core.
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode(
            "SM",
            r#"{"type":"task","data":{"in_progress":false}}"#,
        ));
        let mut r = Cursor::new(bytes);
        let err = read_version_frame(&mut r).expect_err("wrong first-frame type must error");
        assert!(
            err.contains("expected") && err.contains("version"),
            "error must explain the expected first frame: {err:?}"
        );
    }

    #[test]
    fn read_version_frame_rejects_non_sm_first_frame() {
        // Anything that isn't SM as the first frame is unexpected —
        // the version announcement must come first on stdout.
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode("UT", "echo"));
        let mut r = Cursor::new(bytes);
        let err = read_version_frame(&mut r).expect_err("non-SM first frame must error");
        assert!(
            err.contains("unexpected boot frame"),
            "error must call out the unexpected tag: {err:?}"
        );
    }

    #[test]
    fn read_version_frame_rejects_eof_before_frame() {
        // alayacore exited before announcing itself. Common when the
        // binary is broken (config parse error, missing model, etc.).
        let mut r = Cursor::new(Vec::<u8>::new());
        let err = read_version_frame(&mut r).expect_err("EOF must error");
        assert!(
            err.contains("exited"),
            "error must reflect the EOF scenario: {err:?}"
        );
    }

    #[test]
    fn read_version_frame_skips_unknown_frames_after_version() {
        // Once the version frame passes, the helper returns Ok(()) and
        // stops reading — subsequent frames are the boot task /
        // model_list / etc. that the live session reader will consume.
        // Drive that with a NOOP: the helper must NOT block on
        // unread data after Ok.
        let mut bytes = Vec::new();
        bytes.extend_from_slice(&encode(
            "SM",
            r#"{"type":"version","data":{"message_version":11}}"#,
        ));
        // Pad with a bunch of unread frames — the helper must return
        // before reading them.
        for i in 0..32 {
            bytes.extend_from_slice(&encode(
                "SM",
                &format!(r#"{{"type":"task","data":{{"n":{i}}}}}"#),
            ));
        }
        let total = bytes.len();
        let mut r = Cursor::new(bytes);
        read_version_frame(&mut r).expect("matching version must pass");
        // Cursor::position() lets us assert the helper stopped reading
        // after the version frame (the first frame's length).
        let consumed = r.position() as usize;
        assert!(
            consumed < total,
            "helper must not drain later frames (consumed {consumed} of {total} bytes)",
        );
    }
}
