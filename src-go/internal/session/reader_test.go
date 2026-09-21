package session

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"alayaface/src-go/internal/core"
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
	return &Session{ID: "s1", PendingCmds: newPendingCmds()}, h, c
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
	s.disconnect(h, false, "Connection closed")

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
	s.disconnect(h, false, "again")
}

func TestDisconnectStaysQuietWhenTheTerminalFrameAlreadyAnnounced(t *testing.T) {
	// The normal v12 order: SM session/closed (announced), then the process
	// exits and the pipe EOFs. The second end must NOT reach the client — the
	// plan runner fails its node on every core-status:false it sees.
	s, h, c := newTestSession()
	s.setConnected(true)
	s.disconnect(h, true, "Connection closed")

	if s.Connected() {
		t.Error("the pipe is gone; connected must be cleared even when the end was already announced")
	}
	select {
	case raw := <-c.Chan():
		t.Fatalf("no second core-status expected, got %s", raw)
	case <-time.After(100 * time.Millisecond):
	}
}

func frame(tag, value string) *tlv.Frame {
	return &tlv.Frame{Tag: tag, Value: value}
}

// ─── The core's terminal frame (protocol v12: session state "closed") ──

func TestDispatchFrameReportsOnlyTheTerminalFrame(t *testing.T) {
	cases := []struct {
		name  string
		tag   string
		value string
		want  bool
	}{
		{"closed is terminal", "SM", `{"type":"session","data":{"state":"closed"}}`, true},
		{"ready is not", "SM", `{"type":"session","data":{"state":"ready"}}`, false},
		{"a startup state is not", "SM", `{"type":"session","data":{"state":"initializing"}}`, false},
		{"another type is not", "SM", `{"type":"error","data":{"state":"closed"}}`, false},
		{"no state is not", "SM", `{"type":"session","data":{}}`, false},
		{"malformed json is not", "SM", `not-json`, false},
		// The state travels in an SM envelope; the same words on another tag
		// are content, not a lifecycle signal.
		{"not on a non-SM tag", "UT", `{"type":"session","data":{"state":"closed"}}`, false},
	}
	for _, tc := range cases {
		s, h, _ := newTestSession()
		if got := s.dispatchFrame(h, NewModelCache(), frame(tc.tag, tc.value)); got != tc.want {
			t.Errorf("%s: dispatchFrame = %v, want %v", tc.name, got, tc.want)
		}
	}
}

func TestReaderAnnouncesTheEndAtTheTerminalFrame(t *testing.T) {
	// The frame is the session's last word, so the client learns the session
	// is over from it — even if the process then lingers with stdout held open
	// (a grandchild inheriting the pipe is the realistic case). The EOF that
	// follows must not produce a second announcement: the plan runner fails
	// its node on every core-status:false it receives.
	s, h, c := newTestSession()
	s.setConnected(true)

	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	s.Stdout = pr
	go s.startReader(h, NewModelCache())

	write := func(tag, value string) {
		t.Helper()
		if _, err := pw.Write(tlv.Encode(tag, value)); err != nil {
			t.Fatal(err)
		}
	}
	write("SM", `{"type":"session","data":{"state":"ready"}}`)
	write("AT", "\x007\x00the last reply")
	write("SM", `{"type":"session","data":{"state":"closed"}}`)

	var statuses []string
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) && len(statuses) == 0 {
		select {
		case raw := <-c.Chan():
			var ev hub.Event
			if json.Unmarshal(raw, &ev) == nil && ev.Type == "core-status" {
				statuses = append(statuses, decodePayload(t, ev)["message"].(string))
			}
		case <-time.After(50 * time.Millisecond):
		}
	}
	if len(statuses) != 1 {
		t.Fatalf("the terminal frame must announce the end once, got %v", statuses)
	}
	if statuses[0] != SessionClosedMessage {
		t.Errorf("message = %q, want %q", statuses[0], SessionClosedMessage)
	}
	if !s.Connected() {
		t.Error("the pipe is still open, so this backend's `connected` must stay true — close_session waits on it")
	}

	// Now let the process go: EOF arrives, the session ends, and nothing is
	// announced a second time.
	_ = pw.Close()
	deadline = time.Now().Add(2 * time.Second)
	for s.Connected() && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if s.Connected() {
		t.Fatal("EOF must clear `connected`")
	}
	select {
	case raw := <-c.Chan():
		var ev hub.Event
		if json.Unmarshal(raw, &ev) == nil && ev.Type == "core-status" {
			t.Errorf("EOF must not announce a second end: %s", raw)
		}
	case <-time.After(200 * time.Millisecond):
	}
}

// disconnectMessage: what a user is told when the pipe dies. The reason a core
// gives at startup exists only on stderr, and the client shows whichever
// backend it is talking to — so this text is shared with Rust's
// reader.rs::disconnect_message, and pinned the same way on both sides.

func TestDisconnectMessageKeepsThePlainTextWithoutAStderrTail(t *testing.T) {
	// The ordinary case: a session closed on purpose, nothing on stderr.
	// This must stay byte-identical to the pre-StderrTail text — the plan
	// runner quotes it in a node failure reason.
	if got := disconnectMessage("Connection closed", nil); got != "Connection closed" {
		t.Errorf("nil tail = %q, want the plain text", got)
	}
	if got := disconnectMessage("Connection closed", &core.StderrTail{}); got != "Connection closed" {
		t.Errorf("empty tail = %q, want the plain text", got)
	}
}

func TestDisconnectMessageQuotesTheLastStderrLine(t *testing.T) {
	// The real startup failure this exists for, verbatim from a v12 core
	// handed a v11 session file.
	tail := &core.StderrTail{}
	tail.Push("Warning: something earlier")
	tail.Push("Error: failed to load session: session file version mismatch: got 11, expected 12")
	msg := disconnectMessage("Connection closed", tail)
	if !strings.Contains(msg, "session file version mismatch: got 11, expected 12") {
		t.Errorf("the reason must reach the user: %q", msg)
	}
	if strings.Contains(msg, "something earlier") {
		t.Errorf("only the last line goes in the one-line status: %q", msg)
	}
	if !strings.Contains(msg, "(+1 more stderr lines in the backend log)") {
		t.Errorf("the user must be told where the rest is: %q", msg)
	}
}

func TestDisconnectMessageQuotesOneLineWithoutTheCounter(t *testing.T) {
	tail := &core.StderrTail{}
	tail.Push("boom")
	if got := disconnectMessage("Connection closed", tail); got != "Connection closed: boom" {
		t.Errorf("got %q", got)
	}
}

func TestDisconnectMessageClipsALongLineWithoutSplittingACharacter(t *testing.T) {
	// The core prints paths, which can carry multi-byte characters; the limit
	// is counted in runes in both backends so neither cuts one in half.
	long := strings.Repeat("é", core.StderrTailMaxChars+200)
	tail := &core.StderrTail{}
	tail.Push(long)
	msg := disconnectMessage("Connection closed", tail)
	want := len([]rune("Connection closed: ")) + core.StderrTailMaxChars
	if got := len([]rune(msg)); got != want {
		t.Errorf("clipping is counted in characters: got %d runes, want %d", got, want)
	}
}
