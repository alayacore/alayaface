//! Tauri commands for the AlayaFace application.
//!
//! These are the IPC endpoints exposed to the React frontend.
//! Each command delegates to the appropriate module for business logic.

use crate::alayacore;
use crate::session::{self, SessionMap};
use crate::tlv;
use crate::dirs;
use crate::ModelCache;

use serde::Serialize;
use std::io::BufRead;
use std::io::Write;
use tauri::{AppHandle, State};
use uuid::Uuid;

#[derive(Serialize)]
pub struct SessionDirInfo {
    pub id: String,
    pub has_session_file: bool,
    pub created_at: String,
}

#[derive(serde::Deserialize)]
pub struct MediaItem {
    pub media_type: String,
    pub uri: String,
}

// ─── Session Lifecycle ───────────────────────────────────────────────

#[tauri::command]
pub async fn create_session(
    app: AppHandle,
    binary_path: String,
    config_path: String,
    tool_confirm: Option<String>,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let (_template_dir, sessions_dir) = dirs::ensure()?;

    let bin = resolve_binary(&binary_path);
    let session_id = Uuid::new_v4().to_string();
    let session_dir = dirs::create_session_dir(&sessions_dir, &session_id)?;

    let effective_config = if config_path.is_empty() {
        session_dir.join("config").to_string_lossy().to_string()
    } else {
        config_path
    };
    let session_file = session_dir.join("session.md").to_string_lossy().to_string();

    let tc = tool_confirm.unwrap_or_default();
    log::info!("Spawning: {} --rawio --config-path {} --session {}", &bin, &effective_config, &session_file);
    if !tc.is_empty() {
        log::info!("  with --tool-confirm={}", &tc);
    }

    session::create(&app, &bin, &effective_config, &session_file, session_dir, &sessions, &model_cache, &tc).await
}

#[tauri::command]
pub async fn resume_session(
    app: AppHandle,
    session_id: String,
    binary_path: String,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let sessions_dir = dirs::alayaface_dir().join("sessions").join(&session_id);
    let session_file = sessions_dir.join("session.md");
    let config_dir = sessions_dir.join("config");

    if !sessions_dir.exists() {
        return Err(format!("Session directory not found: {:?}", sessions_dir));
    }
    if !session_file.exists() {
        return Err(format!("Session file not found: {:?}", session_file));
    }
    if !config_dir.exists() {
        return Err(format!("Config directory not found: {:?}", config_dir));
    }

    // Check not already running
    if sessions.0.lock().await.contains_key(&session_id) {
        return Err("Session is already active".to_string());
    }

    let bin = resolve_binary(&binary_path);
    let config_path = config_dir.to_string_lossy().to_string();
    let session_path = session_file.to_string_lossy().to_string();

    session::create(&app, &bin, &config_path, &session_path, sessions_dir, &sessions, &model_cache, "").await
}

#[tauri::command]
pub async fn close_session(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    session::close(&session_id, &sessions).await
}

#[tauri::command]
pub async fn list_sessions(
    sessions: State<'_, SessionMap>,
) -> Result<Vec<String>, String> {
    let map = sessions.0.lock().await;
    Ok(map.keys().cloned().collect())
}

