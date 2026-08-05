package session

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"

	"alayaface/src-go/internal/core"
	"alayaface/src-go/internal/hub"
	"alayaface/src-go/internal/tlv"
)

// userEchoTags are user-role content tags that appear on stdout (echoes).
var userEchoTags = map[string]bool{"UT": true, "UI": true, "UV": true, "UA": true, "UD": true}

func isUserEchoTag(tag string) bool { return userEchoTags[tag] }

// startReader spawns the background goroutine that reads TLV frames from
// alayacore's stdout and broadcasts them to the hub (tlv-delta,
// tlv-frame, core-status). Port of reader.rs spawn_stdout_reader.
func (s *Session) startReader(h *hub.Hub, cache *ModelCache) {
	go func() {
		defer s.Stdout.Close()
		reader := bufio.NewReader(s.Stdout)

		for {
			frame, err := tlv.ReadFrame(reader)
			if err != nil {
				s.disconnect(h, fmt.Sprintf("Read error: %v", err))
				return
			}
			if frame == nil { // clean EOF
				s.disconnect(h, "Connection closed")
				return
			}
			s.dispatchFrame(h, cache, frame)
		}
	}()
}

// disconnect marks the session disconnected, reaps the child, and
// broadcasts core-status. Called from the reader goroutine only.
func (s *Session) disconnect(h *hub.Hub, message string) {
	s.setConnected(false)
	core.KillChild(s.Child)
	h.Broadcast(hub.NewEvent("core-status", StatusEvent{
		SessionID: s.ID,
		Connected: false,
		Message:   message,
	}))
	log.Printf("[reader] %s disconnected: %s", s.ID, message)
}

// dispatchFrame routes a single TLV frame to the appropriate event(s).
// Port of reader.rs dispatch_frame.
func (s *Session) dispatchFrame(h *hub.Hub, cache *ModelCache, frame *tlv.Frame) {
	tag := frame.Tag
	rawValue := frame.Value

	preview := rawValue
	if len(preview) > 200 {
		preview = preview[:200]
	}
	log.Printf("[tlv] << %s %s %db %s", s.ID, tag, len(rawValue), preview)

	switch tag {
	// ─── Streaming deltas (At, Ar) ───────────────────────────────
	case "At", "Ar":
		parts := tlv.UnwrapDelta(rawValue)
		if parts.HasDelta {
			h.Broadcast(hub.NewEvent("tlv-delta", DeltaEvent{
				SessionID: s.ID,
				HistoryID: parts.HistoryID,
				Content:   parts.Content,
				Tag:       tag,
			}))
			// Intentionally NOT emitting tlv-frame here: At/Ar are
			// pure delta events; a tlv-frame would cause a second
			// dispatch in the frontend reducer.
		} else {
			// Malformed delta (no NUL prefix) — send raw frame.
			s.emitFrame(h, tag, rawValue, nil, nil, false)
		}
	// ─── Complete/authoritative (AT, AR) ─────────────────────────
	// Delta mode: content is empty (terminator). Replay/--no-delta:
	// full text.
	case "AT", "AR":
		s.emitFrame(h, tag, rawValue, nil, nil, true)
	// ─── JSON frames (Af, AF, UF, Uf) ────────────────────────────
	case "Af", "AF", "UF", "Uf":
		s.handleJSONFrame(h, tag, rawValue)
	// ─── Command output (CO) ─────────────────────────────────────
	case "CO":
		s.handleCmdOutputFrame(h, rawValue)
	// ─── System message (SM) ─────────────────────────────────────
	case "SM":
		s.handleSMFrame(h, cache, rawValue)
	// ─── Everything else (user echoes, unknown) ──────────────────
	default:
		var uct *string
		if isUserEchoTag(tag) {
			t := tag
			uct = &t
		}
		s.emitFrame(h, tag, rawValue, nil, uct, false)
	}
}

// handleJSONFrame handles AF/UF/Uf/Af JSON frames: parse the payload
// (after the NUL prefix) and forward it as `json`.
func (s *Session) handleJSONFrame(h *hub.Hub, tag, rawValue string) {
	parts := tlv.UnwrapDelta(rawValue)
	var parsed json.RawMessage
	if parts.HasDelta {
		parsed = json.RawMessage(parts.Content)
	} else {
		parsed = json.RawMessage(rawValue)
	}
	if !json.Valid(parsed) {
		parsed = nil
	}
	s.emitFrame(h, tag, rawValue, parsed, nil, false)
}

// handleCmdOutputFrame handles CO frames: inject the command name from
// the pending-commands registry into the JSON payload so the frontend
// can render the result without tracking call IDs itself.
func (s *Session) handleCmdOutputFrame(h *hub.Hub, rawValue string) {
	var jsonVal json.RawMessage
	var obj map[string]any
	if err := json.Unmarshal([]byte(rawValue), &obj); err == nil {
		if id, ok := obj["id"].(string); ok {
			if name, ok2 := s.PendingCmds.LoadAndDelete(id); ok2 {
				obj["name"] = name
			}
		}
		if b, err := json.Marshal(obj); err == nil {
			jsonVal = b
		}
	}
	s.emitFrame(h, "CO", rawValue, jsonVal, nil, false)
}

// handleSMFrame handles SM system message frames: caches model_list and
// forwards the envelope as {type, data}.
func (s *Session) handleSMFrame(h *hub.Hub, cache *ModelCache, rawValue string) {
	var env tlv.SystemMsgEnvelope
	if err := json.Unmarshal([]byte(rawValue), &env); err != nil {
		s.emitFrame(h, "SM", rawValue, nil, nil, false)
		return
	}

	// Cache model_list (before any other processing).
	if env.Type == "model_list" {
		var data struct {
			Models []json.RawMessage `json:"models"`
		}
		if err := json.Unmarshal(env.Data, &data); err == nil && data.Models != nil {
			cache.Set(data.Models)
		}
	}

	wrapped, _ := json.Marshal(map[string]any{
		"type": env.Type,
		"data": env.Data,
	})
	s.emitFrame(h, "SM", rawValue, wrapped, nil, false)
}

// emitFrame builds and broadcasts a tlv-frame event from a raw frame
// value. Unwraps the optional NUL-delimited history-ID prefix; json and
// userContentType are attached verbatim. emptyToNone maps an empty
// payload to content: null (used by AT/AR terminators).
func (s *Session) emitFrame(h *hub.Hub, tag, rawValue string, jsonVal json.RawMessage, userContentType *string, emptyToNone bool) {
	parts := tlv.UnwrapDelta(rawValue)

	var content *string
	if parts.HasDelta {
		c := parts.Content
		content = &c
	} else {
		c := rawValue
		content = &c
	}
	if emptyToNone && content != nil && *content == "" {
		content = nil
	}

	var historyID *string
	if parts.HasDelta {
		id := parts.HistoryID
		historyID = &id
	}

	h.Broadcast(hub.NewEvent("tlv-frame", FrameEvent{
		SessionID:       s.ID,
		Tag:             tag,
		RawValue:        rawValue,
		HistoryID:       historyID,
		Content:         content,
		JSON:            jsonVal,
		UserContentType: userContentType,
	}))
}
