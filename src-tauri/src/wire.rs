//! Frame protocol implementation for AlayaCore rawio mode (wire v15).
//!
//! Wire format: one frame per line —
//!
//! ```text
//! [2-byte tag][JSON value]\n
//! ```
//!
//! The tag is two ASCII letters. The value is a JSON object, except for the
//! control frames `UE` and `CE`, whose line is the tag alone. Nothing else
//! follows the value on the line, and there are no separator lines: every line
//! is one frame. There is no separator between the tag and the value — the
//! value begins at byte 2.
//!
//! A value is never more than one line: a raw LF or CR inside it would end the
//! frame early, so neither is allowed, and marshalling JSON with serde gets
//! that for free. A *trailing* CR is accepted on input and never written (a
//! writer on a platform that translates line endings produces it). A malformed
//! frame ends the stream — the reader does not skip it and does not
//! resynchronise — and a stream that ends mid-frame is an error, not a frame.
//!
//! A frame is at most 64MB: the tag, the value and the terminator together
//! (`MAX_FRAME_SIZE`), matching AlayaCore's `wire.MaxFrameSize`.
//!
//! The tag names the frame's PLANE, not the concrete content kind — the kind
//! travels inside the JSON as a content item's "type". The vocabulary is a 2x2
//! over {into the model (U), out of the model (A)} x {content (X), function
//! (F)}:
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
use std::io::{self, BufRead, Write};

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

/// A parsed frame.
#[derive(Debug, Clone)]
pub struct Frame {
    pub tag: String,
    pub value: String,
}

/// Maximum accepted frame size — the tag, the value and the terminator together
/// (mirrors Go's `wire.MaxFrameSize` and AlayaCore's `wire.MaxFrameSize`).
///
/// It bounds what a decoder holds at once, so a peer that never sends a
/// terminator cannot make this side allocate without limit. 64MB is what
/// AlayaCore bounds one MCP message by (the two agree on purpose) and is large
/// enough that a session which saved a multi-megabyte base64 attachment loads
/// again.
pub const MAX_FRAME_SIZE: usize = 64 << 20; // 64 MiB

/// is_letter reports whether `b` is an ASCII letter — what a tag is made of, so
/// a reader can tell a frame from the fragments of one.
fn is_letter(b: u8) -> bool {
    b.is_ascii_alphabetic()
}

/// Encode a frame into its wire bytes: the tag, the value, and the terminator.
///
/// It rejects a tag that is not two ASCII letters, a value that is not empty or
/// a JSON object, a value containing a raw LF or CR, and a frame above
/// `MAX_FRAME_SIZE`. The caller must surface these rather than dropping the
/// frame — a frame that was never written reads as the adapter going quiet.
pub fn encode(tag: &str, value: &str) -> io::Result<Vec<u8>> {
    if tag.len() != 2 || !tag.bytes().all(is_letter) {
        return Err(invalid(format!(
            "wire: tag must be two ASCII letters, got {tag:?} (len {})",
            tag.len()
        )));
    }
    if !value.is_empty() && !value.starts_with('{') {
        return Err(invalid(
            "wire: a frame's value must be a JSON object, or empty for a control frame".to_string(),
        ));
    }
    if let Some(i) = value.find(['\n', '\r']) {
        return Err(invalid(format!(
            "wire: {tag} frame's value contains a raw newline at offset {i}; a frame is one line"
        )));
    }
    if tag.len() + value.len() + 1 > MAX_FRAME_SIZE {
        return Err(invalid(format!(
            "wire: frame of {} bytes exceeds the maximum {MAX_FRAME_SIZE}",
            tag.len() + value.len() + 1
        )));
    }
    let mut buf = Vec::with_capacity(tag.len() + value.len() + 1);
    buf.extend_from_slice(tag.as_bytes());
    buf.extend_from_slice(value.as_bytes());
    buf.push(b'\n');
    Ok(buf)
}

/// Write one frame to a writer. Returns an error if the frame could not be
/// encoded (never a truncated frame) or if the write failed.
pub fn write_frame<W: Write>(writer: &mut W, tag: &str, value: &str) -> io::Result<()> {
    let buf = encode(tag, value)?;
    writer.write_all(&buf)
}

/// Read a single frame from a buffered reader.
///
/// Returns `Ok(None)` at a clean EOF (the stream ended at a frame boundary).
/// Any other error is terminal: the stream is finished, and a caller must stop
/// rather than read on — a malformed frame means the writer lost its place, and
/// no later line can be trusted as a frame.
///
/// The reader must be buffered (`BufRead`) because a frame's boundary is a
/// line: reading one line must not consume the bytes of the next, so the reader
/// buffers the excess it read ahead. A caller holds one buffered reader across
/// the whole stream.
pub fn read_frame<R: BufRead>(reader: &mut R) -> io::Result<Option<Frame>> {
    // Accumulate until a terminator, bounding what is held: `fill_buf` hands
    // back whatever the underlying reader has, so a frame large enough not to
    // fit in one buffer arrives in pieces, each of which is a chunk of the same
    // line — not a frame.
    let mut line: Vec<u8> = Vec::new();
    loop {
        let available = match reader.fill_buf() {
            Ok(b) => b,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        };
        if available.is_empty() {
            // EOF: a line that completed exactly at the boundary is a frame;
            // leftover bytes are a frame cut short.
            if line.is_empty() {
                return Ok(None);
            }
            return Err(invalid(
                "wire: stream ended with an unterminated frame".to_string(),
            ));
        }
        if let Some(pos) = available.iter().position(|&b| b == b'\n') {
            line.extend_from_slice(&available[..pos]);
            if line.len() + 1 > MAX_FRAME_SIZE {
                return Err(too_large());
            }
            reader.consume(pos + 1);
            break;
        }
        line.extend_from_slice(available);
        let n = available.len();
        reader.consume(n);
        if line.len() > MAX_FRAME_SIZE {
            return Err(too_large());
        }
    }
    decode_line(&line).map(Some)
}

