//! Model listing Tauri command.
//!
//! Lists available models by checking cache, then asking a connected session,
//! then falling back to a temporary alayacore process.

use crate::commands::{resolve_binary, SessionMap};
use crate::dirs;
use crate::tlv;
use crate::ModelCache;

use std::io::Write;
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
                let mut stdin = handle.stdin.lock().await;
                let payload = serde_json::json!({
                    "id": uuid::Uuid::new_v4().to_string(),
                    "name": "model_load",
                    "input": "",
                });
                let payload_str = payload.to_string();
                let preview: String = payload_str.chars().take(200).collect();
                log::info!("[tlv] >> {} {} {}b {}", sid, tlv::TAG_CMD_INPUT, payload_str.len(), preview);
                let _ = tlv::write_frame(&mut *stdin, tlv::TAG_CMD_INPUT, &payload_str);
                let _ = stdin.flush();
                let cache = model_cache.0.lock().unwrap();
                if !cache.is_empty() {
                    return Ok(cache.clone());
                }
                break;
            }
        }
    }

    // Fallback: spawn temp process
    let bin = resolve_binary(&binary_path);
    let mut cmd = std::process::Command::new(&bin);
    cmd.arg("--rawio");
    if !config_path.is_empty() {
        cmd.arg("--config-path").arg(&config_path);
    }
    let mut child = cmd
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to start alayacore: {e}"))?;

    drop(child.stdin.take());

    let mut stdout = child.stdout.take().ok_or_else(|| "Failed to capture stdout".to_string())?;
    let mut models = Vec::new();
    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(5);

    loop {
        if start.elapsed() > timeout {
            break;
        }
        match tlv::read_frame(&mut stdout) {
            Ok(Some(frame)) => {
                let preview: String = frame.value.chars().take(200).collect();
                log::info!("[tlv] << temp {} {}b {}", frame.tag, frame.value.len(), preview);
                if frame.tag == "SM" {
                    if let Ok(env) = serde_json::from_str::<tlv::SystemMsgEnvelope>(&frame.value) {
                        if env.msg_type == "model_list" {
                            if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                                models = arr.clone();
                                let mut cache = model_cache.0.lock().unwrap();
                                *cache = models.clone();
                            }
                            break;
                        }
                    }
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    drop(stdout);
    let _ = child.kill();
    let _ = child.wait();
    Ok(models)
}

// ─── Default (global) model list ─────────────────────────────────────
//
// The active preset's config (~/.alayaface/presets/<name>/model.conf) is the
// template new sessions are created from (each session gets its own copy).
// These commands read/replace that file directly through a temporary
// alayacore process, so validation and persistence behave exactly like
// session model_sync, but without touching any running session.

/// Spawn a temporary alayacore process and collect its model list from the
/// SM model_list message.
fn read_models_from_temp(
    bin: &str,
    config_path: &str,
) -> Result<Vec<serde_json::Value>, String> {
    let mut cmd = std::process::Command::new(bin);
    cmd.arg("--rawio");
    if !config_path.is_empty() {
        cmd.arg("--config-path").arg(config_path);
    }
    let mut child = cmd
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to start alayacore: {e}"))?;

    drop(child.stdin.take());

    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Failed to capture stdout".to_string())?;
    let mut models = Vec::new();
    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(5);

    loop {
        if start.elapsed() > timeout {
            break;
        }
        match tlv::read_frame(&mut stdout) {
            Ok(Some(frame)) => {
                let preview: String = frame.value.chars().take(200).collect();
                log::info!("[tlv] << temp {} {}b {}", frame.tag, frame.value.len(), preview);
                if frame.tag == "SM" {
                    if let Ok(env) = serde_json::from_str::<tlv::SystemMsgEnvelope>(&frame.value) {
                        if env.msg_type == "model_list" {
                            if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                                models = arr.clone();
                            }
                            break;
                        }
                    }
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    drop(stdout);
    let _ = child.kill();
    let _ = child.wait();
    Ok(models)
}

/// List the model list from a preset's model.conf (`preset` empty = active).
/// Always reads the config directly via a temporary alayacore process
/// (never the session cache), so it reflects what new sessions will load.
#[tauri::command]
pub async fn list_default_models(binary_path: String, preset: String) -> Result<Vec<serde_json::Value>, String> {
    let config_dir = dirs::resolve_config_dir(&preset)?;
    let config_path = config_dir.to_string_lossy().to_string();
    let bin = resolve_binary(&binary_path);
    read_models_from_temp(&bin, &config_path)
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

    let mut cmd = std::process::Command::new(&bin);
    cmd.arg("--rawio");
    cmd.arg("--config-path").arg(&config_path);
    let mut child = cmd
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .map_err(|e| format!("Failed to start alayacore: {e}"))?;

    let mut stdin = child
        .stdin
        .take()
        .ok_or_else(|| "Failed to capture stdin".to_string())?;
    let mut stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Failed to capture stdout".to_string())?;

    let call_id = uuid::Uuid::new_v4().to_string();
    let payload = serde_json::json!({
        "id": call_id,
        "name": "model_sync",
        "input": config,
    });
    let payload_str = payload.to_string();
    let preview: String = payload_str.chars().take(200).collect();
    log::info!("[tlv] >> temp {} {}b {}", tlv::TAG_CMD_INPUT, payload_str.len(), preview);
    let _ = tlv::write_frame(&mut stdin, tlv::TAG_CMD_INPUT, &payload_str);
    let _ = stdin.flush();

    let start = std::time::Instant::now();
    let timeout = std::time::Duration::from_secs(5);
    let result = loop {
        if start.elapsed() > timeout {
            break Err("model_sync timed out".to_string());
        }
        match tlv::read_frame(&mut stdout) {
            Ok(Some(frame)) => {
                let preview: String = frame.value.chars().take(200).collect();
                log::info!("[tlv] << temp {} {}b {}", frame.tag, frame.value.len(), preview);
                if frame.tag == "SM" {
                    // Refresh the shared cache with the synced list
                    if let Ok(env) = serde_json::from_str::<tlv::SystemMsgEnvelope>(&frame.value) {
                        if env.msg_type == "model_list" {
                            if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                                let mut cache = model_cache.0.lock().unwrap();
                                *cache = arr.clone();
                            }
                        }
                    }
                } else if frame.tag == "CO" {
                    if let Ok(v) = serde_json::from_str::<serde_json::Value>(&frame.value) {
                        let is_ours = v.get("id").and_then(|x| x.as_str()) == Some(call_id.as_str());
                        if is_ours {
                            let is_err = v.get("is_error").and_then(|x| x.as_bool()).unwrap_or(false);
                            if is_err {
                                let msg = v
                                    .pointer("/output/message")
                                    .and_then(|x| x.as_str())
                                    .unwrap_or("model_sync failed");
                                break Err(msg.to_string());
                            }
                            break Ok(v.get("output").cloned().unwrap_or(serde_json::Value::Null));
                        }
                    }
                }
            }
            Ok(None) => break Err("alayacore exited before model_sync completed".to_string()),
            Err(_) => break Err("Failed to read from alayacore".to_string()),
        }
    };

    drop(stdin);
    drop(stdout);
    let _ = child.kill();
    let _ = child.wait();
    result
}
