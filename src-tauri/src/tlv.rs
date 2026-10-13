//! TLV protocol implementation for AlayaCore rawio mode.
//!
//! Wire format: [2-byte tag][4-byte big-endian length][N bytes of value]
//!
//! Protocol v14: every frame's value is either a zero-length control payload
//! (UE, CE) or a JSON object. The tag names the frame's PLANE, not the
//! concrete content kind — the kind travels inside the JSON as a content
//! item's "type". The vocabulary is a 2x2 over {into the model (U), out of
//! the model (A)} x {content (X), function (F)}:
//!
//!   UX  ↔   User content — JSON content item (both directions: input + echo)
//!   AX  ←   Assistant content — JSON content item, complete/authoritative
//!   AF  ←   Assistant function/tool call (JSON: call_id, name, input)
//!   UF  ←   User function/tool result (JSON: call_id, output, is_error)
//!   UE  →   User message end — flushes staged content as one message
//!   CI  →   Command input (JSON CmdMsg: {"call_id":...,"name":...,"input":...})
//!   CE  →   Control-plane input end — no more PROMPTS; the stream stays
//!           open, so commands may still follow (v12; see TAG_INPUT_END)
//!   CO  ←   Command output (JSON CmdResultMsg: {"call_id":...,"output":...})
//!   SM  ←   System message (JSON: {"type":"...","data":{...}})
//!
//! Lowercase tags carry streaming delta / incremental content:
//!   Ax  ←   Assistant content delta (type inside the JSON: text or reasoning)
//!   Af  ←   Assistant function/tool call delta (partial JSON argument)
//!   Uf  ←   Tool result preview snapshot (ephemeral, display-only; UF
//!           overwrites)
//!
//! History id: output content/function frames carry it as the JSON top-level
//! "id" (an ordinary field — no NUL-delimited prefix any more), and
//! authoritative frames also carry "time" (RFC3339). Input frames carry
//! neither. The tool-call id is "call_id", so "id" means history id everywhere.

use serde::{Deserialize, Serialize};
use std::io::{self, Read, Write};

// ─── Input Tags (sent to AlayaCore stdin) ───────────────────────────

/// User content: a JSON content item (type + text/uri/…). Used in BOTH
/// directions — new user content on stdin, and the agent's echo on stdout.
pub const TAG_USER_X: &str = "UX";
pub const TAG_USER_END: &str = "UE";
pub const TAG_CMD_INPUT: &str = "CI";
/// Control-plane input end (protocol v12): "no more prompts, but this stream
/// stays open", so commands can still follow — TCP's FIN rather than a torn
/// down connection. alayacore treats it exactly like EOF on stdin.
///
/// This backend never SENDS it, and that is a decision rather than an
/// omission: AlayaFace has no end of prompts to declare (a window that stops
/// prompting may prompt again), and `close_session` wants the opposite — the
/// process gone — so it closes stdin outright, which ends the command path too
/// and is the point there. It is carried because the tag alphabet is a fact
/// about the wire: `scripts/check-backend-parity.sh` compares the two backends'
/// tag lists, so a tag that exists in the protocol exists here, and a future
/// half-close (or a core that sends one to us) is not a surprise to whoever
/// reads this file.
pub const TAG_INPUT_END: &str = "CE";

// ─── Output Tags (received from AlayaCore stdout) ───────────────────

pub const TAG_ASSISTANT_X: &str = "AX";
pub const TAG_ASSISTANT_F: &str = "AF";
pub const TAG_USER_F: &str = "UF";
pub const TAG_SYSTEM_MSG: &str = "SM";
pub const TAG_CMD_OUTPUT: &str = "CO";

// ─── Delta/Streaming Tags (lowercase) ──────────────────────────────

pub const TAG_ASSISTANT_X_DELTA: &str = "Ax";
pub const TAG_ASSISTANT_F_DELTA: &str = "Af";
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

/// Maximum accepted frame value length (mirrors Go's tlv.MaxFrameSize).
/// alayacore's frames are small (deltas, JSON payloads); a corrupt 4-byte
/// length field must not trigger a huge allocation.
pub const MAX_FRAME_SIZE: usize = 64 << 20; // 64 MiB

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
    if len > MAX_FRAME_SIZE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame too large: {} bytes", len),
        ));
    }

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

// ─── JSON Payload Types ──────────────────────────────────────────────
//
// Mirrors of alayacore's internal/protocol payloads (the field names are the
// wire contract). Used to build input frames and to parse output frames.

/// Frame-level metadata embedded in every content/function frame body.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ContentMeta {
    /// History id (set only on output frames; absent on input / the file).
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub id: String,
    /// Message time, RFC3339. Rides the authoritative frames and the session
    /// file; deltas (ephemeral) and input do not carry it.
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub time: String,
}

/// One piece of content: the body of a UX or AX frame, and each element of a
/// tool result's output. `kind` (the JSON "type") selects which payload field
/// is meaningful; the same shape is used at the top level and when nested.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ContentItem {
    #[serde(rename = "type")]
    pub kind: String,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub text: String,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub uri: String,
    #[serde(skip_serializing_if = "is_zero", default)]
    pub fps: i64,
    #[serde(skip_serializing_if = "is_zero", default)]
    pub res: i64,
}

