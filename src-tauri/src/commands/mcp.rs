//! MCP OAuth flow Tauri commands.
//!
//! Handles the OAuth authorization flow for MCP servers:
//! starts a local callback server, fills the auth URL with redirect URI and state,
//! opens the browser (or copies URL), and processes the callback.
//!
//! Also manages the default (global) MCP server list in
//! `~/.alayaface/config/mcp.conf` (key-value blocks separated by `---`),
//! mirroring the model editor pattern. No alayacore RPC exists for MCP
//! config, so the file is read/written directly.

use crate::commands::SessionMap;
use crate::dirs;
use crate::session;

use std::io::{BufRead, Write};
use tauri::State;

/// Start the MCP OAuth flow: launch callback server, fill URL, open browser.
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

        match code {
            Some(c) => {
                let input = format!("{} {} {}", server_name, c, redirect_uri);
                log::info!("[mcp_auth] Sending mcp_confirm: {}", input);
                crate::commands::send_cmd(&map, session_id, "mcp_confirm", &input).await?;
            }
            None => {
                log::info!("[mcp_auth] Auth failed/cancelled — sending mcp_decline {}", server_name);
                crate::commands::send_cmd(&map, session_id, "mcp_decline", server_name).await?;
            }
        }
        Ok(())
    })
}

// ─── Default (global) MCP server list ────────────────────────────────
//
// The global config at ~/.alayaface/config/mcp.conf lists MCP servers in
// key-value block format (blocks separated by `---`). These commands
// read/replace that file directly. Comments (`#`) and disabled blocks are
// dropped when the file is rewritten, mirroring the model editor behavior.

/// Split a `key: value` line. Skips blank lines and `#` comments.
fn split_kv_line(line: &str) -> Option<(String, String)> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with('#') {
        return None;
    }
    let idx = trimmed.find(':')?;
    Some((trimmed[..idx].trim().to_string(), trimmed[idx + 1..].trim().to_string()))
}

/// Strip surrounding double quotes (alayacore conf style).
fn unquote(s: &str) -> String {
    let t = s.trim();
    if t.len() >= 2 && t.starts_with('"') && t.ends_with('"') {
        t[1..t.len() - 1].to_string()
    } else {
        t.to_string()
    }
}

/// Map a conf key to its JSON key (dash → underscore).
fn json_key(conf_key: &str) -> String {
    match conf_key {
        "auth-type" => "auth_type".to_string(),
        "auth-token" => "auth_token".to_string(),
        "auth-client-id" => "auth_client_id".to_string(),
        "auth-client-secret" => "auth_client_secret".to_string(),
        "proto-version" => "proto_version".to_string(),
        other => other.to_string(),
    }
}

/// Parse mcp.conf text into a list of server objects.
/// `args`/`env` are normalized to raw JSON text strings so the frontend
/// always receives strings for these fields.
fn parse_mcp_conf(text: &str) -> Vec<serde_json::Value> {
    let mut servers: Vec<serde_json::Value> = Vec::new();
    let mut current: Vec<(String, String)> = Vec::new();

    let flush = |current: &mut Vec<(String, String)>, servers: &mut Vec<serde_json::Value>| {
        if current.is_empty() {
            return;
        }
        let mut obj = serde_json::Map::new();
        for (k, v) in current.drain(..) {
            let value = if k == "args" || k == "env" {
                // Raw JSON text (array/object). Normalize to compact text.
                match serde_json::from_str::<serde_json::Value>(&v) {
                    Ok(parsed) => serde_json::Value::String(serde_json::to_string(&parsed).unwrap_or(v)),
                    Err(_) => serde_json::Value::String(v),
                }
            } else {
                serde_json::Value::String(unquote(&v))
            };
            obj.insert(json_key(&k), value);
        }
        // Only keep blocks that declared a server name (drops comment-only blocks)
        if obj.contains_key("server") {
            // Infer the server kind from the config: URL → HTTP, else STDIO.
            // Not persisted back (alayacore infers it the same way).
            let is_http = obj
                .get("url")
                .and_then(|v| v.as_str())
                .map(|s| !s.trim().is_empty())
                .unwrap_or(false);
            obj.insert(
                "type".to_string(),
                serde_json::Value::String(if is_http { "http" } else { "stdio" }.to_string()),
            );
            servers.push(serde_json::Value::Object(obj));
        }
    };

    for line in text.lines() {
        if line.trim() == "---" {
            flush(&mut current, &mut servers);
        } else if let Some((k, v)) = split_kv_line(line) {
            current.push((k, v));
        }
    }
    flush(&mut current, &mut servers);
    servers
}

/// Ordered fields for serialization (matches alayacore's mcp.conf layout).
const MCP_CONF_ORDER: [&str; 10] = [
    "server", "url", "command", "args", "env",
    "auth-type", "auth-token", "auth-client-id", "auth-client-secret", "proto-version",
];

