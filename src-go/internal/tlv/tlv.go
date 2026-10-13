// Package tlv implements the TLV wire protocol for AlayaCore rawio mode.
//
// Wire format: [2-byte tag][4-byte big-endian length][N bytes of value]
//
// Protocol v14: every frame's value is either a zero-length control payload
// (UE, CE) or a JSON object. The two-character tag names the frame's PLANE,
// not the concrete content kind — the kind travels inside the JSON as a
// content item's "type". The vocabulary is a 2x2 over {into the model (U),
// out of the model (A)} x {content (X), function (F)}:
//
//	UX  ↔   User content — JSON content item (both directions: input + echo)
//	AX  ←   Assistant content — JSON content item, complete/authoritative
//	AF  ←   Assistant function/tool call (JSON: call_id, name, input)
//	UF  ←   User function/tool result (JSON: call_id, output, is_error)
//	UE  →   User message end — flushes staged content as one message
//	CI  →   Command input (JSON CmdMsg: {"call_id":...,"name":...,"input":...})
//	CE  →   Control-plane input end — no more PROMPTS; the stream stays
//	        open, so commands may still follow (v12; see TagInputEnd)
//	CO  ←   Command output (JSON CmdResultMsg: {"call_id":...,"output":...})
//	SM  ←   System message (JSON: {"type":"...","data":{...}})
//
// Lowercase tags carry streaming delta / incremental content:
//
//	Ax  ←   Assistant content delta (type inside the JSON: text or reasoning)
//	Af  ←   Assistant function/tool call delta (partial JSON argument)
//	Uf  ←   Tool result preview snapshot (ephemeral, display-only; UF overwrites)
//
// History id: output content/function frames carry it as the JSON top-level
// "id" (an ordinary field — there is no NUL-delimited prefix any more), and
// authoritative frames also carry "time" (RFC3339). Input frames carry
// neither. The tool-call id is "call_id", so "id" means history id everywhere.
package tlv

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"unicode/utf8"
)

// Input tags (sent to AlayaCore stdin).
const (
	// TagUserX is user content: a JSON content item (type + text/uri/…).
	// It is used in BOTH directions — the adapter sends new user content on
	// stdin, and the agent echoes it back on stdout with a history id.
	TagUserX    = "UX"
	TagUserEnd  = "UE"
	TagCmdInput = "CI"
	// TagInputEnd is the control-plane input end (protocol v12): "no more
	// prompts, but this stream stays open", so commands can still follow —
	// TCP's FIN rather than a torn down connection. alayacore treats it
	// exactly like EOF on stdin.
	//
	// This backend never SENDS it, and that is a decision rather than an
	// omission: AlayaFace has no end of prompts to declare (a window that
	// stops prompting may prompt again), and close_session wants the opposite
	// — the process gone — so it closes stdin outright, which ends the command
	// path too and is the point there. It is carried because the tag alphabet
	// is a fact about the wire: check-backend-parity.sh compares the two
	// backends' tag lists, so a tag that exists in the protocol exists here,
	// and a future half-close is not a surprise to whoever reads this file.
	// Port of tlv.rs::TAG_INPUT_END.
	TagInputEnd = "CE"
)

// Output tags (received from AlayaCore stdout).
const (
	TagAssistantX = "AX"
	TagAssistantF = "AF"
	TagUserF      = "UF"
	TagSystemMsg  = "SM"
	TagCmdOutput  = "CO"
)

// Delta/streaming tags (lowercase).
const (
	TagAssistantXDelta = "Ax"
	TagAssistantFDelta = "Af"
	// TagUserFDelta is an ephemeral tool result preview snapshot
	// (display-only; never authoritative — UF overwrites).
	TagUserFDelta = "Uf"
)

// Frame is a parsed TLV frame.
type Frame struct {
	Tag   string
	Value string
}

// Encode builds a TLV frame: [2-byte tag][4-byte big-endian length][value bytes].
func Encode(tag, value string) []byte {
	data := []byte(value)
	buf := make([]byte, 6+len(data))
	copy(buf[0:2], tag)
	binary.BigEndian.PutUint32(buf[2:6], uint32(len(data)))
	copy(buf[6:], data)
	return buf
}

// WriteFrame writes a TLV frame to w.
func WriteFrame(w io.Writer, tag, value string) error {
	_, err := w.Write(Encode(tag, value))
	return err
}