#[tauri::command]
pub async fn session_connected(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<bool, String> {
    let map = sessions.0.lock().await;
    let handle = session::get(&map, &session_id)?;
    Ok(handle.connected.load(std::sync::atomic::Ordering::SeqCst))
}

// ─── Session Directory Management ────────────────────────────────────

#[tauri::command]
pub async fn list_session_dirs() -> Result<Vec<SessionDirInfo>, String> {
    let sessions_dir = dirs::alayaface_dir().join("sessions");
    if !sessions_dir.exists() {
        return Ok(Vec::new());
    }

    let mut entries: Vec<_> = std::fs::read_dir(&sessions_dir)
        .map_err(|e| format!("Cannot read sessions dir: {e}"))?
        .filter_map(|e| e.ok())
        .collect();
    entries.sort_by_key(|e| std::cmp::Reverse(e.path().metadata().ok().and_then(|m| m.modified().ok())));

    let mut result = Vec::new();
    for entry in entries {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let id = entry.file_name().to_string_lossy().to_string();
        let session_file = path.join("session.md");
        let created_at = path.metadata().ok()
            .and_then(|m| m.created().ok())
            .map(|t| t.duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs().to_string())
            .unwrap_or_else(|| "0".to_string());

        result.push(SessionDirInfo {
            id,
            has_session_file: session_file.exists(),
            created_at,
        });
    }
    Ok(result)
}

#[tauri::command]
pub async fn delete_session_dir(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    // Close if running
    let _ = session::close(&session_id, &sessions).await;

    let session_dir = dirs::alayaface_dir().join("sessions").join(&session_id);
    if session_dir.exists() {
        std::fs::remove_dir_all(&session_dir)
            .map_err(|e| format!("Cannot delete {:?}: {}", session_dir, e))?;
    }
    Ok(())
}

#[tauri::command]
pub async fn fork_session(
    app: AppHandle,
    source_session_id: String,
    history_id: String,
    binary_path: String,
    sessions: State<'_, SessionMap>,
    model_cache: State<'_, ModelCache>,
) -> Result<String, String> {
    let (_template_dir, sessions_dir) = dirs::ensure()?;
    let new_id = Uuid::new_v4().to_string();
    let new_session_dir = dirs::create_session_dir(&sessions_dir, &new_id)?;
    let target_file = new_session_dir.join("session.md").to_string_lossy().to_string();
    let config_path = new_session_dir.join("config").to_string_lossy().to_string();

    log::info!("Forking {} up to history {} → {}", &source_session_id, &history_id, &target_file);

    // Tell source alayacore to fork
    {
        let map = sessions.0.lock().await;
        let cmd = format!(":fork {} {}", history_id, target_file);
        send_raw(&map, &source_session_id, tlv::TAG_USER_TEXT, &cmd).await?;
        send_raw(&map, &source_session_id, tlv::TAG_USER_END, "").await?;
    }

    // Wait for session file to stabilize
    wait_for_file(&target_file).await?;

    let bin = resolve_binary(&binary_path);
    session::create(&app, &bin, &config_path, &target_file, new_session_dir, &sessions, &model_cache, "").await
}

async fn wait_for_file(path: &str) -> Result<(), String> {
    let target_path = std::path::Path::new(path);
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    let mut seen_size = 0u64;

    loop {
        if let Ok(meta) = target_path.metadata() {
            let len = meta.len();
            if len > 0 && len == seen_size {
                return Ok(());
            }
            if len > 0 {
                seen_size = len;
            }
        }
        if std::time::Instant::now() > deadline {
            if seen_size > 0 {
                return Ok(());
            }
            return Err("Timeout waiting for fork to complete".to_string());
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
}

// ─── Session I/O ─────────────────────────────────────────────────────

async fn send_raw(
    map: &std::collections::HashMap<String, crate::session::SessionHandle>,
    session_id: &str,
    tag: &str,
    value: &str,
) -> Result<(), String> {
    let handle = session::get(map, session_id)?;
    if !handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("Session is disconnected".to_string());
    }
    let mut stdin = handle.stdin.lock().await;
    tlv::write_frame(&mut *stdin, tag, value).map_err(|e| format!("Write error: {e}"))?;
    stdin.flush().map_err(|e| format!("Flush error: {e}"))?;

    // Log outgoing frame for debugging
    let preview: String = value.chars().take(200).collect();
    log::debug!("[tlv] >> {} {} {}b {}", session_id, tag, value.len(), preview);

    Ok(())
}

#[tauri::command]
pub async fn alayacore_send_message(
    session_id: String,
    text: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &text).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_send_prompt(
    session_id: String,
    text: String,
    media: Vec<MediaItem>,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let handle = session::get(&map, &session_id)?;
    if !handle.connected.load(std::sync::atomic::Ordering::SeqCst) {
        return Err("Session is disconnected".to_string());
    }

    let mut stdin = handle.stdin.lock().await;
    for item in &media {
        let tag = match item.media_type.as_str() {
            "image" => tlv::TAG_USER_IMAGE,
            "audio" => tlv::TAG_USER_AUDIO,
            "video" => tlv::TAG_USER_VIDEO,
            "document" => tlv::TAG_USER_DOC,
            _ => return Err(format!("Unknown media type: {}", item.media_type)),
        };
        tlv::write_frame(&mut *stdin, tag, &item.uri).map_err(|e| format!("Write error: {e}"))?;
    }
    if !text.is_empty() {
        tlv::write_frame(&mut *stdin, tlv::TAG_USER_TEXT, &text).map_err(|e| format!("Write error: {e}"))?;
    }
    tlv::write_frame(&mut *stdin, tlv::TAG_USER_END, "").map_err(|e| format!("Write error: {e}"))?;
    stdin.flush().map_err(|e| format!("Flush error: {e}"))?;
    Ok(())
}

#[tauri::command]
pub async fn alayacore_send_raw_frame(
    session_id: String,
    tag: String,
    value: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, &tag, &value).await
}

// ─── Commands ────────────────────────────────────────────────────────

macro_rules! send_cmd {
    ($name:ident, $fmt:expr) => {
        #[tauri::command]
        pub async fn $name(
            session_id: String,
            sessions: State<'_, SessionMap>,
        ) -> Result<(), String> {
            let map = sessions.0.lock().await;
            send_raw(&map, &session_id, tlv::TAG_USER_TEXT, $fmt).await?;
            send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
        }
    };
}

send_cmd!(alayacore_cancel, ":cancel");
send_cmd!(alayacore_model_load, ":model_load");
send_cmd!(alayacore_continue, ":continue");
send_cmd!(alayacore_summarize, ":summarize");

#[tauri::command]
pub async fn alayacore_model_set(
    session_id: String,
    model_id: u32,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":model_set {}", model_id)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_save(
    session_id: String,
    filename: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let cmd = if filename.is_empty() { ":save".to_string() } else { format!(":save {}", filename) };
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &cmd).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_fork(
    session_id: String,
    history_id: String,
    filename: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let cmd = format!(":fork {} {}", history_id, filename);
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &cmd).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_reason(
    session_id: String,
    level: u32,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":reason {}", level)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_theme_set(
    session_id: String,
    name: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":theme_set {}", name)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_model_sync(
    session_id: String,
    config: String,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":model_sync {}", config)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_video_config(
    session_id: String,
    fps: u32,
    res: u32,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &format!(":video_config {} {}", fps, res)).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

#[tauri::command]
pub async fn alayacore_confirm(
    session_id: String,
    id: String,
    allowed: bool,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    let map = sessions.0.lock().await;
    let cmd = if allowed {
        format!(":tool_confirm {}", id)
    } else {
        format!(":tool_decline {}", id)
    };
    send_raw(&map, &session_id, tlv::TAG_USER_TEXT, &cmd).await?;
    send_raw(&map, &session_id, tlv::TAG_USER_END, "").await
}

// ─── MCP OAuth Flow ──────────────────────────────────────────────────

/// Start the MCP OAuth flow: launch callback server, fill URL, open browser.
/// Returns the filled URL so the frontend can also copy it.
#[tauri::command]
pub async fn start_mcp_auth_flow(
    session_id: String,
    server_name: String,
    auth_url: String,
    sessions: State<'_, SessionMap>,
) -> Result<String, String> {
    start_mcp_auth_inner(&session_id, &server_name, &auth_url, &sessions, true).await
}

/// Fill the MCP auth URL without opening browser.
/// Returns the filled URL for the frontend to copy.
#[tauri::command]
pub async fn fill_mcp_auth_url(
    session_id: String,
    server_name: String,
    auth_url: String,
    sessions: State<'_, SessionMap>,
) -> Result<String, String> {
    start_mcp_auth_inner(&session_id, &server_name, &auth_url, &sessions, false).await
}

/// Shared implementation: start callback server, fill URL, optionally open browser.
async fn start_mcp_auth_inner(
    session_id: &str,
    server_name: &str,
    auth_url: &str,
    sessions: &State<'_, SessionMap>,
    open_browser: bool,
) -> Result<String, String> {
    let sessions_arc = sessions.0.clone();
    let sid_owned = session_id.to_string();
    let sname_owned = server_name.to_string();

    // Generate random state for CSRF protection (128-bit hex)
    let state = {
        let u1: u64 = rand::random();
        let u2: u64 = rand::random();
        format!("{:016x}{:016x}", u1, u2)
    };

    // Start callback server
    let listener = std::net::TcpListener::bind("127.0.0.1:0")
        .map_err(|e| format!("Failed to bind callback server: {e}"))?;
    let port = listener.local_addr().map_err(|e| format!("Failed to get port: {e}"))?.port();
    let redirect_uri = format!("http://127.0.0.1:{}/callback", port);

    // Fill the auth URL with redirect_uri and state
    let encoded_redirect = urlencoding::encode(&redirect_uri);
    let filled_url = auth_url
        .replace("{{redirect_uri}}", &encoded_redirect)
        .replace("{{state}}", &state);

    log::info!("[mcp_auth] Started OAuth flow for {} on port {}", server_name, port);
    log::info!("[mcp_auth] Filled URL: {}", filled_url);

    // Open browser if requested
    if open_browser {
        if let Err(e) = open::that(&filled_url) {
            log::warn!("[mcp_auth] Failed to open browser: {}", e);
        }
    }

    // Accept callback in a background thread
    let sid = sid_owned;
    let sname = sname_owned;
    let ruri = redirect_uri.clone();
    std::thread::spawn(move || {
        match listener.accept() {
            Ok((mut stream, addr)) => {
                log::info!("[mcp_auth] Callback received from {}", addr);
                let mut reader = std::io::BufReader::new(&stream);
                let mut request_line = String::new();
                if reader.read_line(&mut request_line).is_err() {
                    log::error!("[mcp_auth] Failed to read request line");
                    let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, None);
                    return;
                }
                let parts: Vec<&str> = request_line.split_whitespace().collect();
                let path = if parts.len() >= 2 { parts[1] } else { "/" };
                let query_str = path.split('?').nth(1).unwrap_or("");
                let params: std::collections::HashMap<String, String> =
                    url::form_urlencoded::parse(query_str.as_bytes())
                        .into_owned()
                        .collect();
                let http_body = format!(
                    "<!DOCTYPE html><html><body style='display:flex;justify-content:center;align-items:center;height:100vh;font-family:sans-serif;'>                    <div style='text-align:center;'><h2>Authorization {}</h2>                    <p style='color:#666;'>You can close this window.</p></div></body></html>",
                    if params.contains_key("code") { "Successful" } else { "Failed" }
                );
                let http_response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: {}\r\n\r\n{}",
                    http_body.len(), http_body
                );
                let _ = stream.write_all(http_response.as_bytes());
                if let Some(err) = params.get("error") {
                    let desc = params.get("error_description").map(|s| s.as_str()).unwrap_or("");
                    log::error!("[mcp_auth] Auth error: {}: {}", err, desc);
                    let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, None);
                    return;
                }
                match params.get("state") {
                    Some(returned_state) if returned_state == &state => {}
                    _ => {
                        log::warn!("[mcp_auth] State mismatch");
                        let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, None);
                        return;
                    }
                }
                match params.get("code") {
                    Some(code) => {
                        log::info!("[mcp_auth] Authorization code received");
                        let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, Some(code));
                    }
                    None => {
                        log::warn!("[mcp_auth] No authorization code in callback");
                        let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, None);
                    }
                }
            }
            Err(e) => {
                log::error!("[mcp_auth] Accept error: {}", e);
                let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, None);
            }
        }
    });

    Ok(filled_url)
}

