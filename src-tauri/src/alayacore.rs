//! AlayaCore subprocess manager.
//!
//! Spawns `alayacore --rawio` as a child process and provides
//! access to its stdin/stdout for TLV communication.

use std::io;
use std::process::{Child, Command, Stdio};

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
/// If `builtin_tools` is non-empty, passes `--builtin-tools=<list>`
/// (comma-separated; empty = don't pass the flag = alayacore default: all).
/// stderr is inherited so alayacore's own logs reach the terminal.
pub fn spawn(
    binary_path: &str,
    config_path: &str,
    session_path: &str,
    tool_confirm: &str,
    builtin_tools: &str,
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
    if !builtin_tools.is_empty() {
        cmd.arg(format!("--builtin-tools={}", builtin_tools));
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
/// Takes stdin first, then sends kill, then waits up to 3s for exit.
pub fn kill_child(child: &mut Child) {
    let _ = child.stdin.take();
    let _ = child.kill();
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
