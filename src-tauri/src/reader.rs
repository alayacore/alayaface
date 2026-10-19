//! Background readers for alayacore subprocess pipes.
//!
//! `spawn_stdout_reader` reads frames from stdout and emits them as
//! Tauri events. (alayacore's stderr is drained by a pump in
//! `alayacore::spawn` into a `StderrTail`, which this reader quotes when the
//! pipe dies — see `disconnect_message`.)

use crate::event::{DeltaEvent, FrameEvent, StatusEvent};
use crate::wire;

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Emitter};

/// Compose the `core-status` message for a pipe that just died.
///
/// With nothing on stderr this returns the base text unchanged, so the common
/// case (a session closed on purpose) reads exactly as it always did. With a
/// tail, the LAST line is quoted: for a startup failure it is the whole reason
/// (`Error: failed to load session: session file version mismatch: got 14,
/// expected 15`), and `core-status.message` is a one-line UI field, so a stack
/// trace does not belong in it. Everything the core wrote is still in the
/// backend log (the pump forwards each line there), which is what the count
/// suffix points at.
///
/// Ported to Go as `disconnectMessage` in session/reader.go — the two must
/// produce the same string, because the client shows whichever it gets.
fn disconnect_message(base: &str, tail: &crate::alayacore::StderrTail) -> String {
    let lines = tail.lines();
    let Some(last) = lines.last() else {
        return base.to_string();
    };
    let clipped: String = last
        .chars()
        .take(crate::alayacore::STDERR_TAIL_MAX_CHARS)
        .collect();
    if lines.len() <= 1 {
        format!("{base}: {clipped}")
    } else {
        format!(
            "{base}: {clipped} (+{} more stderr lines in the backend log)",
            lines.len() - 1
        )
    }
}

/// Spawn a background thread that reads frames from alayacore's stdout
/// and emits them as Tauri events (`tlv-delta`, `tlv-frame`, `core-status`).
pub fn spawn_stdout_reader(
    app: AppHandle,
    session_id: String,
    stdout: std::process::ChildStdout,
    connected: Arc<AtomicBool>,
    model_cache: Arc<crate::ModelCacheInner>,
    child: Arc<std::sync::Mutex<Option<std::process::Child>>>,
    pending_commands: Arc<crate::session::PendingCommands>,
    stderr_tail: crate::alayacore::StderrTail,
) {
    std::thread::spawn(move || {
        let sid = session_id;
        // A frame is a line, so the reader must buffer: reading one frame must
        // not consume the next. One buffered reader for the whole stream.
        let mut stdout = std::io::BufReader::new(stdout);
        // One `core-status: false` per session. The terminal frame and the EOF
        // that follows it describe the same fact, and the client's plan runner
        // fails its node on each one it receives.
        let mut announced = false;

        let reap_child = || {
            if let Ok(mut guard) = child.lock() {
                if let Some(mut c) = guard.take() {
                    crate::alayacore::kill_child(&mut c);
                }
            }
        };

        loop {
            match wire::read_frame(&mut stdout) {
                Ok(Some(frame)) => {
                    if dispatch_frame(&app, &sid, &frame, &model_cache, &pending_commands)
                        && !announced
                    {
                        // The core's terminal frame: report the end from the
                        // frame rather than inferring it from EOF, which is
                        // what v12 added it for.
                        //
                        // Deliberately does NOT store `connected = false` or
                        // reap: this backend's `connected` means "the pipe is
                        // usable", and EOF is what decides that. Close waits on
                        // the child actually exiting (Rust `try_wait`, Go
                        // `Connected()`), and moving that earlier on one side
                        // only would be exactly the behavioral drift AGENTS.md
                        // warns about.
                        announced = true;
                        let _ = app.emit("core-status", StatusEvent {
                            session_id: sid.clone(),
                            connected: false,
                            message: SESSION_CLOSED_MESSAGE.to_string(),
                        });
                    }
                }
                Ok(None) => {
                    connected.store(false, Ordering::SeqCst);
                    reap_child();
                    if !announced {
                        let message = disconnect_message("Connection closed", &stderr_tail);
                        let _ = app.emit("core-status", StatusEvent {
                            session_id: sid.clone(),
                            connected: false,
                            message,
                        });
                    }
                    break;
                }
                Err(e) => {
                    connected.store(false, Ordering::SeqCst);
                    reap_child();
                    if !announced {
                        let message = disconnect_message(&format!("Read error: {e}"), &stderr_tail);
                        let _ = app.emit("core-status", StatusEvent {
                            session_id: sid.clone(),
                            connected: false,
                            message,
                        });
                    }
                    break;
                }
            }
        }
    });
}

