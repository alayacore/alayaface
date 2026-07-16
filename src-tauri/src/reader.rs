//! Background readers for alayacore subprocess pipes.
//!
//! `spawn_stdout_reader` reads TLV frames from stdout and emits them as
//! Tauri events. `spawn_stderr_collector` captures stderr into a log.

use crate::event::{DeltaEvent, FrameEvent, StatusEvent};
use crate::tlv;

use std::io::BufRead;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};
use tokio::sync::Mutex;

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
    model_cache: Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
    child: Arc<std::sync::Mutex<Option<std::process::Child>>>,
) {
    std::thread::spawn(move || {
        let sid = session_id;

        let reap_child = || {
            if let Ok(mut guard) = child.lock() {
                if let Some(mut c) = guard.take() {
                    let _ = c.stdin.take();
                    let _ = c.kill();
                    let _ = c.wait();
                }
            }
        };

        loop {
            match tlv::read_frame(&mut stdout) {
                Ok(Some(frame)) => {
                    dispatch_frame(&app, &sid, &frame, &model_cache);
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
    model_cache: &Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
) {
    let tag = &frame.tag;
    let raw_value = &frame.value;

    // Cache model_list from SM frames (always, before any other processing)
    if tag == "SM" {
        if let Ok(env) = serde_json::from_str::<tlv::SystemMsgEnvelope>(raw_value) {
            if env.msg_type == "model_list" {
                if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                    let mut cache = model_cache.lock().unwrap();
                    *cache = arr.clone();
                }
            }
        }
    }

    match tag.as_str() {
        // ─── Streaming deltas (At, Ar) ───────────────────────────
        "At" | "Ar" => handle_delta_frame(app, sid, tag, raw_value),
        // ─── Complete/authoritative (AT, AR) ──────────────────────
        "AT" | "AR" => handle_complete_frame(app, sid, tag, raw_value),
        // ─── Tool argument delta (Af) ────────────────────────────
        "Af" => handle_tool_delta_frame(app, sid, raw_value),
        // ─── JSON frames (AF, UF, SM) ────────────────────────────
        "AF" | "UF" => handle_json_frame(app, sid, tag, raw_value),
        "SM" => handle_sm_frame(app, sid, raw_value),
        // ─── Everything else (user echoes, unknown) ─────────────
        _ => handle_other_frame(app, sid, tag, raw_value),
    }
}

/// Handle At/Ar streaming delta frames.
fn handle_delta_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    let (history_id, content, has_delta) = tlv::unwrap_delta(raw_value);
    if has_delta {
        let _ = app.emit("tlv-delta", DeltaEvent {
            session_id: sid.to_string(),
            history_id,
            content,
            tag: tag.to_string(),
        });
        // Note: intentionally NOT emitting tlv-frame here.
        // At/Ar are pure delta events consumed by handleDeltaEvent.
        // Emitting tlv-frame would cause a second dispatch in the
        // frontend reducer (no-op in handleFrameEvent, but still a
        // new sessions array → unnecessary re-render).
    } else {
        // Malformed delta (no NUL prefix) — unlikely, but send raw
        let _ = app.emit("tlv-frame", FrameEvent {
            session_id: sid.to_string(),
            tag: tag.to_string(),
            raw_value: raw_value.to_string(),
            history_id: None,
            content: Some(raw_value.to_string()),
            json: None,
            user_content_type: None,
        });
    }
}

/// Handle AT/AR complete/authoritative frames.
/// Delta mode: content is empty (terminator). Replay/--no-delta: full text.
fn handle_complete_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    let (history_id, content, has_delta) = tlv::unwrap_delta(raw_value);
    let hid = if has_delta { Some(history_id) } else { None };
    let ct = content;

    let _ = app.emit("tlv-frame", FrameEvent {
        session_id: sid.to_string(),
        tag: tag.to_string(),
        raw_value: raw_value.to_string(),
        history_id: hid,
        content: if ct.is_empty() { None } else { Some(ct) },
        json: None,
        user_content_type: None,
    });
}

/// Handle Af tool argument delta frames.
fn handle_tool_delta_frame(app: &AppHandle, sid: &str, raw_value: &str) {
    let (sid_val, raw_content, has_delta) = tlv::unwrap_delta(raw_value);
    let mut json_val = None;
    let history_id = if has_delta {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&raw_content) {
            json_val = Some(v);
        }
        Some(sid_val)
    } else {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(raw_value) {
            json_val = Some(v);
        }
        None
    };
    let _ = app.emit("tlv-frame", FrameEvent {
        session_id: sid.to_string(),
        tag: "Af".to_string(),
        raw_value: raw_value.to_string(),
        history_id,
        content: Some(raw_content),
        json: json_val,
        user_content_type: None,
    });
}

/// Handle AF/UF JSON frames.
fn handle_json_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    let (sid_val, raw_content, has_delta) = tlv::unwrap_delta(raw_value);
    let (history_id, content, json_val) = if has_delta {
        let json = serde_json::from_str::<serde_json::Value>(&raw_content).ok();
        (Some(sid_val), Some(raw_content), json)
    } else {
        let json = serde_json::from_str::<serde_json::Value>(raw_value).ok();
        (None, Some(raw_value.to_string()), json)
    };
    let _ = app.emit("tlv-frame", FrameEvent {
        session_id: sid.to_string(),
        tag: tag.to_string(),
        raw_value: raw_value.to_string(),
        history_id,
        content,
        json: json_val,
        user_content_type: None,
    });
}

/// Handle SM system message frames.
fn handle_sm_frame(app: &AppHandle, sid: &str, raw_value: &str) {
    let json_val = serde_json::from_str::<tlv::SystemMsgEnvelope>(raw_value).ok().map(|env| {
        serde_json::json!({ "type": env.msg_type, "data": env.data })
    });
    let _ = app.emit("tlv-frame", FrameEvent {
        session_id: sid.to_string(),
        tag: "SM".to_string(),
        raw_value: raw_value.to_string(),
        history_id: None,
        content: Some(raw_value.to_string()),
        json: json_val,
        user_content_type: None,
    });
}

/// Handle all other frames (user echoes, unknown tags).
fn handle_other_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    let (sid_val, raw_content, has_delta) = tlv::unwrap_delta(raw_value);
    let (history_id, content) = if has_delta {
        (Some(sid_val), Some(raw_content))
    } else {
        (None, Some(raw_value.to_string()))
    };
    let user_content_type = if is_user_echo_tag(tag) {
        Some(tag.to_string())
    } else {
        None
    };
    let _ = app.emit("tlv-frame", FrameEvent {
        session_id: sid.to_string(),
        tag: tag.to_string(),
        raw_value: raw_value.to_string(),
        history_id,
        content,
        json: None,
        user_content_type,
    });
}

/// Spawn a background thread that collects stderr lines into a log.
pub fn spawn_stderr_collector(
    stderr: std::process::ChildStderr,
    log: Arc<Mutex<Vec<String>>>,
) {
    std::thread::spawn(move || {
        let reader = std::io::BufReader::new(stderr);
        for line in reader.lines() {
            match line {
                Ok(l) => {
                    let mut guard = log.blocking_lock();
                    guard.push(l);
                }
                Err(_) => break,
            }
        }
    });
}