fn send_mcp_result(
    sessions_arc: &std::sync::Arc<tokio::sync::Mutex<std::collections::HashMap<String, session::SessionHandle>>>,
    session_id: &str,
    server_name: &str,
    redirect_uri: &str,
    code: Option<&str>,
) -> Result<(), String> {
    let rt = tokio::runtime::Runtime::new().map_err(|e| format!("Runtime error: {e}"))?;
    rt.block_on(async {
        let map = sessions_arc.lock().await;
        let handle = session::get(&map, session_id)?;
        let mut stdin = handle.stdin.lock().await;

        match code {
            Some(c) => {
                let cmd = format!(":mcp_confirm {} {} {}", server_name, c, redirect_uri);
                log::info!("[mcp_auth] Sending: {}", cmd);
                tlv::write_frame(&mut *stdin, tlv::TAG_USER_TEXT, &cmd)
                    .map_err(|e| format!("Write error: {e}"))?;
                tlv::write_frame(&mut *stdin, tlv::TAG_USER_END, "")
                    .map_err(|e| format!("Write error: {e}"))?;
            }
            None => {
                log::info!("[mcp_auth] Auth failed/cancelled — sending :mcp_decline {}", server_name);
                let cmd = format!(":mcp_decline {}", server_name);
                tlv::write_frame(&mut *stdin, tlv::TAG_USER_TEXT, &cmd)
                    .map_err(|e| format!("Write error: {e}"))?;
                tlv::write_frame(&mut *stdin, tlv::TAG_USER_END, "")
                    .map_err(|e| format!("Write error: {e}"))?;
            }
        }
        stdin.flush().map_err(|e| format!("Flush error: {e}"))?;
        Ok(())
    })
}