/// Dispatch a single frame to the appropriate event channel(s).
///
/// Returns true when the frame ENDED the session (`ends_the_session`), which is
/// the reader's cue to announce the end. Every other frame returns false, and
/// the reader keeps going.
fn dispatch_frame(
    app: &AppHandle,
    sid: &str,
    frame: &wire::Frame,
    model_cache: &Arc<crate::ModelCacheInner>,
    pending_commands: &Arc<crate::session::PendingCommands>,
) -> bool {
    let tag = &frame.tag;
    let raw_value = &frame.value;

    // Log every incoming frame for debugging
    let preview: String = raw_value.chars().take(200).collect();
    log::info!("[wire] << {} {} {}b {}", sid, tag, raw_value.len(), preview);

    // Cache model_list from SM frames (always, before any other processing)
    if tag == "SM" {
        if let Ok(env) = serde_json::from_str::<wire::SystemMsgEnvelope>(raw_value) {
            if env.msg_type == "model_list" {
                if let Some(arr) = env.data.get("models").and_then(|v| v.as_array()) {
                    model_cache.set(arr.clone());
                }
            }
        }
    }

    match tag.as_str() {
        // ─── Assistant content delta (Ax) ─────────────────────────
        wire::TAG_ASSISTANT_X_DELTA => {
            handle_delta_frame(app, sid, tag, raw_value);
            false
        }
        // ─── Assistant content, complete/authoritative (AX) ───────
        // Delta mode: content is empty (terminator). Replay/--no-delta:
        // full text.
        wire::TAG_ASSISTANT_X => {
            handle_content_frame(app, sid, tag, raw_value);
            false
        }
        // ─── User content echo (UX) ───────────────────────────────
        wire::TAG_USER_X => {
            handle_content_frame(app, sid, tag, raw_value);
            false
        }
        // ─── JSON frames (Af, AF, UF, Uf) ────────────────────────
        // All share the same wire format: a JSON object (history id in
        // the top-level "id" when present, tool id in "call_id"). The
        // parsed JSON is forwarded so the frontend can decode it by tag.
        wire::TAG_ASSISTANT_F_DELTA
        | wire::TAG_ASSISTANT_F
        | wire::TAG_USER_F
        | wire::TAG_USER_F_DELTA => {
            handle_json_frame(app, sid, tag, raw_value);
            false
        }
        // ─── Command output (CO) ─────────────────────────────────
        wire::TAG_CMD_OUTPUT => {
            handle_cmd_output_frame(app, sid, raw_value, pending_commands);
            false
        }
        // ─── System message (SM) ─────────────────────────────────
        wire::TAG_SYSTEM_MSG => handle_sm_frame(app, sid, raw_value),
        // ─── Everything else (unknown) ───────────────────────────
        _ => {
            emit_frame(
                app,
                sid,
                tag,
                raw_value,
                json_of(raw_value),
                Some(raw_value.to_string()),
                None,
                None,
            );
            false
        }
    }
}

/// Parse `raw` as a JSON value, or None when it is not valid JSON.
fn json_of(raw: &str) -> Option<serde_json::Value> {
    serde_json::from_str::<serde_json::Value>(raw).ok()
}

/// Handle Ax streaming delta frames: a JSON content item whose `type` says
/// text or reasoning. Emitted as `tlv-delta` so the frontend accumulates by
/// (type, history id).
fn handle_delta_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    match serde_json::from_str::<wire::ContentData>(raw_value) {
        Ok(d) if !d.item.kind.is_empty() => {
            let _ = app.emit(
                "tlv-delta",
                DeltaEvent {
                    session_id: sid.to_string(),
                    history_id: d.meta.id,
                    content: d.item.text,
                    tag: tag.to_string(),
                    content_type: d.item.kind,
                },
            );
            // Note: intentionally NOT emitting tlv-frame here.
            // Ax is a pure delta event consumed by handleDeltaEvent.
            // Emitting tlv-frame would cause a second dispatch in the
            // frontend reducer (no-op in handleFrameEvent, but still a
            // new sessions array -> unnecessary re-render).
        }
        _ => {
            // Malformed delta -> forward the raw frame rather than dropping it.
            emit_frame(
                app,
                sid,
                tag,
                raw_value,
                json_of(raw_value),
                Some(raw_value.to_string()),
                None,
                None,
            );
        }
    }
}