// MaxFrameSize caps a single TLV frame's value length. alayacore's
// frames are small (deltas, JSON payloads); the 4-byte length field
// would otherwise allow a corrupt stream to trigger a huge allocation.
// 64 MiB still accommodates large tool results (e.g. base64 images)
// while keeping a single frame far below OOM territory — and the raw
// value is forwarded to every WebSocket client, so an oversized frame
// would multiply through the hub's per-client send buffers.
const MaxFrameSize = 64 << 20 // 64 MiB

// ReadFrame reads a single TLV frame from r.
// Returns (nil, nil) on clean EOF; (nil, err) on protocol/IO errors.
// Mirrors Rust read_frame: a short header read is EOF, a short value
// read is a protocol error.
func ReadFrame(r io.Reader) (*Frame, error) {
	var header [6]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		if err == io.EOF || err == io.ErrUnexpectedEOF {
			return nil, nil
		}
		return nil, err
	}

	tag := string(header[0:2])
	if !utf8.Valid(header[0:2]) {
		return nil, fmt.Errorf("invalid tag bytes: %q", header[0:2])
	}

	length := binary.BigEndian.Uint32(header[2:6])
	if length > MaxFrameSize {
		return nil, fmt.Errorf("frame too large: %d bytes", length)
	}
	value := make([]byte, length)
	if length > 0 {
		if _, err := io.ReadFull(r, value); err != nil {
			return nil, err
		}
	}
	if !utf8.Valid(value) {
		return nil, fmt.Errorf("invalid utf-8 value")
	}

	return &Frame{Tag: tag, Value: string(value)}, nil
}

// ─── JSON Payload Types ───────────────────────────────────────────────
//
// Mirrors of alayacore's internal/protocol payloads (the field names are
// the wire contract). Used to build input frames and to parse output frames.

// ContentMeta is the frame-level metadata embedded in every content/function
// frame body.
//
//   - ID is the history id (set only on *output* frames; absent on input and
//     in the session file).
//   - Time is the message time (RFC3339): it rides the authoritative frames
//     and the session file; deltas (ephemeral) and input do not carry it.
type ContentMeta struct {
	ID   string `json:"id,omitempty"`
	Time string `json:"time,omitempty"`
}

// ContentItem is one piece of content: the body of a UX or AX frame, and each
// element of a tool result's output. Type selects which payload field is
// meaningful; the same shape is used at the top level and when nested.
type ContentItem struct {
	Type string `json:"type"`
	Text string `json:"text,omitempty"`
	URI  string `json:"uri,omitempty"`
	FPS  int    `json:"fps,omitempty"` // video only
	Res  int    `json:"res,omitempty"` // video only
}

// ContentData is the JSON payload for a content frame (UX/AX): a content item
// plus the frame-level metadata.
type ContentData struct {
	ContentMeta
	ContentItem
}

// ToolInputData is the AF frame payload.
type ToolInputData struct {
	CallID string          `json:"call_id"`
	Name   string          `json:"name,omitempty"`
	Input  json.RawMessage `json:"input,omitempty"`
	ContentMeta
}

// ToolInputDeltaData is the Af frame payload: a partial JSON argument chunk.
type ToolInputDeltaData struct {
	CallID string `json:"call_id"`
	Delta  string `json:"delta"`
	ContentMeta
}

// ToolOutputData is the UF frame payload. Output is an array of content items.
type ToolOutputData struct {
	CallID  string          `json:"call_id"`
	Output  json.RawMessage `json:"output"`
	IsError bool            `json:"is_error,omitempty"`
	ContentMeta
}

// ToolOutputDeltaData is the Uf frame payload: a display-only preview snapshot.
type ToolOutputDeltaData struct {
	CallID string `json:"call_id"`
	Text   string `json:"text"`
	ContentMeta
}

// SystemMsgEnvelope is the SM frame payload.
type SystemMsgEnvelope struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

// CmdMsg is the CI frame payload (adapter → agent).
// CallID is generated by the adapter and echoed back in the matching CO.
// Input is an opaque argument string whose syntax is defined per command.
type CmdMsg struct {
	CallID string `json:"call_id"`
	Name   string `json:"name"`
	Input  string `json:"input,omitempty"`
}

// CmdResultMsg is the CO frame payload (agent → adapter).
type CmdResultMsg struct {
	CallID  string          `json:"call_id"`
	Output  json.RawMessage `json:"output"`
	IsError bool            `json:"is_error,omitempty"`
}
