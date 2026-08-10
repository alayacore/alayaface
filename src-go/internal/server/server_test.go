package server

import (
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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

// TestTokenInjectedIntoIndex verifies the --token mode reaches the
// client: the served index document carries the token in a meta tag
// (bridge.js reads it and attaches it to RPC/WS), while other assets
// are served untouched and a token-less server injects nothing.
func TestTokenInjectedIntoIndex(t *testing.T) {
	dir := t.TempDir()
	index := "<!DOCTYPE html><html><head><title>alayaface</title></head><body></body></html>"
	if err := os.WriteFile(filepath.Join(dir, "index.html"), []byte(index), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "app.js"), []byte("console.log(1)"), 0o644); err != nil {
		t.Fatal(err)
	}

	// With a token: index.html carries the meta tag, app.js does not.
	withToken := New(dir, "secret-token")
	tok := httptest.NewRequest("GET", "/", nil)
	tokRec := httptest.NewRecorder()
	withToken.Routes().ServeHTTP(tokRec, tok)
	if got := tokRec.Body.String(); !strings.Contains(got, `<meta name="alayaface-token" content="secret-token">`) {
		t.Errorf("index with token: meta tag not injected, body: %s", got)
	}
	if tokRec.Header().Get("Content-Type") != "text/html; charset=utf-8" {
		t.Errorf("index with token: Content-Type = %q", tokRec.Header().Get("Content-Type"))
	}

	// /index.html gets the tag too (direct URL).
	idx := httptest.NewRequest("GET", "/index.html", nil)
	idxRec := httptest.NewRecorder()
	withToken.Routes().ServeHTTP(idxRec, idx)
	if got := idxRec.Body.String(); !strings.Contains(got, "alayaface-token") {
		t.Errorf("/index.html with token: meta tag not injected: %s", got)
	}

	// Other assets are served verbatim (no injection, correct bytes).
	js := httptest.NewRequest("GET", "/app.js", nil)
	jsRec := httptest.NewRecorder()
	withToken.Routes().ServeHTTP(jsRec, js)
	if got := jsRec.Body.String(); got != "console.log(1)" || strings.Contains(got, "alayaface-token") {
		t.Errorf("app.js must be served untouched, got: %q", got)
	}

	// No token configured → index served without the meta tag.
	noToken := New(dir, "")
	plain := httptest.NewRequest("GET", "/", nil)
	plainRec := httptest.NewRecorder()
	noToken.Routes().ServeHTTP(plainRec, plain)
	if got := plainRec.Body.String(); strings.Contains(got, "alayaface-token") {
		t.Errorf("index without token must not carry the meta tag: %s", got)
	}

	// The tag must not leak the raw token when it needs HTML escaping.
	weird := New(dir, `a<b"c`)
	esc := httptest.NewRequest("GET", "/", nil)
	escRec := httptest.NewRecorder()
	weird.Routes().ServeHTTP(escRec, esc)
	if got := escRec.Body.String(); strings.Contains(got, `content="a<b"c">`) {
		t.Errorf("token must be HTML-escaped in the meta tag: %s", got)
	}
	if got := escRec.Body.String(); !strings.Contains(got, "a&lt;b&#34;c") {
		t.Errorf("token not escaped: %s", got)
	}
}

// TestServesIndex confirms the path guard: only the index document gets
// the token tag, never sub-paths or missing files.
func TestServesIndex(t *testing.T) {
	cases := map[string]bool{
		"/":           true,
		"":            true,
		"/index.html": true,
		"/app.js":     false,
		"/src/foo":    false,
	}
	for path, want := range cases {
		if got := servesIndex(path); got != want {
			t.Errorf("servesIndex(%q) = %v, want %v", path, got, want)
		}
	}
}
