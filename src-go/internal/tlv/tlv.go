// Package tlv implements the TLV wire protocol for AlayaCore rawio mode.
//
// Wire format: [2-byte tag][4-byte big-endian length][N bytes of value]
//
// Tags (stdin → agent):
//
//	UT   User text
//	UI   User image (data:image/...;base64,... or URL)
//	UV   User video
//	UA   User audio
//	UD   User document
//	UE   User message end — flushes staged content
//	CI   Command input (JSON CmdMsg: {"id":"...","name":"...","input":"..."})
//
// Tags (stdout ← agent):
//
//	At   Assistant text streaming delta (\x00<id>\x00<content>)
//	Ar   Assistant reasoning streaming delta (\x00<id>\x00<content>)
//	Af   Function/tool argument streaming delta (\x00<id>\x00<JSON delta>)
//	Uf   Function/tool result preview snapshot, ephemeral/display-only
//	     (\x00<id>\x00<JSON {"id","text"}>; never authoritative — UF overwrites)
//	AT   Assistant text complete/authoritative (\x00<id>\x00<content>; empty if deltas preceded it)
//	AR   Assistant reasoning complete/authoritative (\x00<id>\x00<content>; empty if deltas preceded it)
//	AF   Function/tool lifecycle (\x00<id>\x00<JSON>)
//	UF   Function/tool result (\x00<id>\x00<JSON>)
//	CO   Command output (JSON CmdResultMsg: {"id":"...","output":...,"is_error":...})
//	SM   System message (JSON: {"type":"...","data":{...}})
//	UT   User text echo (\x00<id>\x00<content>)
//	UI   User image echo (\x00<id>\x00<data URI or URL>)
//	UV   User video echo (\x00<id>\x00<data URI or URL>)
//	UA   User audio echo (\x00<id>\x00<data URI or URL>)
//	UD   User document echo (\x00<id>\x00<data URI or URL>)
package tlv

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"unicode/utf8"
)

// Input tags (sent to AlayaCore stdin).
const (
	TagUserText  = "UT"
	TagUserImage = "UI"
	TagUserVideo = "UV"
	TagUserAudio = "UA"
	TagUserDoc   = "UD"
	TagUserEnd   = "UE"
	TagCmdInput  = "CI"
)

// Output tags (received from AlayaCore stdout).
const (
	TagAssistantText      = "AT"
	TagAssistantReasoning = "AR"
	TagAssistantTool      = "AF"
	TagUserToolResult     = "UF"
	TagSystemMsg          = "SM"
	TagCmdOutput          = "CO"
)

// Delta/streaming tags (lowercase).
const (
	TagAssistantTextDelta      = "At"
	TagAssistantReasoningDelta = "Ar"
	TagToolArgDelta            = "Af"
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
const MaxFrameSize = 256 << 20 // 256 MiB

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

// DeltaParts is the result of parsing a NUL-delimited delta frame value.
type DeltaParts struct {
	// HistoryID is the history ID extracted from the NUL prefix, or empty.
	HistoryID string
	// Content is the content after the NUL-delimited prefix, or the full value.
	Content string
	// HasDelta reports whether a valid NUL-delimited prefix was found.
	HasDelta bool
}

// UnwrapDelta parses a NUL-delimited history ID prefix:
//
//	\x00<history-id>\x00<content>
//
// Same history ID → continuation; different → new content block.
func UnwrapDelta(value string) DeltaParts {
	b := []byte(value)
	if len(b) == 0 || b[0] != 0 {
		return DeltaParts{Content: value}
	}
	// Find the closing NUL in b[1:]; idx is relative to b[1:].
	if idx := bytes.IndexByte(b[1:], 0); idx >= 0 {
		endIdx := idx + 1 // index within b
		id := string(b[1:endIdx])
		if id == "" {
			return DeltaParts{Content: value}
		}
		return DeltaParts{
			HistoryID: id,
			Content:   string(b[endIdx+1:]),
			HasDelta:  true,
		}
	}
	return DeltaParts{Content: value}
}

// ToolInputData is the AF frame payload.
type ToolInputData struct {
	ID    string          `json:"id"`
	Name  *string         `json:"name,omitempty"`
	Input json.RawMessage `json:"input,omitempty"`
	// Delta is present in Af (tool argument delta) frames.
	Delta *string `json:"delta,omitempty"`
}

// ToolOutputData is the UF frame payload.
type ToolOutputData struct {
	ID      string          `json:"id"`
	Output  json.RawMessage `json:"output"`
	IsError bool            `json:"is_error,omitempty"`
}

// SystemMsgEnvelope is the SM frame payload.
type SystemMsgEnvelope struct {
	Type string          `json:"type"`
	Data json.RawMessage `json:"data"`
}

// CmdMsg is the CI frame payload (adapter → agent).
// ID is generated by the adapter and echoed back in the matching CO.
// Input is an opaque argument string whose syntax is defined per command.
type CmdMsg struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Input string `json:"input,omitempty"`
}

// CmdResultMsg is the CO frame payload (agent → adapter).
type CmdResultMsg struct {
	ID      string          `json:"id"`
	Output  json.RawMessage `json:"output"`
	IsError bool            `json:"is_error,omitempty"`
}
