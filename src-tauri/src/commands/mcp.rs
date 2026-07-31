//! MCP OAuth flow Tauri commands.
//!
//! Handles the OAuth authorization flow for MCP servers:
//! starts a local callback server, fills the auth URL with redirect URI and state,
//! opens the browser (or copies URL), and processes the callback.

use crate::commands::SessionMap;
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
