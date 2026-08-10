//! Background readers for alayacore subprocess pipes.
//!
//! `spawn_stdout_reader` reads TLV frames from stdout and emits them as
//! Tauri events. (alayacore's stderr is inherited by the parent process
//! — see alayacore::spawn — so no stderr collector is needed.)

use crate::event::{DeltaEvent, FrameEvent, StatusEvent};
use crate::tlv;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};

/// User-role content tags that appear on stdout (echoes).
fn is_user_echo_tag(tag: &str) -> bool {
    matches!(tag, "UT" | "UI" | "UV" | "UA" | "UD")
}

/// Spawn a background thread that reads TLV frames from alayacore's stdout
/// and emits them as Tauri events (`tlv-delta`, `tlv-frame`, `core-status`).
pub fn spawn_stdout_reader(
    app: AppHandle,
    session_id: String,
    mut stdout: std::process::ChildStdout,
    connected: Arc<AtomicBool>,
    model_cache: Arc<crate::ModelCacheInner>,
    child: Arc<std::sync::Mutex<Option<std::process::Child>>>,
    pending_commands: Arc<crate::session::PendingCommands>,
) {
    std::thread::spawn(move || {
        let sid = session_id;

        let reap_child = || {
            if let Ok(mut guard) = child.lock() {
                if let Some(mut c) = guard.take() {
                    crate::alayacore::kill_child(&mut c);
                }
            }
        };

        loop {
            match tlv::read_frame(&mut stdout) {
                Ok(Some(frame)) => {
                    dispatch_frame(&app, &sid, &frame, &model_cache, &pending_commands);
                }
                Ok(None) => {
                    connected.store(false, Ordering::SeqCst);
                    reap_child();
                    let _ = app.emit("core-status", StatusEvent {
                        session_id: sid.clone(),
                        connected: false,
                        message: "Connection closed".to_string(),
                    });
                    break;
                }
                Err(e) => {
                    connected.store(false, Ordering::SeqCst);
                    reap_child();
                    let _ = app.emit("core-status", StatusEvent {
                        session_id: sid.clone(),
                        connected: false,
                        message: format!("Read error: {e}"),
                    });
                    break;
                }
            }
        }
    });
}

/// Dispatch a single TLV frame to the appropriate event channel(s).
fn dispatch_frame(
    app: &AppHandle,
    sid: &str,
    frame: &tlv::Frame,
    model_cache: &Arc<crate::ModelCacheInner>,
    pending_commands: &Arc<crate::session::PendingCommands>,
) {
    let tag = &frame.tag;
    let raw_value = &frame.value;

    // Log every incoming frame for debugging
    let preview: String = raw_value.chars().take(200).collect();
    log::info!("[tlv] << {} {} {}b {}", sid, tag, raw_value.len(), preview);

    // Cache model_list from SM frames (always, before any other processing)
    if tag == "SM" {
        if let Ok(env) = serde_json::from_str::<tlv::SystemMsgEnvelope>(raw_value) {
            if env.msg_type == "model_list" {
                if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                    model_cache.set(arr.clone());
                }
            }
        }
    }

    match tag.as_str() {
        // ─── Streaming deltas (At, Ar) ───────────────────────────
        "At" | "Ar" => handle_delta_frame(app, sid, tag, raw_value),
        // ─── Complete/authoritative (AT, AR) ──────────────────────
        // Delta mode: content is empty (terminator). Replay/--no-delta: full text.
        "AT" | "AR" => emit_frame(app, sid, tag, raw_value, None, None, true),
        // ─── JSON frames (Af, AF, UF, Uf) ────────────────────────
        // All share the same wire format: raw JSON or a NUL-delimited
        // history ID prefix followed by JSON. The parsed JSON (when
        // present) is forwarded so the frontend can decode it by tag.
        "Af" | "AF" | "UF" | "Uf" => handle_json_frame(app, sid, tag, raw_value),
        // ─── Command output (CO) ─────────────────────────────────
        "CO" => handle_cmd_output_frame(app, sid, raw_value, pending_commands),
        // ─── System message (SM) ─────────────────────────────────
        "SM" => handle_sm_frame(app, sid, raw_value),
        // ─── Everything else (user echoes, unknown) ─────────────
        _ => {
            let user_content_type = if is_user_echo_tag(tag) {
                Some(tag.clone())
            } else {
                None
            };
            emit_frame(app, sid, tag, raw_value, None, user_content_type, false);
        }
    }
}