/// Handle complete content frames (AX assistant, UX user echo). The content
/// is the `text` field for text/reasoning items and the `uri` for media; the
/// content type is the item's `type`.
fn handle_content_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    match serde_json::from_str::<wire::ContentData>(raw_value) {
        Ok(d) if !d.item.kind.is_empty() => {
            let content = if d.item.kind == "text" || d.item.kind == "reasoning" {
                d.item.text.clone()
            } else {
                d.item.uri.clone()
            };
            let history_id = if d.meta.id.is_empty() {
                None
            } else {
                Some(d.meta.id.clone())
            };
            emit_frame(
                app,
                sid,
                tag,
                raw_value,
                json_of(raw_value),
                Some(content),
                history_id,
                Some(d.item.kind.clone()),
            );
        }
        _ => {
            emit_frame(
                app,
                sid,
                tag,
                raw_value,
                json_of(raw_value),
                Some(raw_value.to_string()),
                None,
                None,
            );
        }
    }
}

/// Handle AF/UF/Uf/Af JSON frames. See dispatch_frame for the shared
/// wire format; the parsed JSON is forwarded to the frontend, which
/// decodes it by tag.
fn handle_json_frame(app: &AppHandle, sid: &str, tag: &str, raw_value: &str) {
    let json = json_of(raw_value);
    // The history id rides the top-level "id" on the authoritative frames.
    let history_id = json
        .as_ref()
        .and_then(|v| v.get("id"))
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());
    emit_frame(
        app,
        sid,
        tag,
        raw_value,
        json,
        Some(raw_value.to_string()),
        history_id,
        None,
    );
}

/// Handle CO command output frames.
///
/// CO carries only the command ID — the command name is resolved from the
/// pending-commands registry (populated when the CI was sent) and injected
/// into the JSON payload so the frontend can render the result without
/// tracking command IDs itself.
fn handle_cmd_output_frame(
    app: &AppHandle,
    sid: &str,
    raw_value: &str,
    pending_commands: &Arc<crate::session::PendingCommands>,
) {
    let mut json_val = serde_json::from_str::<serde_json::Value>(raw_value)
        .unwrap_or(serde_json::Value::Null);
    if let Some(obj) = json_val.as_object_mut() {
        let command_id = obj.get("command_id").and_then(|v| v.as_str()).unwrap_or("");
        if let Some(name) = pending_commands.blocking_remove(command_id) {
            obj.insert("name".to_string(), serde_json::Value::String(name));
        }
    }
    emit_frame(app, sid, "CO", raw_value, Some(json_val), Some(raw_value.to_string()), None, None);
}

/// The `core-status` message for a session the core ended itself.
///
/// Distinct from "Connection closed" on purpose: that one means the pipe went
/// away and the reason (if any) is on stderr, while this one means alayacore
/// said it was finished. The client shows whichever it gets, so both backends
/// use this exact text (scripts/check-backend-parity.sh compares them).
pub const SESSION_CLOSED_MESSAGE: &str = "Session closed by alayacore";

/// True for the core's terminal frame, `SM {"type":"session","data":{"state":
/// "closed"}}` — sent exactly once, after every other frame, with nothing
/// following it on stdout (adapter-guide, "Session lifecycle signal").
///
/// v12 of the protocol added it precisely so a client does not have to INFER
/// the end from EOF. That inference is not free here: stdout stays open while
/// anything still holds the write end, so a core that has finished can leave
/// the reader waiting on a pipe and the window showing a running session.
fn ends_the_session(msg_type: &str, data: &serde_json::Value) -> bool {
    msg_type == "session" && data.get("state").and_then(|v| v.as_str()) == Some("closed")
}

/// Handle SM system message frames.
///
/// Returns true for the terminal frame (see [`ends_the_session`]) so the reader
/// can end the loop; every other SM returns false.
fn handle_sm_frame(app: &AppHandle, sid: &str, raw_value: &str) -> bool {
    let (json_val, ended) = match serde_json::from_str::<wire::SystemMsgEnvelope>(raw_value) {
        Ok(env) => (
            serde_json::json!({ "type": env.msg_type, "data": env.data }),
            ends_the_session(&env.msg_type, &env.data),
        ),
        Err(_) => (serde_json::Value::Null, false),
    };
    emit_frame(
        app,
        sid,
        "SM",
        raw_value,
        (!json_val.is_null()).then_some(json_val),
        Some(raw_value.to_string()),
        None,
        None,
    );
    ended
}

