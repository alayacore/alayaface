//! Model listing Tauri command.
//!
//! Lists available models by checking cache, then asking a connected session,
//! then falling back to a temporary alayacore process.

use crate::commands::{resolve_binary, SessionMap};
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
        for (_sid, handle) in map.iter() {
            if handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
                let mut stdin = handle.stdin.lock().await;
                let payload = serde_json::json!({
                    "id": uuid::Uuid::new_v4().to_string(),
                    "name": "model_load",
                    "input": "",
                });
                let _ = tlv::write_frame(&mut *stdin, tlv::TAG_CMD_INPUT, &payload.to_string());
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
