package session

import (
	"encoding/json"
	"testing"
	"time"

	"alayaface/src-go/internal/hub"
	"alayaface/src-go/internal/tlv"
)

// Unit tests for the stdout reader's dispatch logic (reader.go).
// These pin the exact event shapes and null semantics that the Elm
// decoders depend on (see docs/go-backend.md §4).

// newTestSession builds a session + hub with one registered client.
func newTestSession() (*Session, *hub.Hub, *hub.Client) {
	h := hub.New()
	c := h.NewClient()
	h.Register(c)
	return &Session{ID: "s1"}, h, c
}

// nextEvent reads one event from the client channel, decoding it.
func nextEvent(t *testing.T, c *hub.Client) hub.Event {
	t.Helper()
	select {
	case raw := <-c.Chan():
		var ev hub.Event
		if err := json.Unmarshal(raw, &ev); err != nil {
			t.Fatalf("bad event json: %v", raw)
		}
		return ev
	case <-time.After(2 * time.Second):
		t.Fatal("no event arrived")
		return hub.Event{}
	}
}

// assertNoEvent asserts the client channel is currently empty.
func assertNoEvent(t *testing.T, c *hub.Client) {
	t.Helper()
	select {
	case raw := <-c.Chan():
		t.Fatalf("unexpected event: %s", raw)
	default:
	}
}

func decodePayload(t *testing.T, ev hub.Event) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(ev.Payload, &m); err != nil {
		t.Fatalf("bad payload: %v", ev.Payload)
	}
	return m
}

// ─── Delta frames (At/Ar) ───────────────────────────────────────────

func TestDispatchAtDelta(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("At", "\x00h1\x00hello"))

	ev := nextEvent(t, c)
	if ev.Type != "tlv-delta" {
		t.Fatalf("type = %s, want tlv-delta", ev.Type)
	}
	m := decodePayload(t, ev)
	if m["session_id"] != "s1" || m["history_id"] != "h1" || m["content"] != "hello" || m["tag"] != "At" {
		t.Errorf("delta payload = %v", m)
	}
	// At must NEVER emit a tlv-frame (double dispatch).
	assertNoEvent(t, c)
}

func TestDispatchAtMalformed(t *testing.T) {
	// No NUL prefix → not a valid delta → raw tlv-frame fallback.
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("At", "no-prefix"))

	ev := nextEvent(t, c)
	if ev.Type != "tlv-frame" {
		t.Fatalf("type = %s, want tlv-frame", ev.Type)
	}
	m := decodePayload(t, ev)
	if m["tag"] != "At" || m["content"] != "no-prefix" || m["history_id"] != nil || m["json"] != nil {
		t.Errorf("malformed delta payload = %v", m)
	}
	assertNoEvent(t, c)
}

// ─── Complete frames (AT/AR): empty → content null ──────────────────

func TestDispatchATEmpty(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("AT", "\x00h1\x00"))

	ev := nextEvent(t, c)
	if ev.Type != "tlv-frame" {
		t.Fatalf("type = %s, want tlv-frame", ev.Type)
	}
	m := decodePayload(t, ev)
	if m["tag"] != "AT" || m["content"] != nil {
		t.Errorf("AT payload = %v, want content null", m)
	}
	if m["history_id"] != "h1" {
		t.Errorf("AT history_id = %v", m["history_id"])
	}
}

// ─── JSON frames (Af/AF/UF/Uf) ──────────────────────────────────────

func TestDispatchAFJSON(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("AF", "\x00h1\x00{\"id\":\"t1\",\"name\":\"read\"}"))

	ev := nextEvent(t, c)
	m := decodePayload(t, ev)
	js, ok := m["json"].(map[string]any)
	if !ok {
		t.Fatalf("AF json = %v, want object", m["json"])
	}
	if js["id"] != "t1" || js["name"] != "read" {
		t.Errorf("AF json = %v", js)
	}
	if m["content"] != "{\"id\":\"t1\",\"name\":\"read\"}" {
		t.Errorf("AF content = %v", m["content"])
	}
}

func TestDispatchUFInvalidJSON(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("UF", "\x00h1\x00this-is-not-json"))

	m := decodePayload(t, nextEvent(t, c))
	if m["json"] != nil {
		t.Errorf("UF invalid json = %v, want null", m["json"])
	}
}

