// Access policy for the HTTP surface (RPC + WebSocket + static client).
//
// The Go backend serves the Elm client AND the RPC/WS API from one origin,
// and out of the box it runs with no token (`make run-go`). Two attack
// classes follow, and both are the reason this file exists:
//
//  1. Drive-by CSRF. A POST to /rpc/<cmd> with Content-Type: text/plain is a
//     CORS "simple request": the browser sends it — with the attacker's body
//     — to any host *before* consulting CORS, and CORS only gates whether
//     the *response* is readable. The command still runs. Several commands
//     are destructive (fs_write_file_text, fs_delete_file,
//     delete_session_dir, create_session), so "the attacker can't read the
//     reply" is not a mitigation. This was verified against a running
//     server: a text/plain POST carrying `Origin: http://evil.example`
//     wrote a file and returned 200 OK.
//  2. DNS rebinding. The old WebSocket check compared the Origin header to
//     the request's Host — but under rebinding *both* are attacker
//     controlled (attacker.example resolving to 127.0.0.1), so the check
//     admitted a rebinding page to every live conversation. Verified: a
//     handshake with `Origin: http://evil.example:18777` /
//     `Host: evil.example:18777` got 101 Switching Protocols.
//
// What is enforced here:
//
//   - Host allowlist (optional, --allow-host): the real rebinding defense.
//     Applied to every request, including the static index — which matters
//     because with --token the index embeds the token, so whoever can make
//     the victim's browser load the page *as the app's origin* holds the
//     credential. Left empty by default because the documented LAN workflow
//     (bind 0.0.0.0, open http://<host>:8765) must keep working without
//     configuration; main.go warns when a no-token server is exposed.
//   - Sec-Fetch-Site: cross-site is rejected on /rpc and /ws. Modern
//     browsers send it on every request and a page cannot strip it, so this
//     catches the form-navigation / stripped-Origin cases.
//   - Origin (or, when absent, Referer) must be the request's own origin on
//     /rpc and /ws — same rule the WS path already applied, now also on RPC.
//   - POST /rpc must carry application/json *when the request came from a
//     browser*. The shipped client always does (transport.js sets it); this
//     is defense in depth against the "simple request" trick.
//
// Requests with no Origin, no Referer and no Sec-Fetch-Site are treated as
// native/CLI clients (curl, the Tauri-side tooling, tests) and are governed
// by the bearer token only — same-origin policy is a browser concept and
// refusing to guess one for non-browsers keeps the API scriptable.

package server

import (
	"net"
	"net/http"
	"net/url"
	"strings"
)

// hostPort splits a Host / Origin authority into its host and port, filling
// in the scheme's default port so "http://x" and "x:80" compare equal.
func hostPort(authority, scheme string) (host, port string) {
	authority = strings.TrimSpace(authority)
	if authority == "" {
		return "", ""
	}
	if u, err := url.Parse(authority); err == nil && u.Host != "" {
		if scheme == "" {
			scheme = u.Scheme
		}
		authority = u.Host
	}
	h, p, err := net.SplitHostPort(authority)
	if err != nil {
		// No port present (IPv6 literals keep their brackets).
		h, p = authority, ""
		if strings.HasPrefix(authority, "[") {
			h = strings.Trim(authority, "[]")
		}
	}
	if p == "" {
		switch strings.ToLower(scheme) {
		case "https", "wss":
			p = "443"
		default:
			p = "80"
		}
	}
	return strings.Trim(strings.ToLower(h), "."), p
}

// originOf returns the request's browser origin (Origin header, falling back
// to Referer) as an authority string, or "" when neither is present.
func originOf(r *http.Request) string {
	if o := strings.TrimSpace(r.Header.Get("Origin")); o != "" && o != "null" {
		return o
	}
	if ref := strings.TrimSpace(r.Header.Get("Referer")); ref != "" {
		if u, err := url.Parse(ref); err == nil && u.Host != "" {
			return u.Scheme + "://" + u.Host
		}
	}
	return ""
}

// isBrowser reports whether the request carries any browser provenance
// header. A non-browser client (curl, a native app, a test) sends none, and
// there is no same-origin concept to apply to it.
func isBrowser(r *http.Request) bool {
	return originOf(r) != "" || r.Header.Get("Sec-Fetch-Site") != ""
}

// splitEntry parses one allowlist entry. A bare host ("attacker.example")
// matches any port; an entry that carries one ("127.0.0.1:8765") must match
// the port exactly.
func splitEntry(entry string) (host, port string, portGiven bool) {
	entry = strings.TrimSpace(entry)
	h, p, err := net.SplitHostPort(entry)
	if err != nil {
		host, _ := hostPort(entry, "")
		return host, "", false
	}
	ph, pp := hostPort(h+":"+p, "")
	return ph, pp, true
}

// hostAllowed checks the Host header against the configured allowlist
// (empty list = any host, the pre-allowlist behavior).
func (s *Server) hostAllowed(r *http.Request) bool {
	if len(s.allowHosts) == 0 {
		return true
	}
	rh, rp := hostPort(r.Host, "")
	for _, a := range s.allowHosts {
		ah, ap, portGiven := splitEntry(a)
		if ah == "*" {
			return true
		}
		if ah != rh {
			continue
		}
		if !portGiven || ap == rp {
			return true
		}
	}
	return false
}

// checkAccess rejects cross-site browser requests on the API endpoints and
// enforces the Host allowlist everywhere. Returns an *rpcError so the status
// code reaches the client unchanged.
func (s *Server) checkAccess(r *http.Request) error {
	if !s.hostAllowed(r) {
		h, _ := hostPort(r.Host, "")
		return &rpcError{status: http.StatusForbidden, msg: "host not allowed: " + h}
	}

	api := strings.HasPrefix(r.URL.Path, "/rpc/") || r.URL.Path == "/ws"
	if !api || !isBrowser(r) {
		return nil
	}

	if strings.EqualFold(r.Header.Get("Sec-Fetch-Site"), "cross-site") {
		return &rpcError{status: http.StatusForbidden, msg: "cross-site request rejected"}
	}

	origin := originOf(r)
	if origin != "" {
		oh, op := hostPort(origin, "")
		rh, rp := hostPort(r.Host, "")
		if oh != rh || op != rp {
			return &rpcError{status: http.StatusForbidden, msg: "cross-origin request rejected"}
		}
	}

	// Defense in depth against the CORS "simple request" trick: a
	// browser-originated RPC must be a real JSON call (what transport.js
	// sends), not a text/plain form-style POST that no preflight gates.
	if r.Method == http.MethodPost &&
		!strings.HasPrefix(strings.ToLower(r.Header.Get("Content-Type")), "application/json") {
		return &rpcError{status: http.StatusUnsupportedMediaType, msg: "content-type must be application/json"}
	}

	return nil
}

// IsExposedAddr reports whether a listen address reaches beyond this machine
// (a wildcard bind or an explicit non-loopback host). Used only for the
// startup advisory in cmd/alayaface-server — the access policy itself never
// guesses what the operator meant to expose.
func IsExposedAddr(addr string) bool {
	host := addr
	if h, _, err := net.SplitHostPort(addr); err == nil {
		host = h
	}
	host = strings.Trim(strings.ToLower(host), "[]")
	switch host {
	case "", "*", "0.0.0.0", "::":
		return true
	case "localhost":
		return false
	}
	if strings.HasSuffix(host, ".localhost") {
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return true // a name we cannot prove is loopback
	}
	return !ip.IsLoopback()
}
