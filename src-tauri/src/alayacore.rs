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
/// 1. `ALAYACORE_BIN` environment variable
/// 2. `which alayacore` (Unix) or `where alayacore` (Windows)
/// 3. Known relative/absolute paths
/// 4. Fallback to "alayacore" (assume in PATH)
pub fn find_binary() -> String {
    // 1. Check env var
    if let Ok(bin) = std::env::var("ALAYACORE_BIN") {
        if !bin.is_empty() && std::path::Path::new(&bin).exists() {
            return bin;
        }
    }

    // 2. Try `which` (Unix) or `where` (Windows)
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

    // 3. Check common locations
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
/// take to drain an active task (auto-saving at task end) and exit on
/// stdin EOF before we SIGKILL it.
pub const GRACEFUL_CLOSE_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(5);

/// Gracefully close an alayacore child (used by close_session):
///
/// 1. Ask alayacore to persist the conversation (CI `save` — with an
///    empty filename it writes to the `--session` file). Best-effort:
///    a dead child produces a write error, which is ignored.
/// 2. Close stdin (EOF). alayacore drains an active task — completing
///    it and auto-saving via handleTaskDone — then exits; with no
///    active task it exits immediately. (There is no other graceful
///    exit signal in rawio mode: SIGINT is only wired up in the
///    plainio/terseio adapters, not rawio.)
/// 3. Wait up to `GRACEFUL_CLOSE_TIMEOUT` for a natural exit.
/// 4. SIGKILL fallback if the child is still alive.
///
/// `stdin` is the session's `Arc<tokio::sync::Mutex<Option<ChildStdin>>>` —
/// setting the slot to `None` closes the pipe no matter how many Arc clones
/// exist (prompt sends lock the same mutex, so no concurrent write can
/// interleave with the save frame).
pub fn close_child_gracefully(
    child: &mut Child,
    stdin: &tokio::sync::Mutex<Option<std::process::ChildStdin>>,
) {
    close_child_gracefully_with_timeout(child, stdin, GRACEFUL_CLOSE_TIMEOUT);
}

fn close_child_gracefully_with_timeout(
    child: &mut Child,
    stdin: &tokio::sync::Mutex<Option<std::process::ChildStdin>>,
    timeout: std::time::Duration,
) {
    // 1. Best-effort save (alayacore: empty filename → session file).
    //    try_lock (sync context) with a short retry in case a prompt
    //    send holds the mutex.
    let mut eof_sent = false;
    for _ in 0..10 {
        if let Ok(mut guard) = stdin.try_lock() {
            if let Some(writer) = guard.as_mut() {
                let msg = crate::tlv::CmdMsg {
                    id: "alayaface-close-save".to_string(),
                    name: "save".to_string(),
                    input: String::new(),
                };
                if let Ok(json) = serde_json::to_string(&msg) {
                    let _ = crate::tlv::write_frame(writer, crate::tlv::TAG_CMD_INPUT, &json);
                    let _ = writer.flush();
                }
            }
            // 2. EOF: drop the pipe regardless of remaining Arc clones.
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
    // 3. Wait for a natural exit.
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return,
            Ok(None) if start.elapsed() > timeout => break,
            Ok(None) => std::thread::sleep(std::time::Duration::from_millis(50)),
            Err(_) => return,
        }
    }
    // 4. Fallback: SIGKILL.
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

        // 1. The save CI frame reached the child's stdin. Empty `input`
        //    is omitted by CmdMsg's serializer — alayacore treats it as
        //    "save to the --session file".
        let bytes = std::fs::read(&out).expect("read captured stdin");
        let s = String::from_utf8_lossy(&bytes);
        assert!(s.contains("CI"), "no CI tag in captured stdin: {s:?}");
        assert!(s.contains("\"name\":\"save\""), "no save command: {s:?}");
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
            let mut p = spawn("/bin/echo", "", "", "", bt, "", None).unwrap();
            let mut out = String::new();
            p.stdout.read_to_string(&mut out).unwrap();
            let _ = p.child.wait();
            out
        };

        // Some("") → explicit empty flag: alayacore treats it as NO tools.
        let out = read_args(Some(""));
        assert!(
            out.contains("--builtin-tools=\n"),
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
}