// ─── CO: command-name injection from PendingCmds ────────────────────

func TestDispatchCOInjection(t *testing.T) {
	s, h, c := newTestSession()
	s.PendingCmds.Store("call-1", "model_set")
	s.dispatchFrame(h, NewModelCache(), frame("CO", `{"id":"call-1","output":{"ok":true},"is_error":false}`))

	m := decodePayload(t, nextEvent(t, c))
	js := m["json"].(map[string]any)
	if js["name"] != "model_set" {
		t.Errorf("CO json.name = %v, want model_set (injected)", js["name"])
	}
	// The pending entry must be consumed.
	if _, ok := s.PendingCmds.Load("call-1"); ok {
		t.Error("pending cmd not deleted after CO")
	}
}

func TestDispatchCOUnknownID(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("CO", `{"id":"nobody","output":{},"is_error":false}`))

	m := decodePayload(t, nextEvent(t, c))
	js := m["json"].(map[string]any)
	if _, has := js["name"]; has {
		t.Errorf("CO unknown id got injected name: %v", js)
	}
}

// ─── SM: envelope wrap + model_list cache ───────────────────────────

func TestDispatchSMWrap(t *testing.T) {
	s, h, c := newTestSession()
	cache := NewModelCache()
	s.dispatchFrame(h, cache, frame("SM", `{"type":"task","data":{"id":"boot"}}`))

	m := decodePayload(t, nextEvent(t, c))
	js := m["json"].(map[string]any)
	if js["type"] != "task" {
		t.Errorf("SM json = %v, want {type,data} wrapper", js)
	}
	if !cache.IsEmpty() {
		t.Error("non-model_list SM must not touch the cache")
	}
}

func TestDispatchSMModelListCaches(t *testing.T) {
	s, h, c := newTestSession()
	cache := NewModelCache()
	s.dispatchFrame(h, cache, frame("SM", `{"type":"model_list","data":{"models":[{"id":1,"name":"m1"}]}}`))

	m := decodePayload(t, nextEvent(t, c))
	js := m["json"].(map[string]any)
	if js["type"] != "model_list" {
		t.Errorf("SM json type = %v", js["type"])
	}
	models := cache.Get()
	if len(models) != 1 {
		t.Fatalf("cache len = %d, want 1", len(models))
	}
	var first map[string]any
	if err := json.Unmarshal(models[0], &first); err != nil || first["name"] != "m1" {
		t.Errorf("cached model = %s", models[0])
	}
}

func TestDispatchSMInvalid(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("SM", "not-json"))

	m := decodePayload(t, nextEvent(t, c))
	if m["json"] != nil {
		t.Errorf("SM invalid json = %v, want null", m["json"])
	}
}

// ─── User echoes: user_content_type ─────────────────────────────────

func TestDispatchUserEcho(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("UT", "\x00h1\x00hi"))

	m := decodePayload(t, nextEvent(t, c))
	if m["user_content_type"] != "UT" || m["content"] != "hi" {
		t.Errorf("echo payload = %v", m)
	}
}

func TestDispatchNonEchoTag(t *testing.T) {
	s, h, c := newTestSession()
	s.dispatchFrame(h, NewModelCache(), frame("XX", "odd"))

	m := decodePayload(t, nextEvent(t, c))
	if m["user_content_type"] != nil || m["content"] != "odd" {
		t.Errorf("unknown tag payload = %v", m)
	}
}

// ─── Disconnect: state + status event, killOnce nil-safe ────────────

func TestDisconnect(t *testing.T) {
	// Child is nil on purpose: disconnect → kill() must not panic.
	s, h, c := newTestSession()
	s.setConnected(true)
	s.disconnect(h, "Connection closed")

	if s.Connected() {
		t.Error("session still marked connected")
	}
	ev := nextEvent(t, c)
	if ev.Type != "core-status" {
		t.Fatalf("type = %s, want core-status", ev.Type)
	}
	m := decodePayload(t, ev)
	if m["session_id"] != "s1" || m["connected"] != false || m["message"] != "Connection closed" {
		t.Errorf("status payload = %v", m)
	}
	// Calling disconnect again must not panic and emits again (the
	// reader only calls it once, but be safe).
	s.disconnect(h, "again")
}

func frame(tag, value string) *tlv.Frame {
	return &tlv.Frame{Tag: tag, Value: value}
}