#[tauri::command]
pub async fn get_stderr_log(
    session_id: String,
    sessions: State<'_, SessionMap>,
) -> Result<Vec<String>, String> {
    let map = sessions.0.lock().await;
    let handle = session::get(&map, &session_id)?;
    let log = handle.stderr_log.lock().await.clone();
    Ok(log)
}

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
                let _ = tlv::write_frame(&mut *stdin, tlv::TAG_USER_TEXT, ":model_load");
                let _ = tlv::write_frame(&mut *stdin, tlv::TAG_USER_END, "");
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

// ─── File System ─────────────────────────────────────────────────────

#[derive(Serialize)]
pub struct DirEntry {
    pub name: String,
    #[serde(rename = "isDir")]
    pub is_dir: bool,
}

/// List the contents of a directory.
/// Returns an error if the path doesn't exist or isn't a directory.
/// Includes ".." entry for all directories except root ("/").
#[tauri::command]
pub async fn fs_list_dir(path: String) -> Result<Vec<DirEntry>, String> {
    let dir = std::path::Path::new(&path);
    if !dir.exists() {
        return Err(format!("Path does not exist: {}", path));
    }
    if !dir.is_dir() {
        return Err(format!("Not a directory: {}", path));
    }

    let mut entries = std::fs::read_dir(dir)
        .map_err(|e| format!("Cannot read directory: {}", e))?
        .filter_map(|e| e.ok())
        .collect::<Vec<_>>();
    entries.sort_by_key(|e| e.file_name());

    let mut result = Vec::with_capacity(entries.len() + 1);

    // Add ".." parent entry for all directories except root
    if path != "/" {
        result.push(DirEntry {
            name: "..".to_string(),
            is_dir: true,
        });
    }

    // Separate dirs and files for sorting: dirs first, then files
    let mut dirs: Vec<DirEntry> = Vec::new();
    let mut files: Vec<DirEntry> = Vec::new();

    for entry in entries {
        let name = entry.file_name().to_string_lossy().to_string();
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        let de = DirEntry {
            name,
            is_dir,
        };
        if is_dir {
            dirs.push(de);
        } else {
            files.push(de);
        }
    }

    // Directories first (sorted), then files (sorted)
    dirs.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    files.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    result.extend(dirs);
    result.extend(files);

    Ok(result)
}

