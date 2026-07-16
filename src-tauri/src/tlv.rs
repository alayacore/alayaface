//! TLV protocol implementation for AlayaCore rawio mode.
//!
//! Wire format: [2-byte tag][4-byte big-endian length][N bytes of value]
//!
//! Tags (stdin → agent):
//!   UT   User text
//!   UI   User image (data:image/...;base64,... or URL)
//!   UV   User video
//!   UA   User audio
//!   UD   User document
//!   UE   User message end — flushes staged content
//!
//! Tags (stdout ← agent):
//!   At   Assistant text streaming delta (\x00<id>\x00<content>)
//!   Ar   Assistant reasoning streaming delta (\x00<id>\x00<content>)
//!   Af   Function/tool argument streaming delta (\x00<id>\x00<JSON delta>)
//!   AT   Assistant text complete/authoritative (\x00<id>\x00<content>; empty if deltas preceded it)
//!   AR   Assistant reasoning complete/authoritative (\x00<id>\x00<content>; empty if deltas preceded it)
//!   AF   Function/tool lifecycle (\x00<id>\x00<JSON>)
//!   UF   Function/tool result (\x00<id>\x00<JSON>)
//!   SM   System message (JSON: {"type":"...","data":{...}})
//!   UT   User text echo (\x00<id>\x00<content>)
//!   UI   User image echo (\x00<id>\x00<data URI or URL>)
//!   UV   User video echo (\x00<id>\x00<data URI or URL>)
//!   UA   User audio echo (\x00<id>\x00<data URI or URL>)
//!   UD   User document echo (\x00<id>\x00<data URI or URL>)

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

// ─── Input Tags (sent to AlayaCore stdin) ───────────────────────────

pub const TAG_USER_TEXT: &str = "UT";
pub const TAG_USER_IMAGE: &str = "UI";
pub const TAG_USER_VIDEO: &str = "UV";
pub const TAG_USER_AUDIO: &str = "UA";
pub const TAG_USER_DOC: &str = "UD";
pub const TAG_USER_END: &str = "UE";

// ─── Output Tags (received from AlayaCore stdout) ───────────────────

pub const TAG_ASSISTANT_TEXT: &str = "AT";
pub const TAG_ASSISTANT_REASONING: &str = "AR";
pub const TAG_ASSISTANT_TOOL: &str = "AF";
pub const TAG_USER_TOOL_RESULT: &str = "UF";
pub const TAG_SYSTEM_MSG: &str = "SM";

// ─── Delta/Streaming Tags (lowercase) ──────────────────────────────

pub const TAG_ASSISTANT_TEXT_DELTA: &str = "At";
pub const TAG_ASSISTANT_REASONING_DELTA: &str = "Ar";
pub const TAG_TOOL_ARG_DELTA: &str = "Af";

/// Encode a TLV frame into bytes.
/// Format: [2-byte tag][4-byte length (big-endian)][value bytes]
pub fn encode(tag: &str, value: &str) -> Vec<u8> {
    let data = value.as_bytes();
    let len = data.len() as u32;
    let mut buf = Vec::with_capacity(6 + len as usize);
    buf.extend_from_slice(tag.as_bytes()); // 2 bytes
    buf.extend_from_slice(&len.to_be_bytes()); // 4 bytes
    buf.extend_from_slice(data); // value bytes
    buf
}

/// A parsed TLV frame.
#[derive(Debug, Clone)]
pub struct Frame {
    pub tag: String,
    pub value: String,
}

/// Read a single TLV frame from a reader.
/// Returns None on EOF, Some(frame) on success, or an error.
pub fn read_frame<R: Read>(reader: &mut R) -> io::Result<Option<Frame>> {
    let mut header = [0u8; 6];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(e) => return Err(e),
    }

    let tag = std::str::from_utf8(&header[0..2])
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?
        .to_string();

    let len = u32::from_be_bytes([header[2], header[3], header[4], header[5]]) as usize;

    let mut value = vec![0u8; len];
    if len > 0 {
        reader.read_exact(&mut value)?;
    }

    let value_str = String::from_utf8(value)
        .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;

    Ok(Some(Frame { tag, value: value_str }))
}

/// Write a TLV frame to a writer.
pub fn write_frame<W: Write>(writer: &mut W, tag: &str, value: &str) -> io::Result<()> {
    let buf = encode(tag, value);
    writer.write_all(&buf)
}

// ─── Delta Message Handling ─────────────────────────────────────────
//
// At, Ar, Af use NUL-delimited history IDs:
//   \x00<history-id>\x00<content>
//
// Same history ID → continuation; Different → new content block.

/// Parse a NUL-delimited history ID prefix from a value.
/// Returns `(id, content, true)` on success, or `("", full_value, false)`.
pub fn unwrap_delta(value: &str) -> (String, String, bool) {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes[0] != 0u8 {
        return (String::new(), value.to_string(), false);
    }

    if let Some(end_idx) = bytes[1..].iter().position(|&b| b == 0u8) {
        let end_idx = end_idx + 1;
        let id = String::from_utf8_lossy(&bytes[1..end_idx]).to_string();
        if id.is_empty() {
            return (String::new(), value.to_string(), false);
        }
        let content = String::from_utf8_lossy(&bytes[end_idx + 1..]).to_string();
        (id, content, true)
    } else {
        (String::new(), value.to_string(), false)
    }
}

/// Wrap content with a NUL-delimited history ID prefix: \x00<id>\x00<content>
#[allow(dead_code)]
pub fn wrap_delta(id: &str, content: &str) -> String {
    format!("\x00{}\x00{}", id, content)
}

// ─── JSON Payload Types ──────────────────────────────────────────────

/// Tool input data (AF frame payload).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolInputData {
    pub id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub input: Option<serde_json::Value>,
    /// Present in Af (tool argument delta) frames.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delta: Option<String>,
}

/// Tool output data (UF frame payload).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolOutputData {
    pub id: String,
    pub output: serde_json::Value,
    #[serde(default, skip_serializing_if = "is_false")]
    pub is_error: bool,
}

fn is_false(b: &bool) -> bool {
    !b
}

/// System message envelope (SM frame payload).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SystemMsgEnvelope {
    #[serde(rename = "type")]
    pub msg_type: String,
    pub data: serde_json::Value,
}
