//! Session I/O Tauri commands.
//!
//! Commands for sending prompts to sessions.

use crate::commands::{write_frames_to, MediaItem};
use crate::session::{self, SessionMap};
use crate::wire;

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
    // v14: each user content item is a UX frame whose value is a JSON content
    // item — {"type":"image","uri":...} etc. The concrete kind lives in
    // "type", not in the tag.
    let mut frames: Vec<(String, String)> = Vec::with_capacity(media.len() + 2);
    for item in &media {
        let kind = match item.media_type.as_str() {
            "image" => "image",
            "audio" => "audio",
            "video" => "video",
            "document" => "document",
            _ => return Err(format!("Unknown media type: {}", item.media_type)),
        };
        let body = serde_json::to_string(&wire::ContentData {
            meta: wire::ContentMeta::default(),
            item: wire::ContentItem {
                kind: kind.to_string(),
                uri: item.uri.clone(),
                ..Default::default()
            },
        })
        .map_err(|e| e.to_string())?;
        frames.push((wire::TAG_USER_X.to_string(), body));
    }
    if !text.is_empty() {
        let body = serde_json::to_string(&wire::ContentData {
            meta: wire::ContentMeta::default(),
            item: wire::ContentItem {
                kind: "text".to_string(),
                text: text.clone(),
                ..Default::default()
            },
        })
        .map_err(|e| e.to_string())?;
        frames.push((wire::TAG_USER_X.to_string(), body));
    }
    frames.push((wire::TAG_USER_END.to_string(), String::new()));

    let refs = session::refs(sessions.inner(), &session_id).await?;
    write_frames_to(&refs, &session_id, &frames).await
}