fn is_zero(n: &i64) -> bool {
    *n == 0
}

/// JSON payload for a content frame (UX/AX): a content item plus the
/// frame-level metadata.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ContentData {
    #[serde(flatten)]
    pub meta: ContentMeta,
    #[serde(flatten)]
    pub item: ContentItem,
}

/// AF frame payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolInputData {
    pub call_id: String,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub input: Option<serde_json::Value>,
    #[serde(flatten)]
    pub meta: ContentMeta,
}

/// Af frame payload: a partial JSON argument chunk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolInputDeltaData {
    pub call_id: String,
    pub delta: String,
    #[serde(flatten)]
    pub meta: ContentMeta,
}

/// UF frame payload. `output` is an array of content items.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolOutputData {
    pub call_id: String,
    pub output: serde_json::Value,
    #[serde(default, skip_serializing_if = "is_false")]
    pub is_error: bool,
    #[serde(flatten)]
    pub meta: ContentMeta,
}

/// Uf frame payload: a display-only preview snapshot.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolOutputDeltaData {
    pub call_id: String,
    pub text: String,
    #[serde(flatten)]
    pub meta: ContentMeta,
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
/// `call_id` is generated by the adapter and echoed back in the matching CO.
/// `input` is an opaque argument string whose syntax is defined per command.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CmdMsg {
    pub call_id: String,
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty", default)]
    pub input: String,
}

/// Command output (CO frame payload) — agent → adapter.
/// Mirrors ToolOutputData (UF): on success `output` is the command's
/// structured result (may be null); on failure it is a uniform error
/// object `{"code":...,"message":...}`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CmdResultMsg {
    pub call_id: String,
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
        write_frame(&mut buf, "UX", "hello \u{0000} world").unwrap();

        let mut reader = buf.as_slice();
        let frame = read_frame(&mut reader).unwrap().unwrap();
        assert_eq!(frame.tag, "UX");
        assert_eq!(frame.value, "hello \u{0000} world");
        // Whole buffer consumed.
        assert!(read_frame(&mut reader).unwrap().is_none());
    }

    #[test]
    fn encode_uses_big_endian_length() {
        let value = "x".repeat(300);
        let buf = encode("UX", &value);
        // [tag 2][len 4][value]
        assert_eq!(&buf[0..2], b"UX");
        assert_eq!(u32::from_be_bytes([buf[2], buf[3], buf[4], buf[5]]), 300);
        assert_eq!(&buf[6..], value.as_bytes());
    }

    #[test]
    fn read_frame_eof_returns_none() {
        let mut reader: &[u8] = &[];
        assert!(read_frame(&mut reader).unwrap().is_none());
    }

    #[test]
    fn read_frame_rejects_oversized_length() {
        // Header claims MAX_FRAME_SIZE+1 bytes; must be rejected without
        // allocating the frame.
        let too_big = (MAX_FRAME_SIZE as u32) + 1;
        let mut header = Vec::new();
        header.extend_from_slice(b"UX");
        header.extend_from_slice(&too_big.to_be_bytes());
        let mut reader: &[u8] = &header;
        let err = read_frame(&mut reader).unwrap_err();
        assert!(err.to_string().contains("frame too large"), "got: {err}");
    }

    /// Pins the v14 content-frame body: kind in "type", history id in "id",
    /// message time in "time".
    #[test]
    fn content_data_roundtrip() {
        let data = ContentData {
            meta: ContentMeta { id: "7".into(), time: "2026-10-14T02:06:07Z".into() },
            item: ContentItem { kind: "text".into(), text: "hi".into(), ..Default::default() },
        };
        let s = serde_json::to_string(&data).unwrap();
        assert_eq!(
            s,
            r#"{"id":"7","time":"2026-10-14T02:06:07Z","type":"text","text":"hi"}"#
        );
        let back: ContentData = serde_json::from_str(&s).unwrap();
        assert_eq!(back.meta.id, "7");
        assert_eq!(back.item.kind, "text");
        assert_eq!(back.item.text, "hi");
    }

    #[test]
    fn json_payloads_roundtrip() {
        let output = ToolOutputData {
            call_id: "t5".into(),
            output: serde_json::json!([{"type": "text", "text": "ok"}]),
            is_error: false,
            meta: ContentMeta::default(),
        };
        let s = serde_json::to_string(&output).unwrap();
        let back: ToolOutputData = serde_json::from_str(&s).unwrap();
        assert_eq!(back.call_id, "t5");
        assert!(!back.is_error);
        assert_eq!(back.output[0]["text"], "ok");

        let cmd = CmdMsg { call_id: "c1".into(), name: "save".into(), input: "/tmp/x".into() };
        let s = serde_json::to_string(&cmd).unwrap();
        let back: CmdMsg = serde_json::from_str(&s).unwrap();
        assert_eq!(back.name, "save");
        assert_eq!(back.input, "/tmp/x");
    }
}
