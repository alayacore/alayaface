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

// disconnectMessage composes the `core-status` message for a pipe that just
// died.
//
// With nothing on stderr this returns the base text unchanged, so the common
// case (a session closed on purpose) reads exactly as it always did. With a
// tail, the LAST line is quoted: for a startup failure it is the whole reason
// (`Error: failed to load session: session file version mismatch: got 12,
// expected 14`), and `core-status.message` is a one-line UI field, so a stack
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
//
// v14: content and function frames carry a JSON object whose concrete kind is
// the "type" of a content item; the tag names only the plane. The history id
// is the JSON top-level "id" (no NUL prefix), and the tool-call id is
// "call_id". The reader parses the body here and forwards it as `json`, plus
// the history id and content type on the event envelope so the frontend can
// key and route without re-parsing.
func (s *Session) dispatchFrame(h *hub.Hub, cache *ModelCache, frame *tlv.Frame) bool {
	tag := frame.Tag
	rawValue := frame.Value

	preview := rawValue
	if len(preview) > 200 {
		preview = preview[:200]
	}
	log.Printf("[tlv] << %s %s %db %s", s.ID, tag, len(rawValue), preview)

	switch tag {
	// ─── Assistant content delta (Ax) ────────────────────────────
	case tlv.TagAssistantXDelta:
		s.handleAssistantDeltaFrame(h, rawValue)
	// ─── Assistant content, complete/authoritative (AX) ──────────
	// Delta mode: content is empty (terminator). Replay/--no-delta:
	// full text.
	case tlv.TagAssistantX:
		s.handleContentFrame(h, tag, rawValue)
	// ─── User content echo (UX) ──────────────────────────────────
	case tlv.TagUserX:
		s.handleContentFrame(h, tag, rawValue)
	// ─── Function frames (Af, AF, UF, Uf) ────────────────────────
	case tlv.TagAssistantFDelta, tlv.TagAssistantF, tlv.TagUserF, tlv.TagUserFDelta:
		s.handleFunctionFrame(h, tag, rawValue)
	// ─── Command output (CO) ─────────────────────────────────────
	case tlv.TagCmdOutput:
		s.handleCmdOutputFrame(h, rawValue)
	// ─── System message (SM) ─────────────────────────────────────
	case tlv.TagSystemMsg:
		return s.handleSMFrame(h, cache, rawValue)
	// ─── Everything else (unknown) ───────────────────────────────
	default:
		s.emitFrame(h, tag, rawValue, rawJSON(rawValue), &rawValue, nil, nil)
	}
	return false
}

// rawJSON returns v as a JSON message when it is valid JSON, else nil.
func rawJSON(v string) json.RawMessage {
	if json.Valid([]byte(v)) {
		return json.RawMessage(v)
	}
	return nil
}

// parseContentData parses a UX/AX/Ax body into its metadata + item.
func parseContentData(rawValue string) (tlv.ContentData, bool) {
	var d tlv.ContentData
	if err := json.Unmarshal([]byte(rawValue), &d); err != nil || d.Type == "" {
		return tlv.ContentData{}, false
	}
	return d, true
}

// handleAssistantDeltaFrame handles Ax streaming deltas: a JSON content item
// whose "type" says text or reasoning. Emitted as tlv-delta so the frontend
// accumulates by (type, history id).
func (s *Session) handleAssistantDeltaFrame(h *hub.Hub, rawValue string) {
	d, ok := parseContentData(rawValue)
	if !ok {
		// Malformed delta — forward the raw frame rather than dropping it.
		s.emitFrame(h, tlv.TagAssistantXDelta, rawValue, rawJSON(rawValue), &rawValue, nil, nil)
		return
	}
	h.Broadcast(hub.NewEvent("tlv-delta", DeltaEvent{
		SessionID:   s.ID,
		HistoryID:   d.ID,
		Content:     d.Text,
		Tag:         tlv.TagAssistantXDelta,
		ContentType: d.Type,
	}))
	// Intentionally NOT emitting tlv-frame here: Ax is a pure delta event; a
	// tlv-frame would cause a second dispatch in the frontend reducer.
}

// handleContentFrame handles complete content frames: AX (assistant text or
// reasoning) and UX (user echo). The content is the "text" field for text /
// reasoning items and the "uri" for media; the content type is the item's
// "type".
func (s *Session) handleContentFrame(h *hub.Hub, tag, rawValue string) {
	d, ok := parseContentData(rawValue)
	if !ok {
		s.emitFrame(h, tag, rawValue, rawJSON(rawValue), &rawValue, nil, nil)
		return
	}
	var content string
	if d.Type == "text" || d.Type == "reasoning" {
		content = d.Text
	} else {
		content = d.URI
	}
	var historyID *string
	if d.ID != "" {
		id := d.ID
		historyID = &id
	}
	ct := d.Type
	s.emitFrame(h, tag, rawValue, rawJSON(rawValue), &content, historyID, &ct)
}

// handleFunctionFrame handles AF/Af/UF/Uf JSON frames: parse the payload and
// forward it as `json`, extracting the history id from the top-level "id"
// (present on the authoritative frames; absent on the deltas).
func (s *Session) handleFunctionFrame(h *hub.Hub, tag, rawValue string) {
	var historyID *string
	var obj map[string]json.RawMessage
	if err := json.Unmarshal([]byte(rawValue), &obj); err == nil {
		if idRaw, ok := obj["id"]; ok {
			var id string
			if json.Unmarshal(idRaw, &id) == nil && id != "" {
				historyID = &id
			}
		}
	}
	s.emitFrame(h, tag, rawValue, rawJSON(rawValue), &rawValue, historyID, nil)
}

// handleCmdOutputFrame handles CO frames: inject the command name from
// the pending-commands registry into the JSON payload so the frontend
// can render the result without tracking call IDs itself.
func (s *Session) handleCmdOutputFrame(h *hub.Hub, rawValue string) {
	jsonVal := rawJSON(rawValue)
	var obj map[string]any
	if err := json.Unmarshal([]byte(rawValue), &obj); err == nil {
		if id, ok := obj["call_id"].(string); ok {
			if name, ok2 := s.PendingCmds.LoadAndDelete(id); ok2 {
				obj["name"] = name
			}
		}
		if b, err := json.Marshal(obj); err == nil {
			jsonVal = b
		}
	}
	s.emitFrame(h, "CO", rawValue, jsonVal, &rawValue, nil, nil)
}

// handleSMFrame handles SM system message frames: caches model_list and
// forwards the envelope as {type, data}. Returns true for the core's terminal
// frame (see endsTheSession).
func (s *Session) handleSMFrame(h *hub.Hub, cache *ModelCache, rawValue string) bool {
	var env tlv.SystemMsgEnvelope
	if err := json.Unmarshal([]byte(rawValue), &env); err != nil {
		s.emitFrame(h, "SM", rawValue, nil, &rawValue, nil, nil)
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
	s.emitFrame(h, "SM", rawValue, wrapped, &rawValue, nil, nil)
	return ended
}

// emitFrame builds and broadcasts a tlv-frame event. jsonVal, content,
// historyID and contentType are attached verbatim (each optional).
func (s *Session) emitFrame(h *hub.Hub, tag, rawValue string, jsonVal json.RawMessage, content, historyID, contentType *string) {
	h.Broadcast(hub.NewEvent("tlv-frame", FrameEvent{
		SessionID:   s.ID,
		Tag:         tag,
		RawValue:    rawValue,
		HistoryID:   historyID,
		Content:     content,
		JSON:        jsonVal,
		ContentType: contentType,
	}))
}
