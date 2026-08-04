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
//!   CI   Command input (JSON CmdMsg: {"id":"...","name":"...","input":"..."})
//!
//! Tags (stdout ← agent):
//!   At   Assistant text streaming delta (\x00<id>\x00<content>)
//!   Ar   Assistant reasoning streaming delta (\x00<id>\x00<content>)
//!   Af   Function/tool argument streaming delta (\x00<id>\x00<JSON delta>)
//!   Uf   Function/tool result preview snapshot, ephemeral/display-only
//!        (\x00<id>\x00<JSON {"id","text"}>; never authoritative — UF overwrites)
//!   AT   Assistant text complete/authoritative (\x00<id>\x00<content>; empty if deltas preceded it)
//!   AR   Assistant reasoning complete/authoritative (\x00<id>\x00<content>; empty if deltas preceded it)
//!   AF   Function/tool lifecycle (\x00<id>\x00<JSON>)
//!   UF   Function/tool result (\x00<id>\x00<JSON>)
//!   CO   Command output (JSON CmdResultMsg: {"id":"...","output":...,"is_error":...})
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
pub const TAG_CMD_INPUT: &str = "CI";

// ─── Output Tags (received from AlayaCore stdout) ───────────────────

pub const TAG_ASSISTANT_TEXT: &str = "AT";
pub const TAG_ASSISTANT_REASONING: &str = "AR";
pub const TAG_ASSISTANT_TOOL: &str = "AF";
pub const TAG_USER_TOOL_RESULT: &str = "UF";
pub const TAG_SYSTEM_MSG: &str = "SM";
pub const TAG_CMD_OUTPUT: &str = "CO";

// ─── Delta/Streaming Tags (lowercase) ──────────────────────────────

pub const TAG_ASSISTANT_TEXT_DELTA: &str = "At";
pub const TAG_ASSISTANT_REASONING_DELTA: &str = "Ar";
pub const TAG_TOOL_ARG_DELTA: &str = "Af";
/// Ephemeral tool result preview snapshot (display-only; never
/// authoritative — the complete result always arrives via UF).
pub const TAG_USER_F_DELTA: &str = "Uf";

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

/// Result of parsing a NUL-delimited delta frame value.
#[derive(Debug, Clone)]
pub struct DeltaParts {
    /// The history ID extracted from the NUL prefix, or empty if none.
    pub history_id: String,
    /// The content after the NUL-delimited history ID prefix, or the full value.
    pub content: String,
    /// Whether a valid NUL-delimited history ID prefix was found.
    pub has_delta: bool,
}

/// Parse a NUL-delimited history ID prefix from a value.
/// Returns `DeltaParts` with `has_delta = true` on success.
pub fn unwrap_delta(value: &str) -> DeltaParts {
    let bytes = value.as_bytes();
    if bytes.is_empty() || bytes[0] != 0u8 {
        return DeltaParts {
            history_id: String::new(),
            content: value.to_string(),
            has_delta: false,
        };
    }

    if let Some(end_idx) = bytes[1..].iter().position(|&b| b == 0u8) {
        let end_idx = end_idx + 1;
        let id = String::from_utf8_lossy(&bytes[1..end_idx]).to_string();
        if id.is_empty() {
            return DeltaParts {
                history_id: String::new(),
                content: value.to_string(),
                has_delta: false,
            };
        }
        let content = String::from_utf8_lossy(&bytes[end_idx + 1..]).to_string();
        DeltaParts {
            history_id: id,
            content,
            has_delta: true,
        }
    } else {
        DeltaParts {
            history_id: String::new(),
            content: value.to_string(),
            has_delta: false,
        }
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

/// Command input (CI frame payload) — adapter → agent.
/// `id` is generated by the adapter and echoed back in the matching CO.
/// `input` is an opaque argument string whose syntax is defined per command.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CmdMsg {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub input: String,
}

/// Command output (CO frame payload) — agent → adapter.
/// Mirrors ToolOutputData (UF): on success `output` is the command's
/// structured result (may be null); on failure it is a uniform error
/// object `{"code":...,"message":...}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CmdResultMsg {
    pub id: String,
    pub output: serde_json::Value,
    #[serde(default, skip_serializing_if = "is_false")]
    pub is_error: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_read_roundtrip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, "UT", "hello \u{0000} world").unwrap();

        let mut reader = buf.as_slice();
        let frame = read_frame(&mut reader).unwrap().unwrap();
        assert_eq!(frame.tag, "UT");
        assert_eq!(frame.value, "hello \u{0000} world");
        // Whole buffer consumed.
        assert!(read_frame(&mut reader).unwrap().is_none());
    }

    #[test]
    fn encode_uses_big_endian_length() {
        let value = "x".repeat(300);
        let buf = encode("UT", &value);
        // [tag 2][len 4][value]
        assert_eq!(&buf[0..2], b"UT");
        assert_eq!(u32::from_be_bytes([buf[2], buf[3], buf[4], buf[5]]), 300);
        assert_eq!(&buf[6..], value.as_bytes());
    }

    #[test]
    fn read_frame_eof_returns_none() {
        let mut reader: &[u8] = &[];
        assert!(read_frame(&mut reader).unwrap().is_none());
    }

    #[test]
    fn unwrap_delta_without_nul_prefix() {
        let parts = unwrap_delta("plain");
        assert!(!parts.has_delta);
        assert_eq!(parts.history_id, "");
        assert_eq!(parts.content, "plain");
    }

    #[test]
    fn unwrap_delta_empty_value() {
        let parts = unwrap_delta("");
        assert!(!parts.has_delta);
        assert_eq!(parts.content, "");
    }

    #[test]
    fn unwrap_delta_with_empty_id() {
        let parts = unwrap_delta("\u{0000}\u{0000}content");
        assert!(!parts.has_delta);
    }

    #[test]
    fn unwrap_delta_valid() {
        let parts = unwrap_delta("\u{0000}abc-123\u{0000}{\"id\":\"t1\"}");
        assert!(parts.has_delta);
        assert_eq!(parts.history_id, "abc-123");
        assert_eq!(parts.content, "{\"id\":\"t1\"}");
    }

    #[test]
    fn unwrap_delta_keeps_embedded_nuls_in_content() {
        // Content after the history ID may itself contain NULs (raw values).
        let parts = unwrap_delta("\u{0000}id\u{0000}a\u{0000}b");
        assert!(parts.has_delta);
        assert_eq!(parts.history_id, "id");
        assert_eq!(parts.content, "a\u{0000}b");
    }

    #[test]
    fn wrap_delta_roundtrips() {
        let wrapped = wrap_delta("h1", "payload");
        let parts = unwrap_delta(&wrapped);
        assert!(parts.has_delta);
        assert_eq!(parts.history_id, "h1");
        assert_eq!(parts.content, "payload");
    }

    #[test]
    fn json_payloads_roundtrip() {
        let output = ToolOutputData {
            id: "t5".into(),
            output: serde_json::json!([{"type": "text", "text": "ok"}]),
            is_error: false,
        };
        let s = serde_json::to_string(&output).unwrap();
        let back: ToolOutputData = serde_json::from_str(&s).unwrap();
        assert_eq!(back.id, "t5");
        assert!(!back.is_error);
        assert_eq!(back.output[0]["text"], "ok");

        let cmd = CmdMsg { id: "c1".into(), name: "save".into(), input: "/tmp/x".into() };
        let s = serde_json::to_string(&cmd).unwrap();
        let back: CmdMsg = serde_json::from_str(&s).unwrap();
        assert_eq!(back.name, "save");
        assert_eq!(back.input, "/tmp/x");
    }
}
