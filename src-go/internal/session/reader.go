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

// disconnectMessage composes the `core-status` message for a pipe that just
// died.
//
// With nothing on stderr this returns the base text unchanged, so the common
// case (a session closed on purpose) reads exactly as it always did. With a
// tail, the LAST line is quoted: for a startup failure it is the whole reason
// (`Error: failed to load session: session file version mismatch: got 11,
// expected 12`), and `core-status.message` is a one-line UI field, so a stack
// trace does not belong in it. Everything the core wrote is still in the
// backend log (the pump forwards each line there), which is what the count
// suffix points at.
//
// Port of reader.rs::disconnect_message — the two must produce the same
// string, because the client shows whichever backend it is talking to.
func disconnectMessage(base string, tail *core.StderrTail) string {
	lines := tail.Lines()
	if len(lines) == 0 {
		return base
	}
	last := lines[len(lines)-1]
	runes := []rune(last)
	if len(runes) > core.StderrTailMaxChars {
		runes = runes[:core.StderrTailMaxChars]
	}
	clipped := string(runes)
	if len(lines) <= 1 {
		return fmt.Sprintf("%s: %s", base, clipped)
	}
	return fmt.Sprintf(
		"%s: %s (+%d more stderr lines in the backend log)",
		base, clipped, len(lines)-1,
	)
}

// SessionClosedMessage is the `core-status` message for a session the core
// ended itself — SM {"type":"session","data":{"state":"closed"}}.
//
// Distinct from "Connection closed" on purpose: that one means the pipe went
// away and the reason (if any) is on stderr, while this one means alayacore
// said it was finished. The client shows whichever it gets, so both backends
// use this exact text (scripts/check-backend-parity.sh compares them).
const SessionClosedMessage = "Session closed by alayacore"

// endsTheSession reports whether an SM envelope is the core's terminal frame.
//
// v12 of the protocol added it precisely so a client does not have to INFER the
// end from EOF. That inference is not free here: stdout stays open while
// anything still holds the write end, so a core that has finished can leave the
// reader parked on a read and the window showing a running session.
func endsTheSession(env *tlv.SystemMsgEnvelope) bool {
	if env == nil || env.Type != "session" {
		return false
	}
	var data struct {
		State string `json:"state"`
	}
	if err := json.Unmarshal(env.Data, &data); err != nil {
		return false
	}
	return data.State == "closed"
}

// startReader spawns the background goroutine that reads TLV frames from
// alayacore's stdout and broadcasts them to the hub (tlv-delta,
// tlv-frame, core-status). Port of reader.rs spawn_stdout_reader.
func (s *Session) startReader(h *hub.Hub, cache *ModelCache) {
	go func() {
		defer s.Stdout.Close()
		reader := bufio.NewReader(s.Stdout)
		// One `core-status: false` per session. The terminal frame and the EOF
		// that follows it describe the same fact, and the client's plan runner
		// fails its node on each one it receives.
		announced := false

		for {
			frame, err := tlv.ReadFrame(reader)
			if err != nil || frame == nil {
				base := "Connection closed"
				if err != nil {
					base = fmt.Sprintf("Read error: %v", err)
				}
				s.disconnect(h, announced, disconnectMessage(base, s.StderrTail))
				return
			}
			if s.dispatchFrame(h, cache, frame) && !announced {
				// The core's terminal frame: report the end from the frame
				// rather than inferring it from EOF, which is what v12 added
				// it for.
				//
				// Deliberately does NOT clear `connected` or reap: this
				// backend's `connected` means "the pipe is usable", and EOF is
				// what decides that. Close waits on the child actually exiting
				// (Rust `try_wait`, Go `Connected()`), and moving that earlier
				// on one side only would be exactly the behavioral drift
				// AGENTS.md warns about.
				announced = true
				s.announce(h, SessionClosedMessage)
			}
		}
	}()
}

// announce broadcasts the core-status event that ends a session, for callers
// that have already decided this is the one and only end announcement.
func (s *Session) announce(h *hub.Hub, message string) {
	h.Broadcast(hub.NewEvent("core-status", StatusEvent{
		SessionID: s.ID,
		Connected: false,
		Message:   message,
	}))
	log.Printf("[reader] %s disconnected: %s", s.ID, message)
}

// disconnect marks the session disconnected, reaps the child, and broadcasts
// core-status — unless the terminal frame already announced the end
// (`announced`), which is the normal order: alayacore writes `closed`, then
// exits, and EOF follows.
//
// Called from the reader goroutine only.
func (s *Session) disconnect(h *hub.Hub, announced bool, message string) {
	s.setConnected(false)
	s.kill()
	if !announced {
		s.announce(h, message)
	}
}

// dispatchFrame routes a single TLV frame to the appropriate event(s).
//
// Returns true when the frame ENDED the session (endsTheSession), which is the
// reader's cue to announce the end. Every other frame returns false, and the
// reader keeps going.
//
// Port of reader.rs::dispatch_frame.
func (s *Session) dispatchFrame(h *hub.Hub, cache *ModelCache, frame *tlv.Frame) bool {
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
		return s.handleSMFrame(h, cache, rawValue)
	// ─── Everything else (user echoes, unknown) ──────────────────
	default:
		var uct *string
		if isUserEchoTag(tag) {
			t := tag
			uct = &t
		}
		s.emitFrame(h, tag, rawValue, nil, uct, false)
	}
	return false
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
// forwards the envelope as {type, data}. Returns true for the core's terminal
// frame (see endsTheSession).
func (s *Session) handleSMFrame(h *hub.Hub, cache *ModelCache, rawValue string) bool {
	var env tlv.SystemMsgEnvelope
	if err := json.Unmarshal([]byte(rawValue), &env); err != nil {
		s.emitFrame(h, "SM", rawValue, nil, nil, false)
		return false
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

	ended := endsTheSession(&env)
	wrapped, _ := json.Marshal(map[string]any{
		"type": env.Type,
		"data": env.Data,
	})
	s.emitFrame(h, "SM", rawValue, wrapped, nil, false)
	return ended
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
