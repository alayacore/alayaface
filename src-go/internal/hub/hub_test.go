package hub

import (
	"encoding/json"
	"testing"
	"time"
)

// next reads one broadcast message from a client.
func next(t *testing.T, c *Client) Event {
	t.Helper()
	select {
	case raw := <-c.Chan():
		var ev Event
		if err := json.Unmarshal(raw, &ev); err != nil {
			t.Fatalf("bad event: %s", raw)
		}
		return ev
	case <-time.After(2 * time.Second):
		t.Fatal("no broadcast arrived")
		return Event{}
	}
}

func TestBroadcast(t *testing.T) {
	h := New()
	c := h.NewClient()
	h.Register(c)
	if h.Len() != 1 {
		t.Fatalf("Len = %d, want 1", h.Len())
	}

	h.Broadcast(NewEvent("tlv-frame", map[string]any{"tag": "AT"}))
	ev := next(t, c)
	if ev.Type != "tlv-frame" {
		t.Errorf("type = %s", ev.Type)
	}
	var payload map[string]any
	if err := json.Unmarshal(ev.Payload, &payload); err != nil || payload["tag"] != "AT" {
		t.Errorf("payload = %s", ev.Payload)
	}
}

func TestUnregisterClosesChannel(t *testing.T) {
	h := New()
	c := h.NewClient()
	h.Register(c)
	h.Unregister(c)

	select {
	case _, ok := <-c.Chan():
		if ok {
			t.Error("channel should be closed after Unregister")
		}
	default:
		t.Error("expected channel to be closed")
	}
	if h.Len() != 0 {
		t.Errorf("Len = %d, want 0", h.Len())
	}
	// Unregister twice must be safe (no double close).
	h.Unregister(c)
}

func TestSlowClientDropped(t *testing.T) {
	h := New()
	c := h.NewClient()
	h.Register(c)

	// Never drain the client; the hub must drop it once its buffer
	// (64 messages) fills, without blocking Broadcast.
	for i := 0; i < 200; i++ {
		h.Broadcast(NewEvent("x", map[string]any{"i": i}))
	}
	if h.Len() != 0 {
		t.Errorf("slow client not dropped: Len = %d", h.Len())
	}
	// The dropped client's channel is closed; drain the buffered
	// messages until the closed state is visible.
	closed := false
	for i := 0; i < 200; i++ {
		if _, ok := <-c.Chan(); !ok {
			closed = true
			break
		}
	}
	if !closed {
		t.Error("dropped client channel should be closed")
	}

	// Remaining clients still receive broadcasts.
	c2 := h.NewClient()
	h.Register(c2)
	h.Broadcast(NewEvent("y", map[string]any{"ok": true}))
	if ev := next(t, c2); ev.Type != "y" {
		t.Errorf("surviving client got type %s", ev.Type)
	}
}

func TestBroadcastNoClients(t *testing.T) {
	h := New()
	h.Broadcast(NewEvent("z", map[string]any{})) // must not panic
}