/// Get the user's home directory path.
#[tauri::command]
pub async fn fs_home_dir() -> Result<String, String> {
    std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| "Cannot determine home directory".to_string())
}

/// Resolve a path (handles ~, ., ..) and return info.
/// Does not follow symlinks.
#[derive(Serialize)]
pub struct ResolvedPath {
    pub resolved: String,
    pub exists: bool,
    #[serde(rename = "isDir")]
    pub is_dir: bool,
}

#[tauri::command]
pub async fn fs_resolve_path(path: String) -> Result<ResolvedPath, String> {
    let resolved = if path.starts_with('~') {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| ".".to_string());
        std::path::PathBuf::from(home).join(&path[1..])
    } else if path.starts_with('/') {
        std::path::PathBuf::from(&path)
    } else {
        // Relative: resolve from current dir
        let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
        cwd.join(&path)
    };

    // Normalize (resolve . and ..)
    let normalized = if let Ok(canon) = std::fs::canonicalize(&resolved) {
        canon
    } else {
        // If path doesn't exist, do our best to normalize
        let mut components: Vec<&str> = Vec::new();
        for component in resolved.components() {
            match component {
                std::path::Component::Normal(c) => components.push(c.to_str().unwrap_or("")),
                std::path::Component::ParentDir => { components.pop(); }
                _ => {}
            }
        }
        let base = if path.starts_with('~') || path.starts_with('/') {
            std::path::PathBuf::from("/")
        } else {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        };
        base.join(components.join("/"))
    };

    let exists = normalized.exists();
    let is_dir = exists && normalized.is_dir();

    Ok(ResolvedPath {
        resolved: normalized.to_string_lossy().to_string(),
        exists,
        is_dir,
    })
}

