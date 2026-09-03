package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Regression tests for the access policy in authz.go. The cases mirror the
// two attacks that were verified against a running server before the fix:
// a CORS-"simple" cross-origin POST that wrote a file, and a DNS-rebinding
// WebSocket handshake that got 101 Switching Protocols.

func post(t *testing.T, s *Server, target, host, origin, contentType, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, target, strings.NewReader(body))
	req.Host = host
	if origin != "" {
		req.Header.Set("Origin", origin)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	rec := httptest.NewRecorder()
	s.Routes().ServeHTTP(rec, req)
	return rec
}

// TestRPCDriveByWriteRefused is the headline CSRF case: a page on another
// origin POSTs a *simple* request (text/plain, so the browser sends it
// without a preflight) to fs_write_file_text. Before the policy this
// returned 200 and wrote the file.
func TestRPCDriveByWriteRefused(t *testing.T) {
	s := New("", "")
	dir := t.TempDir()
	victim := filepath.Join(dir, "PWNED.txt")
	body, _ := json.Marshal(map[string]any{"path": victim, "content": "written by a cross-origin simple request"})

	rec := post(t, s, "/rpc/fs_write_file_text", "127.0.0.1:8765", "http://evil.example", "text/plain", string(body))

	if rec.Code == http.StatusOK {
		t.Fatalf("cross-origin simple request executed the command (200 OK)")
	}
	if _, err := os.Stat(victim); err == nil {
		t.Fatalf("fs_write_file_text wrote through a cross-origin request: %s", victim)
	}
	if rec.Code != http.StatusForbidden && rec.Code != http.StatusUnsupportedMediaType {
		t.Fatalf("status = %d, want 403 or 415 (body %s)", rec.Code, rec.Body.String())
	}
}

// A same-origin browser call must keep working, and so must a native/CLI
// client that sends no browser provenance at all (curl, tests, scripts):
// same-origin is a browser concept, and the bearer token still gates those.
func TestRPCSameOriginAndNativeStillWork(t *testing.T) {
	s := New("", "")
	dir := t.TempDir()
	target := filepath.Join(dir, "ok.txt")
	body, _ := json.Marshal(map[string]any{"path": target, "content": "hello"})

	if rec := post(t, s, "/rpc/fs_write_file_text", "127.0.0.1:8765", "http://127.0.0.1:8765", "application/json", string(body)); rec.Code != http.StatusOK {
		t.Fatalf("same-origin JSON call rejected: %d %s", rec.Code, rec.Body.String())
	}
	if rec := post(t, s, "/rpc/fs_home_dir", "127.0.0.1:8765", "", "", "{}"); rec.Code != http.StatusOK {
		t.Fatalf("native (no Origin) call rejected: %d %s", rec.Code, rec.Body.String())
	}
	// Default port equivalence: the browser sends "http://host" without the
	// :80 it implies, and Host carries no port either.
	if rec := post(t, s, "/rpc/fs_home_dir", "mybox.local", "http://mybox.local", "application/json", "{}"); rec.Code != http.StatusOK {
		t.Fatalf("default-port same-origin call rejected: %d %s", rec.Code, rec.Body.String())
	}
}

// Modern browsers always send Sec-Fetch-Site and a page cannot strip it, so
// it catches what a spoofed/absent Origin would not.
func TestRPCCrossSiteSecFetchRefused(t *testing.T) {
	s := New("", "")
	req := httptest.NewRequest(http.MethodPost, "/rpc/fs_home_dir", strings.NewReader("{}"))
	req.Host = "127.0.0.1:8765"
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	s.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("cross-site Sec-Fetch-Site accepted: %d", rec.Code)
	}
}

// A Referer-only cross-site request (no Origin) is still refused.
func TestRPCRefererFallbackRefused(t *testing.T) {
	s := New("", "")
	req := httptest.NewRequest(http.MethodPost, "/rpc/fs_home_dir", strings.NewReader("{}"))
	req.Host = "127.0.0.1:8765"
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Referer", "http://evil.example/launch.html")
	rec := httptest.NewRecorder()
	s.Routes().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatalf("cross-site Referer accepted: %d", rec.Code)
	}
}

