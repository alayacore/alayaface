// Package wire implements AlayaCore's frame protocol for rawio mode.
//
// Wire format (protocol v17): one frame per line.
//
//	[2-byte tag][JSON value]\n
//
// The tag is exactly two ASCII letters. The value is a JSON object, except for
// the control frames UE and CE, whose line is the tag alone. Nothing else
// follows the value on the line, and there are no separator lines: every line
// is one frame.
//
// There is no separator between the tag and the value: the value begins at byte
// 2. A frame's value may never contain a raw LF or CR — that would end the
// frame early — so a writer that marshals JSON with encoding/json gets that for
// free ("\n" is escaped). A *trailing* CR is accepted on input and never
// written: a writer on a platform that translates line endings produces it.
//
// A malformed frame ends the stream: the reader does not skip it and does not
// resynchronise, because a frame that is not a frame means the writer lost its
// place. A stream that ends mid-frame is an error, not a frame: a truncated
// message must not be read as a complete one.
//
// The two-character tag names the frame's PLANE, not the concrete content kind
// — the kind travels inside the JSON as a content item's "type". The vocabulary
// is a 2x2 over {into the model (U), out of the model (A)} x {content (X),
// function (F)}:
//
//	UX  ↔   User content — JSON content item (both directions: input + echo)
//	AX  ←   Assistant content — JSON content item, complete/authoritative
//	AF  ←   Assistant function/tool call (JSON: call_id, name, input)
//	UF  ←   User function/tool result (JSON: call_id, output, is_error)
//	UE  →   User message end — flushes staged content as one message
//	CI  →   Command input (JSON CmdMsg: {"command_id":...,"name":...,"args":...})
//	CE  →   Control-plane input end — no more PROMPTS; the stream stays
//	        open, so commands may still follow (v12; see TagInputEnd)
//	CO  ←   Command output (JSON CmdResultMsg: {"command_id":...,"result":...})
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
package wire

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
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
	// Port of wire.rs::TAG_INPUT_END.
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

// Frame is a parsed wire frame.
type Frame struct {
	Tag   string
	Value string
}

// MaxFrameSize caps a single frame — the tag, the value and the terminator
// together — matching AlayaCore's wire.MaxFrameSize. It is 64 MiB because that
// is what AlayaCore bounds one MCP message by, and because a session that saved
// a multi-megabyte base64 attachment must load again. It keeps a corrupt or
// hostile stream from growing a reader's buffer without bound: the raw frame is
// also forwarded to every WebSocket client, so an oversized frame would
// multiply through the hub's per-client send buffers.
const MaxFrameSize = 64 << 20 // 64 MiB