/// Guess MIME type from file extension.
fn guess_mime(path: &std::path::Path) -> &str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" | "oga" => "audio/ogg",
        "flac" => "audio/flac",
        "m4a" => "audio/mp4",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "mkv" => "video/x-matroska",
        "pdf" => "application/pdf",
        "txt" | "md" => "text/plain",
        "json" => "application/json",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        "js" => "text/javascript",
        "ts" => "text/typescript",
        "rs" => "text/rust",
        "py" => "text/x-python",
        "go" => "text/x-go",
        "java" => "text/x-java",
        "c" => "text/x-c",
        "cpp" | "cc" | "cxx" => "text/x-c++",
        "h" | "hpp" => "text/x-header",
        "yaml" | "yml" => "text/yaml",
        "toml" => "text/toml",
        "xml" => "text/xml",
        _ => "application/octet-stream",
    }
}

/// Read a file and return it as a data URI string.
#[tauri::command]
pub async fn fs_read_file_data_uri(path: String) -> Result<String, String> {
    let p = std::path::Path::new(&path);
    let data = std::fs::read(p)
        .map_err(|e| format!("Cannot read file: {}", e))?;
    let mime = guess_mime(p);
    let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &data);
    Ok(format!("data:{};base64,{}", mime, b64))
}

// ─── Helpers ──────────────────────────────────────────────────────────

fn resolve_binary(binary_path: &str) -> String {
    if binary_path.is_empty() {
        alayacore::find_binary()
    } else {
        binary_path.to_string()
    }
}
