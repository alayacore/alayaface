//! MCP OAuth flow Tauri commands.
//!
//! Handles the OAuth authorization flow for MCP servers:
//! starts a local callback server, fills the auth URL with redirect URI and state,
//! opens the browser (or copies URL), and processes the callback.
//!
//! Also manages the active preset's MCP server list in
//! `~/.alayaface/presets/<name>/mcp.conf` (key-value blocks separated by `---`),
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
    listener
        .set_nonblocking(true)
        .map_err(|e| format!("Failed to set callback server nonblocking: {e}"))?;
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

    // Accept callback in a background thread. The listener is
    // non-blocking with a timeout so an abandoned flow (user never
    // completes the browser dance) cannot leak the thread/socket.
    let sid = sid_owned;
    let sname = sname_owned;
    let ruri = redirect_uri.clone();
    std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(300);
        let stream = loop {
            match listener.accept() {
                Ok((stream, addr)) => {
                    log::info!("[mcp_auth] Callback received from {}", addr);
                    break stream;
                }
                Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    if std::time::Instant::now() > deadline {
                        log::warn!("[mcp_auth] Timed out waiting for callback, declining");
                        let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, None);
                        return;
                    }
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
                Err(e) => {
                    log::error!("[mcp_auth] Accept error: {}", e);
                    let _ = send_mcp_result(&sessions_arc, &sid, &sname, &ruri, None);
                    return;
                }
            }
        };
        let mut stream = stream;
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
        let http_body = auth_callback_page(&sname, params.contains_key("code"));
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
    });

    Ok(filled_url)
}

/// Send the OAuth result to the session as an mcp_confirm/mcp_decline
/// command. Runs on Tauri's async runtime (never creates its own).
fn send_mcp_result(
    sessions_arc: &std::sync::Arc<tokio::sync::Mutex<std::collections::HashMap<String, session::SessionHandle>>>,
    session_id: &str,
    server_name: &str,
    redirect_uri: &str,
    code: Option<&str>,
) -> Result<(), String> {
    tauri::async_runtime::handle().block_on(async {
        // `send_cmd` locks the map only for the lookup and releases it
        // before writing to stdin — the map lock must never be held
        // across a blocking pipe write (see session::refs).
        let sessions = crate::session::SessionMap(sessions_arc.clone());

        match code {
            Some(c) => {
                let input = format!("{} {} {}", server_name, c, redirect_uri);
                log::info!("[mcp_auth] Sending mcp_confirm: {}", input);
                crate::commands::send_cmd(&sessions, session_id, "mcp_confirm", &input).await?;
            }
            None => {
                log::info!("[mcp_auth] Auth failed/cancelled — sending mcp_decline {}", server_name);
                crate::commands::send_cmd(&sessions, session_id, "mcp_decline", server_name).await?;
            }
        }
        Ok(())
    })
}

/// HTML page shown in the browser after the OAuth callback completes.
/// Includes the server name so the user can tell which server the
/// authorization was for (multiple servers may be authorized in one init).
fn auth_callback_page(server_name: &str, success: bool) -> String {
    format!(
        "<!DOCTYPE html><html><body style='display:flex;justify-content:center;align-items:center;height:100vh;font-family:sans-serif;'>                    <div style='text-align:center;'><h2>Authorization {}</h2>                    <p style='color:#666;'>Server: {}</p>                    <p style='color:#666;'>You can close this window.</p></div></body></html>",
        if success { "Successful" } else { "Failed" },
        html_escape(server_name)
    )
}

/// Minimal HTML escaping for config values shown in the callback page.
fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

// ─── Default (global) MCP server list ────────────────────────────────
//
// The active preset's config (~/.alayaface/presets/<name>/mcp.conf) lists
// MCP servers in key-value block format. These commands read/replace that file
// directly; the FORMAT belongs to `App/McpConfig.elm`, so this layer only
// moves bytes. AlayaCore reads the file at session start, which is why an
// edit affects new sessions rather than a running one.

/// Return the preset's mcp.conf verbatim.
///
/// Text, not a parsed server list: the schema lives in `App/McpConfig.elm`,
/// and parsing it here would be a second implementation of the same keys —
/// the drift that produced the `&`/`<`/`>` corruption this move fixed.
#[tauri::command]
pub async fn list_default_mcp(preset: String) -> Result<serde_json::Value, String> {
    // Ensure first so the seed presets exist on first run (mirrors Go and the
    // model handlers).
    dirs::ensure()?;
    let config_dir = dirs::resolve_config_dir(&preset)?;
    let path = config_dir.join("mcp.conf");
    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(format!("Failed to read mcp.conf: {e}")),
    };
    Ok(serde_json::json!({ "text": text }))
}

/// Replace a preset's mcp.conf with `config`, the whole file produced by
/// `App.McpConfig.encode`.
///
/// Atomic, and 0600: the file can hold OAuth client secrets and tokens, and
/// `model.conf` already keeps that permission. Nothing is validated here on
/// purpose — the client owns the schema (its `draftProblems` refuses at Save),
/// and a bad block that reaches the file is reported by AlayaCore at session
/// start with its block number.
#[tauri::command]
pub async fn sync_default_mcp(config: String, preset: String) -> Result<(), String> {
    dirs::ensure()?;
    let config_dir = dirs::resolve_config_dir(&preset)?;
    let path = config_dir.join("mcp.conf");
    crate::dirs::write_file_atomic_mode(&path, &config, 0o600)
        .map_err(|e| format!("Failed to write mcp.conf: {e}"))?;
    log::info!("[mcp] Wrote {} bytes to mcp.conf", config.len());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_callback_page_shows_server_name() {
        let ok = auth_callback_page("github", true);
        assert!(ok.contains("Authorization Successful"));
        assert!(ok.contains("Server: github"));
        assert!(ok.contains("You can close this window"));

        let failed = auth_callback_page("gitlab", false);
        assert!(failed.contains("Authorization Failed"));
        assert!(failed.contains("Server: gitlab"));
    }

    #[test]
    fn auth_callback_page_escapes_server_name() {
        let body = auth_callback_page("a<b&c\"d", true);
        assert!(body.contains("Server: a&lt;b&amp;c&quot;d"));
        assert!(!body.contains("a<b&c"));
    }

    #[test]
    fn sync_writes_the_text_verbatim_and_list_reads_it_back() {
        crate::dirs::isolated_home(|| {
            crate::dirs::ensure().unwrap();
            // The bytes include the values the old Go/JSON quoting corrupted:
            // an ampersand, angle brackets, and a core escape.
            let text = "server: \"a&b<c>\"\nurl: \"https://h/mcp?a=1&b=2\"\nauth-scopes: [\"read\"]\n";

            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(sync_default_mcp(text.to_string(), "Simple".to_string()))
                .unwrap();

            let listed = rt.block_on(list_default_mcp("Simple".to_string())).unwrap();
            assert_eq!(listed["text"], text);

            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let path = crate::dirs::resolve_config_dir("Simple")
                    .unwrap()
                    .join("mcp.conf");
                let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
                assert_eq!(mode, 0o600, "mcp.conf can hold OAuth secrets");
            }
        });
    }

    #[test]
    fn list_missing_file_returns_an_empty_document() {
        crate::dirs::isolated_home(|| {
            crate::dirs::ensure().unwrap();
            let rt = tokio::runtime::Runtime::new().unwrap();
            let listed = rt.block_on(list_default_mcp("Simple".to_string())).unwrap();
            assert_eq!(listed["text"], "");
        });
    }
}
