//! Model listing Tauri command.
//!
//! Lists available models by checking cache, then asking a connected session,
//! then falling back to a temporary alayacore process.

use crate::commands::{resolve_binary, send_cmd, SessionMap};
use crate::dirs;
use crate::tlv;
use crate::ModelCache;

use std::io::Write;
use std::process::{Child, Command, Stdio};
use tauri::State;

#[tauri::command]
pub async fn list_models(
    binary_path: String,
    config_path: String,
    model_cache: State<'_, ModelCache>,
    sessions: State<'_, SessionMap>,
) -> Result<Vec<serde_json::Value>, String> {
    // Try cache first
    {
        let cache = model_cache.0.lock().unwrap();
        if !cache.is_empty() {
            return Ok(cache.clone());
        }
    }

    // Ask any connected session
    {
        let map = sessions.0.lock().await;
        for (sid, handle) in map.iter() {
            if handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
                // send_cmd registers the call ID → name mapping so the
                // matching CO frame is rendered with the command name.
                let _ = send_cmd(&map, sid, "model_load", "").await;
                let cache = model_cache.0.lock().unwrap();
                if !cache.is_empty() {
                    return Ok(cache.clone());
                }
                break;
            }
        }
    }

    // Fallback: probe with a temporary process
    let bin = resolve_binary(&binary_path);
    let probe = run_temp_probe(&bin, &config_path, None, Some(&model_cache))?;
    Ok(probe.models.unwrap_or_default())
}

// ─── Temporary alayacore probes ─────────────────────────────────────
//
// list_models' fallback, list_default_models, and sync_default_models all
// used to duplicate the same dance: spawn a throwaway `alayacore --rawio`,
// optionally send one CI command, then read TLV frames until the SM
// model_list (and/or the matching CO) arrives or a timeout elapses. This
// section captures that protocol once.

/// A throwaway alayacore process with its pipes.
struct TempCore {
    child: Child,
    stdin: Option<std::process::ChildStdin>,
    stdout: std::io::BufReader<std::process::ChildStdout>,
}

impl TempCore {
    fn spawn(bin: &str, config_path: &str) -> Result<Self, String> {
        let mut cmd = Command::new(bin);
        cmd.arg("--rawio");
        if !config_path.is_empty() {
            cmd.arg("--config-path").arg(config_path);
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("Failed to start alayacore: {e}"))?;

        let stdin = child.stdin.take();
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| "Failed to capture stdout".to_string())?;

        Ok(TempCore {
            child,
            stdin,
            stdout: std::io::BufReader::new(stdout),
        })
    }

    fn kill(mut self) {
        drop(self.stdout);
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Why a probe stopped reading.
#[derive(Debug, Clone, Copy, PartialEq)]
enum ProbeEnd {
    /// The target frame(s) arrived.
    Complete,
    /// Nothing arrived within the timeout.
    Timeout,
    /// alayacore closed stdout (exited).
    Eof,
    /// Reading stdout failed.
    ReadError,
}

/// What a probe collected.
struct ProbeResult {
    /// First SM model_list payload, if seen.
    models: Option<Vec<serde_json::Value>>,
    /// CO frame JSON matching the probe's call ID, if any.
    cmd_output: Option<serde_json::Value>,
    /// Why the read loop stopped.
    end: ProbeEnd,
}

/// Run a temporary alayacore probe.
///
/// `cmd` optionally sends one CI command first (`(call_id, name, input)`);
/// the matching CO is captured in `ProbeResult::cmd_output`. `model_cache`,
/// when given, is refreshed from any SM model_list seen (mirrors how live
/// sessions populate it).
fn run_temp_probe(
    bin: &str,
    config_path: &str,
    cmd: Option<(&str, &str, &str)>,
    model_cache: Option<&ModelCache>,
) -> Result<ProbeResult, String> {
    let mut core = TempCore::spawn(bin, config_path)?;

    // Optionally send one command, then close stdin.
    if let Some((call_id, name, input)) = cmd {
        let payload = serde_json::json!({
            "id": call_id,
            "name": name,
            "input": input,
        });
        let payload_str = payload.to_string();
        let preview: String = payload_str.chars().take(200).collect();
        log::info!("[tlv] >> temp {} {}b {}", tlv::TAG_CMD_INPUT, payload_str.len(), preview);
        if let Some(stdin) = core.stdin.as_mut() {
            let _ = tlv::write_frame(stdin, tlv::TAG_CMD_INPUT, &payload_str);
            let _ = stdin.flush();
        }
    }
    drop(core.stdin.take());

    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(5);
    let mut result = ProbeResult {
        models: None,
        cmd_output: None,
        end: ProbeEnd::Timeout,
    };

    loop {
        if start.elapsed() > timeout {
            result.end = ProbeEnd::Timeout;
            break;
        }
        match tlv::read_frame(&mut core.stdout) {
            Ok(Some(frame)) => {
                let preview: String = frame.value.chars().take(200).collect();
                log::info!("[tlv] << temp {} {}b {}", frame.tag, frame.value.len(), preview);
                if frame.tag == "SM" {
                    if let Ok(env) = serde_json::from_str::<tlv::SystemMsgEnvelope>(&frame.value) {
                        if env.msg_type == "model_list" {
                            if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                                result.models = Some(arr.clone());
                                if let Some(cache) = &model_cache {
                                    let mut cache = cache.0.lock().unwrap();
                                    *cache = arr.clone();
                                }
                            }
                        }
                    }
                    // Without a pending command the model list is all we
                    // need; with a pending command we must keep reading
                    // for the CO.
                    if cmd.is_none() && result.models.is_some() {
                        result.end = ProbeEnd::Complete;
                        break;
                    }
                } else if frame.tag == "CO" {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&frame.value) {
                        let is_ours = match cmd {
                            Some((call_id, _, _)) => {
                                v.get("id").and_then(|x| x.as_str()) == Some(call_id)
                            }
                            None => true,
                        };
                        if is_ours {
                            result.cmd_output = Some(v);
                            result.end = ProbeEnd::Complete;
                            break;
                        }
                    }
                }
            }
            Ok(None) => {
                result.end = ProbeEnd::Eof;
                break;
            }
            Err(_) => {
                result.end = ProbeEnd::ReadError;
                break;
            }
        }
    }

    core.kill();
    Ok(result)
}

