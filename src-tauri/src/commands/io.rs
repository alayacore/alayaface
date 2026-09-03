//! Session I/O Tauri commands.
//!
//! Commands for sending prompts to sessions.

use crate::commands::{write_frames_to, MediaItem};
use crate::session::{self, SessionMap};
use crate::tlv;

use tauri::State;

#[tauri::command]
pub async fn alayacore_send_prompt(
    session_id: String,
    text: String,
    media: Vec<MediaItem>,
    sessions: State<'_, SessionMap>,
) -> Result<(), String> {
    // Build the whole message (media + text + UE flush) first, then write
    // it under ONE stdin lock — and crucially WITHOUT holding the
    // SessionMap lock. A prompt carries media data URIs (megabytes) on a
    // ~64 KiB OS pipe: if this one alayacore stops draining stdin, the
    // write blocks, and holding the global map lock across it used to
    // freeze every other session's commands (Go's SendPrompt only ever
    // takes the per-session stdin lock).
    let mut frames: Vec<(String, String)> = Vec::with_capacity(media.len() + 2);
    for item in &media {
        let tag = match item.media_type.as_str() {
            "image" => tlv::TAG_USER_IMAGE,
            "audio" => tlv::TAG_USER_AUDIO,
            "video" => tlv::TAG_USER_VIDEO,
            "document" => tlv::TAG_USER_DOC,
            _ => return Err(format!("Unknown media type: {}", item.media_type)),
        };
        frames.push((tag.to_string(), item.uri.clone()));
    }
    if !text.is_empty() {
        frames.push((tlv::TAG_USER_TEXT.to_string(), text));
    }
    frames.push((tlv::TAG_USER_END.to_string(), String::new()));

    let refs = session::refs(sessions.inner(), &session_id).await?;
    write_frames_to(&refs, &session_id, &frames).await
}
