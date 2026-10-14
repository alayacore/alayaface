package session

import "encoding/json"

// Event payloads pushed to the frontend. Field names and null semantics
// must match the Rust serde output exactly (see src-tauri/src/event.rs
// and the Elm decoders in src-elm/src/Session/Protocol.elm).

// DeltaEvent is emitted when a streaming delta frame (Ax) arrives.
// ContentType is the content item's kind ("text" or "reasoning"), which the
// delta's tag no longer names.
type DeltaEvent struct {
	SessionID   string `json:"session_id"`
	HistoryID   string `json:"history_id"`
	Content     string `json:"content"`
	Tag         string `json:"tag"`
	ContentType string `json:"content_type"`
}

// FrameEvent is emitted when any complete frame arrives from
// alayacore stdout.
type FrameEvent struct {
	SessionID string `json:"session_id"`
	Tag       string `json:"tag"`
	RawValue  string `json:"raw_value"`
	// HistoryID is the JSON top-level "id" when present; otherwise null
	// (Rust Option serializes as null — no omitempty).
	HistoryID *string `json:"history_id"`
	Content   *string `json:"content"`
	// JSON is the parsed payload for JSON frames, else null.
	JSON json.RawMessage `json:"json"`
	// ContentType is the content item's "type" for content frames
	// (UX/AX): "text"/"reasoning"/"image"/"audio"/"video"/"document".
	ContentType *string `json:"content_type"`
}

// StatusEvent is emitted when the connection status of a session changes.
type StatusEvent struct {
	SessionID string `json:"session_id"`
	Connected bool   `json:"connected"`
	Message   string `json:"message"`
}
