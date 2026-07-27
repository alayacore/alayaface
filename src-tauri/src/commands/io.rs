//! Session I/O Tauri commands.
//!
//! Commands for sending messages, prompts, and raw frames to sessions.

use crate::commands::{send_raw, MediaItem};
use crate::session::{self, SessionMap};
use crate::tlv;

use std::io::Write;
use tauri::State;

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