/// Build and emit a `tlv-frame` event. `json`, `content`, `history_id` and
/// `content_type` are attached verbatim (each optional).
#[allow(clippy::too_many_arguments)]
fn emit_frame(
    app: &AppHandle,
    sid: &str,
    tag: &str,
    raw_value: &str,
    json: Option<serde_json::Value>,
    content: Option<String>,
    history_id: Option<String>,
    content_type: Option<String>,
) {
    let _ = app.emit(
        "tlv-frame",
        FrameEvent {
            session_id: sid.to_string(),
            tag: tag.to_string(),
            raw_value: raw_value.to_string(),
            history_id,
            content,
            json,
            content_type,
        },
    );
}

#[cfg(test)]
mod tests {
    use super::{disconnect_message, ends_the_session};
    use crate::alayacore::{StderrTail, STDERR_TAIL_MAX_CHARS};
    use serde_json::json;

    // ─── the terminal frame ───────────────────────────────────
    //
    // Protocol v12's `session` states, and the one that matters: only
    // `closed` ends the session, so a predicate that got this wrong either
    // drops the end (a ready frame) or kills the session mid-boot (a startup
    // state, or another type carrying the same word).

    #[test]
    fn only_the_closed_session_state_ends_it() {
        let cases: &[(&str, serde_json::Value, bool)] = &[
            ("session", json!({"state": "closed"}), true),
            ("session", json!({"state": "ready"}), false),
            ("session", json!({"state": "initializing"}), false),
            ("session", json!({"state": "starting"}), false),
            ("session", json!({}), false),
            ("session", json!(null), false),
            // The state travels in a `session` envelope; the same word in
            // another one is content, not a lifecycle signal.
            ("error", json!({"state": "closed"}), false),
            ("mcp", json!({"status": "closed"}), false),
        ];
        for (msg_type, data, want) in cases {
            let got = ends_the_session(msg_type, data);
            assert_eq!(got, *want, "type={msg_type} data={data} → {got}, want {want}");
        }
    }

    fn tail_with(lines: &[&str]) -> StderrTail {
        let tail = StderrTail::default();
        for line in lines {
            tail.push(line);
        }
        tail
    }

    #[test]
    fn a_clean_death_keeps_the_message_it_always_had() {
        // The ordinary case: a session closed on purpose, nothing on stderr.
        // This must stay byte-identical to the pre-StderrTail text — the plan
        // runner quotes it in a node failure reason.
        assert_eq!(
            disconnect_message("Connection closed", &tail_with(&[])),
            "Connection closed"
        );
    }

    #[test]
    fn the_last_stderr_line_is_quoted() {
        // The real startup failure this exists for, verbatim from a v12 core
        // handed a v11 session file.
        let tail = tail_with(&[
            "Warning: something earlier",
            "Error: failed to load session: session file version mismatch: got 14, expected 15",
        ]);
        let msg = disconnect_message("Connection closed", &tail);
        assert!(
            msg.contains("session file version mismatch: got 14, expected 15"),
            "the reason must reach the user: {msg}"
        );
        assert!(
            !msg.contains("something earlier"),
            "only the last line goes in the one-line status: {msg}"
        );
        assert!(
            msg.contains("(+1 more stderr lines in the backend log)"),
            "the user must be told where the rest is: {msg}"
        );
    }

    #[test]
    fn one_line_is_quoted_without_the_counter() {
        let msg = disconnect_message("Connection closed", &tail_with(&["boom"]));
        assert_eq!(msg, "Connection closed: boom");
    }

    #[test]
    fn a_long_line_is_clipped_without_splitting_a_character() {        // The core prints paths, which can carry non-ASCII; a byte slice here
        // would panic on the read path that reports a dead session.
        let long = "é".repeat(STDERR_TAIL_MAX_CHARS + 200);
        let msg = disconnect_message("Connection closed", &tail_with(&[&long]));
        assert_eq!(
            msg.chars()
                .count()
                .cmp(&("Connection closed: ".chars().count() + STDERR_TAIL_MAX_CHARS)),
            std::cmp::Ordering::Equal,
            "clipping is counted in characters: {msg}"
        );
    }
}
