//! Event payloads emitted to the frontend via Tauri events.
//!
//! These structs are serialized and sent to the React frontend
//! over Tauri's event system. Every event includes `session_id`.

use serde::Serialize;

/// Emitted when a streaming delta frame (At, Ar) arrives.
#[derive(Debug, Clone, Serialize)]
pub struct DeltaEvent {
    pub session_id: String,
    pub history_id: String,
    pub content: String,
    pub tag: String,
}

/// Emitted when any complete TLV frame arrives from alayacore stdout.
#[derive(Debug, Clone, Serialize)]
pub struct FrameEvent {
    pub session_id: String,
    pub tag: String,
    pub raw_value: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub history_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub json: Option<serde_json::Value>,
    /// Set for user-role echo frames (UT/UI/UV/UA/UD on stdout)
    /// so the frontend can distinguish direction and content type.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_content_type: Option<String>,
}

/// Emitted when the connection status of a session changes.
#[derive(Debug, Clone, Serialize)]
pub struct StatusEvent {
    pub session_id: String,
    pub connected: bool,
    pub message: String,
}