// The Host allowlist is the DNS-rebinding defense: Origin and Host agree
// there, so only an explicit allowlist stops it. Applied to the static
// index too, because with --token the index embeds the token.
func TestHostAllowlist(t *testing.T) {
	cases := []struct {
		name     string
		hosts    []string
		reqHost  string
		wantOK   bool
		endpoint string
	}{
		{"rebound host refused", []string{"localhost:8765"}, "attacker.example:8765", false, "/rpc/fs_home_dir"},
		{"allowlisted host served", []string{"localhost:8765", "attacker.example:8765"}, "attacker.example:8765", true, "/rpc/fs_home_dir"},
		{"bare entry matches any port", []string{"attacker.example"}, "attacker.example:8765", true, "/rpc/fs_home_dir"},
		{"wrong port refused", []string{"attacker.example:1"}, "attacker.example:8765", false, "/rpc/fs_home_dir"},
		{"static index is gated too", []string{"localhost:8765"}, "attacker.example:8765", false, "/"},
		{"wildcard disables the check", []string{"*"}, "attacker.example:8765", true, "/rpc/fs_home_dir"},
		{"unset allowlist allows any host", nil, "attacker.example:8765", true, "/rpc/fs_home_dir"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := New("", "", WithAllowedHosts(tc.hosts))
			rec := post(t, s, tc.endpoint, tc.reqHost, "", "application/json", "{}")
			if got := rec.Code == http.StatusOK; got != tc.wantOK {
				t.Fatalf("status %d (ok=%v), want ok=%v: %s", rec.Code, got, tc.wantOK, rec.Body.String())
			}
		})
	}
}

// /ws goes through the same policy: a cross-site subscription is refused
// before the upgrade (the rebinding variant is covered by the allowlist test
// above, since Origin/Host agree there by construction).
func TestWSCrossSiteRefused(t *testing.T) {
	s := New("", "")
	req := httptest.NewRequest(http.MethodGet, "/ws", nil)
	req.Host = "127.0.0.1:8765"
	req.Header.Set("Origin", "http://evil.example")
	req.Header.Set("Sec-Fetch-Site", "cross-site")
	rec := httptest.NewRecorder()
	s.Routes().ServeHTTP(rec, req)
	if rec.Code == http.StatusSwitchingProtocols {
		t.Fatal("cross-site WS request was upgraded")
	}
	if rec.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", rec.Code)
	}
}

func TestHostPortDefaults(t *testing.T) {
	cases := []struct{ in, scheme, host, port string }{
		{"127.0.0.1:8765", "http", "127.0.0.1", "8765"},
		{"http://127.0.0.1:8765", "", "127.0.0.1", "8765"},
		{"http://evil.example", "", "evil.example", "80"},
		{"https://evil.example", "", "evil.example", "443"},
		{"evil.example", "http", "evil.example", "80"},
		{"[::1]:8765", "", "::1", "8765"},
		{"LocalHost.", "", "localhost", "80"},
	}
	for _, tc := range cases {
		h, p := hostPort(tc.in, tc.scheme)
		if h != tc.host || p != tc.port {
			t.Errorf("hostPort(%q, %q) = (%q, %q), want (%q, %q)", tc.in, tc.scheme, h, p, tc.host, tc.port)
		}
	}
}

func TestIsExposedAddr(t *testing.T) {
	cases := map[string]bool{
		"127.0.0.1:8765": false,
		"[::1]:8765":     false,
		"localhost:8765": false,
		":8765":          true,
		"0.0.0.0:8765":   true,
		"[::]:8765":      true,
		"192.168.1.5:99": true,
		"myhost:8765":    true, // a name we cannot prove is loopback
	}
	for addr, want := range cases {
		if got := IsExposedAddr(addr); got != want {
			t.Errorf("IsExposedAddr(%q) = %v, want %v", addr, got, want)
		}
	}
}
