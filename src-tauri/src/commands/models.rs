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
    if !model_cache.is_empty() {
        return Ok(model_cache.get());
    }

    // Ask any connected session. Pick it under the lock, then RELEASE the
    // lock: the write itself must not serialize other sessions' commands,
    // and the 2s wait for the model_list below must not freeze the whole
    // backend (Go's ListModels uses ForEach, which only holds the manager
    // lock for the snapshot).
    let target = {
        let map = sessions.0.lock().await;
        map.iter()
            .find(|(_, h)| h.connected.load(std::sync::atomic::Ordering::SeqCst))
            .map(|(id, _)| id.clone())
    };
    if let Some(sid) = target {
        // send_cmd registers the call ID → name mapping so the matching CO
        // frame is rendered with the command name.
        if send_cmd(sessions.inner(), &sid, "model_load", "").await.is_ok() {
            // WAIT for the SM model_list to populate the cache: the
            // reply arrives via the stdout reader thread, so checking
            // the cache immediately after send_cmd would always miss it
            // and silently fall through to the probe (while spamming
            // the live session with a pointless model_load on every
            // call). Sleep on the cache's notification instead of
            // polling (M6/D6); 2s bound, on timeout fall back to the
            // probe.
            if tokio::time::timeout(
                std::time::Duration::from_secs(2),
                model_cache.wait_non_empty(),
            )
            .await
            .is_ok()
            {
                return Ok(model_cache.get());
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
        // Mirror `alayacore::spawn`: advertise the bundled rg via
        // PATH so a probe that triggers alayacore's rg-using code
        // paths (e.g. listing models from a config that needs
        // content-search) doesn't fail just because the build
        // machine lacked rg on PATH. No-op without a bundled rg.
        crate::alayacore::prepend_rg_to_path(&mut cmd, bin);
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
                                    cache.set(arr.clone());
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

/// List the model list from a preset's model.conf (preset REQUIRED)
/// plus the preset's DEFAULT model id. Always reads the config directly
/// via a temporary alayacore process (never the session cache), so it
/// reflects what new sessions will load. The default (active) model is
/// stored by alayacore in the preset's runtime.conf as
/// `active_model: <name>`; the response's active_id is the matching
/// index in the returned model list (null when none matches).
#[tauri::command]
pub async fn list_default_models(binary_path: String, preset: String) -> Result<serde_json::Value, String> {
    let config_dir = dirs::resolve_config_dir(&preset)?;
    let config_path = config_dir.to_string_lossy().to_string();
    let bin = resolve_binary(&binary_path);
    let probe = run_temp_probe(&bin, &config_path, None, None)?;
    let models = probe.models.unwrap_or_default();

    let mut active_id: Option<serde_json::Value> = None;
    if let Some(name) = read_active_model_name(&config_dir) {
        for m in &models {
            if m.get("name").and_then(|v| v.as_str()) == Some(name.as_str()) {
                active_id = m.get("id").cloned();
                break;
            }
        }
    }
    Ok(serde_json::json!({ "models": models, "active_id": active_id }))
}

/// Read the `active_model: <name>` line from a preset's runtime.conf
/// (alayacore-managed key:value file). None when the file is missing or
/// has no active_model.
fn read_active_model_name(config_dir: &std::path::Path) -> Option<String> {
    let text = std::fs::read_to_string(config_dir.join("runtime.conf")).ok()?;
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(idx) = line.find(':') {
            let key = line[..idx].trim();
            if key == "active_model" {
                let value = line[idx + 1..].trim();
                if value.is_empty() {
                    continue;
                }
                // alayacore writes strings DOUBLE-QUOTED
                // (`active_model: "MyModel"`), like model.conf.
                return Some(if value.starts_with('"') && value.ends_with('"') {
                    serde_json::from_str::<String>(value).unwrap_or_else(|_| value.to_string())
                } else {
                    value.to_string()
                });
            }
        }
    }
    None
}

/// Set a preset's DEFAULT model: spawns a temporary alayacore with the
/// preset config dir and sends model_set, so alayacore persists
/// `active_model: <name>` into the preset's runtime.conf. New sessions
/// under the preset copy runtime.conf and start on that model.
#[tauri::command]
pub async fn set_default_model(preset: String, model_id: u32) -> Result<serde_json::Value, String> {
    let config_dir = dirs::resolve_config_dir(&preset)?;
    let config_path = config_dir.to_string_lossy().to_string();
    let bin = resolve_binary("");

    let call_id = uuid::Uuid::new_v4().to_string();
    let input = model_id.to_string();
    let probe = run_temp_probe(&bin, &config_path, Some((&call_id, "model_set", &input)), None)?;

    match probe.cmd_output {
        Some(v) => {
            let is_err = v.get("is_error").and_then(|x| x.as_bool()).unwrap_or(false);
            if is_err {
                let msg = v
                    .pointer("/output/message")
                    .and_then(|x| x.as_str())
                    .unwrap_or("model_set failed");
                Err(msg.to_string())
            } else {
                Ok(v.get("output").cloned().unwrap_or(serde_json::Value::Null))
            }
        }
        None => match probe.end {
            ProbeEnd::Timeout => Err("model_set timed out".to_string()),
            ProbeEnd::Eof => Err("alayacore exited before model_set completed".to_string()),
            _ => Err("Failed to read from alayacore".to_string()),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn read_active_model_name_parses_key_value_lines() {
        let dir = std::env::temp_dir().join(format!(
            "alayaface-active-model-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        // Missing file → None.
        assert_eq!(read_active_model_name(&dir), None);

        // active_model is a model NAME (alayacore format, strings
        // double-quoted like model.conf).
        std::fs::write(
            dir.join("runtime.conf"),
            "active_model: \"MyModel\"\nactive_theme: dark\n",
        )
        .unwrap();
        assert_eq!(read_active_model_name(&dir).as_deref(), Some("MyModel"));

        // Unquoted values are tolerated too.
        std::fs::write(dir.join("runtime.conf"), "active_model: MyModel\n").unwrap();
        assert_eq!(read_active_model_name(&dir).as_deref(), Some("MyModel"));

        // Comments and missing key → None.
        std::fs::write(
            dir.join("runtime.conf"),
            "# comment\nactive_theme: dark\n",
        )
        .unwrap();
        assert_eq!(read_active_model_name(&dir), None);

        // Empty value → None.
        std::fs::write(dir.join("runtime.conf"), "active_model:  \n").unwrap();
        assert_eq!(read_active_model_name(&dir), None);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn list_default_models_shape_matches_frontend() {
        // The response is an object {models, active_id} — pins the wire
        // shape the Elm decoder reads.
        let json = serde_json::json!({
            "models": [{"name": "a"}, {"name": "b"}],
            "active_id": 1,
        });
        assert_eq!(json["models"][1]["name"], "b");
        assert_eq!(json["active_id"], 1);
    }
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