// ─── Default (global) model list ─────────────────────────────────────
//
// The active preset's config (~/.alayaface/presets/<name>/model.conf) is the
// template new sessions are created from (each session gets its own copy).
// These commands read/replace that file directly through a temporary
// alayacore process, so validation and persistence behave exactly like
// session model_sync, but without touching any running session.

/// List the model list from a preset's model.conf (`preset` empty = active).
/// Always reads the config directly via a temporary alayacore process
/// (never the session cache), so it reflects what new sessions will load.
#[tauri::command]
pub async fn list_default_models(binary_path: String, preset: String) -> Result<Vec<serde_json::Value>, String> {
    let config_dir = dirs::resolve_config_dir(&preset)?;
    let config_path = config_dir.to_string_lossy().to_string();
    let bin = resolve_binary(&binary_path);
    let probe = run_temp_probe(&bin, &config_path, None, None)?;
    Ok(probe.models.unwrap_or_default())
}

/// Replace the model list in a preset's model.conf (`preset` empty = active).
/// Spawns a temporary alayacore with that config dir and sends
/// model_sync, waiting for the CO result. Validation, key-value
/// serialization and persistence are all performed by alayacore. The
/// refreshed model list is cached for later list_models calls.
#[tauri::command]
pub async fn sync_default_models(
    binary_path: String,
    config: String,
    preset: String,
    model_cache: State<'_, ModelCache>,
) -> Result<serde_json::Value, String> {
    let config_dir = dirs::resolve_config_dir(&preset)?;
    let config_path = config_dir.to_string_lossy().to_string();
    let bin = resolve_binary(&binary_path);

    let call_id = uuid::Uuid::new_v4().to_string();
    let probe = run_temp_probe(&bin, &config_path, Some((&call_id, "model_sync", &config)), Some(&model_cache))?;

    match probe.cmd_output {
        Some(v) => {
            let is_err = v.get("is_error").and_then(|x| x.as_bool()).unwrap_or(false);
            if is_err {
                let msg = v
                    .pointer("/output/message")
                    .and_then(|x| x.as_str())
                    .unwrap_or("model_sync failed");
                Err(msg.to_string())
            } else {
                Ok(v.get("output").cloned().unwrap_or(serde_json::Value::Null))
            }
        }
        None => match probe.end {
            ProbeEnd::Timeout => Err("model_sync timed out".to_string()),
            ProbeEnd::Eof => Err("alayacore exited before model_sync completed".to_string()),
            _ => Err("Failed to read from alayacore".to_string()),
        },
    }
}