/// Handle At/Ar streaming delta frames.
fn handle_delta_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    let parts = tlv::unwrap_delta(raw_value);
    if parts.has_delta {
        let _ = app.emit("tlv-delta", DeltaEvent {
            session_id: sid.to_string(),
            history_id: parts.history_id,
            content: parts.content,
            tag: tag.to_string(),
        });
        // Note: intentionally NOT emitting tlv-frame here.
        // At/Ar are pure delta events consumed by handleDeltaEvent.
        // Emitting tlv-frame would cause a second dispatch in the
        // frontend reducer (no-op in handleFrameEvent, but still a
        // new sessions array → unnecessary re-render).
    } else {
        // Malformed delta (no NUL prefix) — unlikely, but send raw
        emit_frame(app, sid, tag, raw_value, None, None, false);
    }
}

/// Handle AF/UF/Uf/Af JSON frames. See dispatch_frame for the shared
/// wire format; the parsed JSON (when present) is forwarded to the
/// frontend, which decodes it by tag.
fn handle_json_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    let parts = tlv::unwrap_delta(raw_value);
    let json = if parts.has_delta {
        serde_json::from_str::<serde_json::Value>(&parts.content).ok()
    } else {
        serde_json::from_str::<serde_json::Value>(raw_value).ok()
    };
    emit_frame(app, sid, tag, raw_value, json, None, false);
}

/// Handle CO command output frames.
///
/// CO carries only the call ID — the command name is resolved from the
/// pending-commands registry (populated when the CI was sent) and injected
/// into the JSON payload so the frontend can render the result without
/// tracking call IDs itself.
fn handle_cmd_output_frame(
    app: &AppHandle,
    sid: &str,
    raw_value: &str,
    pending_commands: &Arc<crate::session::PendingCommands>,
) {
    let mut json_val = serde_json::from_str::<serde_json::Value>(raw_value)
        .unwrap_or(serde_json::Value::Null);
    if let Some(obj) = json_val.as_object_mut() {
        let call_id = obj.get("id").and_then(|v| v.as_str()).unwrap_or("");
        if let Some(name) = pending_commands.blocking_remove(call_id) {
            obj.insert("name".to_string(), serde_json::Value::String(name));
        }
    }
    emit_frame(app, sid, "CO", raw_value, Some(json_val), None, false);
}

/// Handle SM system message frames.
fn handle_sm_frame(app: &AppHandle, sid: &str, raw_value: &str) {
    let json_val = serde_json::from_str::<tlv::SystemMsgEnvelope>(raw_value).ok().map(|env| {
        serde_json::json!({ "type": env.msg_type, "data": env.data })
    });
    emit_frame(app, sid, "SM", raw_value, json_val, None, false);
}

/// Build and emit a `tlv-frame` event from a raw frame value.
///
/// Unwraps the optional NUL-delimited history-ID prefix; `json` and
/// `user_content_type` are attached verbatim. `empty_to_none` maps an
/// empty payload to `content: None` (used by AT/AR terminators, where an
/// empty value means "deltas already carried the text").
fn emit_frame(
    app: &AppHandle,
    sid: &str,
    tag: &str,
    raw_value: &str,
    json: Option<serde_json::Value>,
    user_content_type: Option<String>,
    empty_to_none: bool,
) {
    let parts = tlv::unwrap_delta(raw_value);
    let content = if parts.has_delta {
        Some(parts.content)
    } else {
        Some(raw_value.to_string())
    };
    let content = if empty_to_none {
        content.filter(|c| !c.is_empty())
    } else {
        content
    };
    let _ = app.emit("tlv-frame", FrameEvent {
        session_id: sid.to_string(),
        tag: tag.to_string(),
        raw_value: raw_value.to_string(),
        history_id: if parts.has_delta { Some(parts.history_id) } else { None },
        content,
        json,
        user_content_type,
    });
}
