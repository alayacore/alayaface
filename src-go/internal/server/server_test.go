package server

import (
	"net/http/httptest"
	"testing"
)

func TestCheckOrigin(t *testing.T) {
	s := New("../src-elm", "")
	upgrader := s.upgrader

	// Same origin as the request Host → allowed.
	req := httptest.NewRequest("GET", "/ws", nil)
	req.Host = "127.0.0.1:8765"
	req.Header.Set("Origin", "http://127.0.0.1:8765")
	if !upgrader.CheckOrigin(req) {
		t.Error("same-origin request should be allowed")
	}

	// Cross-origin (malicious website) → blocked.
	req.Header.Set("Origin", "https://evil.example.com")
	if upgrader.CheckOrigin(req) {
		t.Error("cross-origin request should be blocked")
	}

	// No Origin header (curl, local tools) → allowed.
	req2 := httptest.NewRequest("GET", "/ws", nil)
	req2.Host = "192.168.3.7:8765"
	if !upgrader.CheckOrigin(req2) {
		t.Error("request without Origin should be allowed")
	}

	// Malformed Origin → blocked.
	req3 := httptest.NewRequest("GET", "/ws", nil)
	req3.Host = "127.0.0.1:8765"
	req3.Header.Set("Origin", "://not-a-url")
	if upgrader.CheckOrigin(req3) {
		t.Error("malformed Origin should be blocked")
	}
}