/// Serialize server objects back into mcp.conf block format.
fn write_mcp_conf(servers: &[serde_json::Value]) -> String {
    let mut out = String::new();
    for (i, s) in servers.iter().enumerate() {
        if i > 0 {
            out.push_str("---\n");
        }
        let Some(obj) = s.as_object() else { continue };
        for conf_key in MCP_CONF_ORDER.iter() {
            let Some(v) = obj.get(json_key(conf_key).as_str()) else { continue };
            let line = match v {
                serde_json::Value::String(sv) => {
                    if *conf_key == "args" || *conf_key == "env" {
                        // Already raw JSON text; write as-is (empty → skip)
                        if sv.trim().is_empty() {
                            continue;
                        }
                        format!("{}: {}", conf_key, sv)
                    } else {
                        if sv.is_empty() && *conf_key != "server" {
                            continue;
                        }
                        // Quote with JSON encoding to escape safely
                        let quoted = serde_json::to_string(sv).unwrap_or_else(|_| format!("\"{sv}\""));
                        format!("{}: {}", conf_key, quoted)
                    }
                }
                _ => format!("{}: {}", conf_key, serde_json::to_string(v).unwrap_or_default()),
            };
            out.push_str(&line);
            out.push('\n');
        }
    }
    out
}

/// List the default (global) MCP server list from ~/.alayaface/config/mcp.conf.
#[tauri::command]
pub async fn list_default_mcp() -> Result<Vec<serde_json::Value>, String> {
    let (config_dir, _) = dirs::ensure()?;
    let path = config_dir.join("mcp.conf");
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("Failed to read mcp.conf: {e}"))?;
    let servers = parse_mcp_conf(&text);
    log::info!("[mcp] Listed {} servers from mcp.conf", servers.len());
    Ok(servers)
}

/// Replace the default (global) MCP server list in ~/.alayaface/config/mcp.conf.
/// Validates server names (required, unique) and args/env JSON, then writes
/// atomically (temp file + rename).
#[tauri::command]
pub async fn sync_default_mcp(config: String) -> Result<(), String> {
    let servers: Vec<serde_json::Value> = serde_json::from_str(&config)
        .map_err(|e| format!("Invalid config JSON: {e}"))?;

    let mut names = std::collections::HashSet::new();
    for s in &servers {
        let obj = s.as_object().ok_or("Each MCP server must be an object")?;
        let name = obj.get("server").and_then(|v| v.as_str()).map(str::trim).unwrap_or("");
        if name.is_empty() {
            return Err("Every server needs a non-empty `server` name".to_string());
        }
        if !names.insert(name.to_string()) {
            return Err(format!("Duplicate server name: {name}"));
        }
        for key in ["args", "env"] {
            if let Some(v) = obj.get(key) {
                match v {
                    serde_json::Value::String(sv) => {
                        let parsed: serde_json::Value = serde_json::from_str(sv)
                            .map_err(|e| format!("Server {name}: {key} is not valid JSON: {e}"))?;
                        if key == "args" && !parsed.is_array() {
                            return Err(format!("Server {name}: args must be a JSON array"));
                        }
                        if key == "env" && !parsed.is_object() {
                            return Err(format!("Server {name}: env must be a JSON object"));
                        }
                    }
                    _ => {
                        if key == "args" && !v.is_array() {
                            return Err(format!("Server {name}: args must be a JSON array"));
                        }
                        if key == "env" && !v.is_object() {
                            return Err(format!("Server {name}: env must be a JSON object"));
                        }
                    }
                }
            }
        }
    }

    let text = write_mcp_conf(&servers);
    let (config_dir, _) = dirs::ensure()?;
    let path = config_dir.join("mcp.conf");
    let tmp = config_dir.join("mcp.conf.tmp");
    std::fs::write(&tmp, &text).map_err(|e| format!("Failed to write mcp.conf: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Failed to replace mcp.conf: {e}"))?;
    log::info!("[mcp] Wrote {} servers to mcp.conf", servers.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_skips_commented_blocks() {
        let sample = r#"#server: disabledOne
#url: http://localhost:1
---
server: exaWebSearch
url: https://mcp.exa.ai/mcp
proto-version: 2025-11-25
---
#server: disabledTwo
---
server: embedded
command: "embedded-debugger-mcp"
args: ["--allow-flash-erase", "serve"]
env: {"RUST_LOG": "info"}
auth-type: authorization_code
"#;
        let servers = parse_mcp_conf(sample);
        assert_eq!(servers.len(), 2);
        assert_eq!(servers[0].get("type").and_then(|v| v.as_str()), Some("http"));
        assert_eq!(servers[1].get("type").and_then(|v| v.as_str()), Some("stdio"));
        let embedded = &servers[1];
        assert_eq!(
            embedded.get("args").and_then(|v| v.as_str()),
            Some("[\"--allow-flash-erase\",\"serve\"]")
        );
        assert_eq!(
            embedded.get("env").and_then(|v| v.as_str()),
            Some("{\"RUST_LOG\":\"info\"}")
        );
    }

    #[test]
    fn write_roundtrips() {
        let sample = r#"server: exaWebSearch
url: https://mcp.exa.ai/mcp
proto-version: 2025-11-25
---
server: embedded
command: "embedded-debugger-mcp"
args: ["--allow-flash-erase", "serve"]
env: {"RUST_LOG": "info"}
"#;
        let servers = parse_mcp_conf(sample);
        let out = write_mcp_conf(&servers);
        let reparsed = parse_mcp_conf(&out);
        assert_eq!(reparsed, servers);
    }

    #[test]
    fn sync_validates() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        // Invalid args JSON must be rejected
        let bad = r#"[{"server":"x","args":"not json"}]"#;
        assert!(rt.block_on(sync_default_mcp(bad.to_string())).is_err());
        // Duplicate names must be rejected
        let dup = r#"[{"server":"x"},{"server":"x"}]"#;
        assert!(rt.block_on(sync_default_mcp(dup.to_string())).is_err());
    }
}