// isLetter reports whether b is an ASCII letter, which is what a frame's tag is
// made of: a reader can then tell a frame from the fragments of one.
func isLetter(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

// Encode builds the wire bytes of a single frame: the tag, the value, and the
// terminator.
//
// It rejects a tag that is not two ASCII letters, a value that is not empty or a
// JSON object, a value containing a raw LF or CR, and a frame above
// MaxFrameSize. A caller must surface these rather than dropping the frame — a
// frame that was never written reads as the adapter going quiet.
func Encode(tag, value string) ([]byte, error) {
	if len(tag) != 2 || !isLetter(tag[0]) || !isLetter(tag[1]) {
		return nil, fmt.Errorf("wire: tag must be two ASCII letters, got %q (len %d)", tag, len(tag))
	}
	if value != "" && value[0] != '{' {
		return nil, errors.New("wire: a frame's value must be a JSON object, or empty for a control frame")
	}
	if i := strings.IndexAny(value, "\n\r"); i >= 0 {
		return nil, fmt.Errorf("wire: %s frame's value contains a raw %q at offset %d; a frame is one line", tag, value[i], i)
	}
	if len(tag)+len(value)+1 > MaxFrameSize {
		return nil, fmt.Errorf("wire: frame of %d bytes exceeds the maximum %d", len(tag)+len(value)+1, MaxFrameSize)
	}
	buf := make([]byte, 0, len(tag)+len(value)+1)
	buf = append(buf, tag...)
	buf = append(buf, value...)
	buf = append(buf, '\n')
	return buf, nil
}

// WriteFrame writes one frame to w. It returns an error if the frame could not
// be encoded (never a truncated frame) or if the write failed.
func WriteFrame(w io.Writer, tag, value string) error {
	buf, err := Encode(tag, value)
	if err != nil {
		return err
	}
	_, err = w.Write(buf)
	return err
}

// ReadFrame reads a single frame from r.
//
// It returns (nil, nil) on a clean EOF (the stream ended at a frame boundary).
// Any other error is terminal: the stream is finished, and a caller must stop
// rather than read on — a malformed frame means the writer lost its place, and
// no later line can be trusted as a frame.
//
// r must be a *bufio.Reader because a frame's boundary is a line: reading one
// line must not consume the bytes of the next, so the reader buffers the excess
// it read ahead. Callers hold one *bufio.Reader across the whole stream.
func ReadFrame(r *bufio.Reader) (*Frame, error) {
	// Accumulate until a terminator, bounding what is held: ReadSlice returns
	// ErrBufferFull when the buffer fills without a terminator, which is a
	// chunk of the same line, not a frame.
	var line []byte
	for {
		chunk, err := r.ReadSlice('\n')
		if len(chunk) > 0 {
			line = append(line, chunk...)
			if len(line) > MaxFrameSize {
				return nil, fmt.Errorf("wire: frame exceeds the maximum of %d bytes", MaxFrameSize)
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			if err == io.EOF {
				if len(line) == 0 {
					return nil, nil // clean EOF between frames
				}
				return nil, errors.New("wire: stream ended with an unterminated frame")
			}
			return nil, err
		}
		break
	}
	return decodeLine(line)
}

// decodeLine validates the bytes of one line (with or without its terminator)
// and splits them into tag and value.
func decodeLine(line []byte) (*Frame, error) {
	// Drop the terminator, if present: an LF, and a CR before it. A value can
	// never contain either character, so the only thing a trailing one can be
	// is the terminator.
	if n := len(line); n > 0 && line[n-1] == '\n' {
		line = line[:n-1]
	}
	if n := len(line); n > 0 && line[n-1] == '\r' {
		line = line[:n-1]
	}

	switch {
	case len(line) == 0:
		return nil, errors.New("wire: blank line; every line must be one frame")
	case len(line) < 2:
		return nil, fmt.Errorf("wire: %q is shorter than a two-letter tag", line)
	case !isLetter(line[0]) || !isLetter(line[1]):
		return nil, fmt.Errorf("wire: %q does not start with a two-letter tag", line)
	}

	tag := string(line[:2])
	if !utf8.Valid(line[2:]) {
		return nil, fmt.Errorf("wire: %s frame's value is not valid UTF-8", tag)
	}
	value := string(line[2:])
	if value != "" && value[0] != '{' {
		return nil, fmt.Errorf("wire: %s frame's value must be a JSON object, or empty for a control frame", tag)
	}
	return &Frame{Tag: tag, Value: value}, nil
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
// CommandID is generated by the adapter and echoed back in the matching CO.
// It is NOT a tool call's call_id: that is the provider's tool_call_id in the
// other plane. Args is an opaque argument string whose syntax is defined per
// command.
type CmdMsg struct {
	CommandID string `json:"command_id"`
	Name      string `json:"name"`
	Args      string `json:"args,omitempty"`
}

// CmdResultMsg is the CO frame payload (agent → adapter).
// On success Result is the command's structured result (may be null); on
// failure it is a uniform error object {"code":...,"message":...}. Only
// IsError is shared with UF: a command result is opaque and command-defined,
// not a content-item array.
type CmdResultMsg struct {
	CommandID string          `json:"command_id"`
	Result    json.RawMessage `json:"result"`
	IsError   bool            `json:"is_error,omitempty"`
}