/// decode_line validates the bytes of one line (without its terminator) and
/// splits them into tag and value.
fn decode_line(line: &[u8]) -> io::Result<Frame> {
    // Drop a trailing CR. A value can never contain one, so the only thing a
    // trailing one can be is part of a CRLF terminator.
    let line = match line.split_last() {
        Some((&b'\r', rest)) => rest,
        _ => line,
    };

    if line.is_empty() {
        return Err(invalid(
            "wire: blank line; every line must be one frame".to_string(),
        ));
    }
    if line.len() < 2 {
        return Err(invalid(format!(
            "wire: {:?} is shorter than a two-letter tag",
            String::from_utf8_lossy(line)
        )));
    }
    if !is_letter(line[0]) || !is_letter(line[1]) {
        return Err(invalid(format!(
            "wire: {:?} does not start with a two-letter tag",
            String::from_utf8_lossy(line)
        )));
    }

    let tag = String::from_utf8_lossy(&line[..2]).into_owned();
    let value = String::from_utf8(line[2..].to_vec())
        .map_err(|_| invalid(format!("wire: {tag} frame's value is not valid UTF-8")))?;
    if !value.is_empty() && !value.starts_with('{') {
        return Err(invalid(format!(
            "wire: {tag} frame's value must be a JSON object, or empty for a control frame"
        )));
    }
    Ok(Frame { tag, value })
}

fn invalid(msg: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, msg)
}

fn too_large() -> io::Error {
    invalid(format!(
        "wire: frame exceeds the maximum of {MAX_FRAME_SIZE} bytes"
    ))
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
    use std::io::BufReader;

    fn read_all(bytes: &[u8]) -> io::Result<Vec<(String, String)>> {
        let mut r = BufReader::new(bytes);
        let mut out = Vec::new();
        while let Some(f) = read_frame(&mut r)? {
            out.push((f.tag, f.value));
        }
        Ok(out)
    }

    #[test]
    fn encode_read_roundtrip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, "UX", r#"{"type":"text","text":"hi"}"#).unwrap();
        write_frame(&mut buf, "UE", "").unwrap();

        let frames = read_all(&buf).unwrap();
        assert_eq!(frames.len(), 2);
        assert_eq!(frames[0].0, "UX");
        assert_eq!(frames[0].1, r#"{"type":"text","text":"hi"}"#);
        assert_eq!(frames[1].0, "UE");
        assert_eq!(frames[1].1, "");
    }

    #[test]
    fn encode_is_tag_value_newline() {
        let value = r#"{"type":"text","text":"hi"}"#;
        let buf = encode("UX", value).unwrap();
        // [tag 2][value][\n] — no length field, no separator.
        let mut want = Vec::new();
        want.extend_from_slice(b"UX");
        want.extend_from_slice(value.as_bytes());
        want.push(b'\n');
        assert_eq!(buf, want);
    }

    #[test]
    fn read_frame_eof_returns_none() {
        let frames = read_all(b"").unwrap();
        assert!(frames.is_empty());
    }

    #[test]
    fn read_frame_rejects_unterminated_frame() {
        let err = read_all(br#"UX{"type":"text""#).unwrap_err();
        assert!(err.to_string().contains("unterminated"), "got: {err}");
    }

    #[test]
    fn read_frame_rejects_blank_line() {
        let err = read_all(b"\n").unwrap_err();
        assert!(err.to_string().contains("blank line"), "got: {err}");
    }

    #[test]
    fn read_frame_accepts_trailing_cr() {
        let frames = read_all(b"UX{\"type\":\"text\",\"text\":\"hi\"}\r\n").unwrap();
        assert_eq!(frames.len(), 1);
        assert_eq!(frames[0].0, "UX");
        assert_eq!(frames[0].1, r#"{"type":"text","text":"hi"}"#);
    }

    #[test]
    fn encode_rejects_bad_input() {
        assert!(encode("U", "{}").is_err(), "short tag");
        assert!(encode("1X", "{}").is_err(), "non-letter tag");
        assert!(encode("UX", "hello").is_err(), "value not an object");
        assert!(encode("UX", "{\n}").is_err(), "raw LF in value");
        assert!(encode("UX", "{\r}").is_err(), "raw CR in value");
    }

    /// Pins the v14+ content-frame body: kind in "type", history id in "id",
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
