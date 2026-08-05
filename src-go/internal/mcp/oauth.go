// Package mcp implements the MCP OAuth callback flow.
//
// Starts a local callback server on 127.0.0.1:0, fills the auth URL with
// redirect URI and state, optionally opens the browser, and processes the
// callback with a 5-minute timeout. Port of mcp.rs start_mcp_auth_inner.
package mcp

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"log"
	"net"
	"net/http"
	"net/url"
	"os/exec"
	"runtime"
	"strings"
	"time"
)

// Result carries the outcome of an OAuth callback.
type Result struct {
	// Code is the authorization code, or nil on failure/timeout.
	Code *string
	// RedirectURI is the callback URI (needed for mcp_confirm).
	RedirectURI string
}

// StartAuthFlow starts the OAuth flow: launches a callback server on
// 127.0.0.1:0, fills the URL, optionally opens the browser, and invokes
// onResult when the callback arrives (or after a 5-minute timeout).
// Returns the filled URL.
func StartAuthFlow(serverName, authURL string, openBrowser bool, onResult func(Result)) (string, error) {
	state, err := randomState()
	if err != nil {
		return "", err
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", fmt.Errorf("failed to bind callback server: %w", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	redirectURI := fmt.Sprintf("http://127.0.0.1:%d/callback", port)

	// Fill the auth URL with redirect_uri and state.
	filledURL := strings.ReplaceAll(authURL, "{{redirect_uri}}", url.QueryEscape(redirectURI))
	filledURL = strings.ReplaceAll(filledURL, "{{state}}", state)

	log.Printf("[mcp_auth] Started OAuth flow for %s on port %d", serverName, port)
	log.Printf("[mcp_auth] Filled URL: %s", filledURL)

	if openBrowser {
		openBrowserURL(filledURL)
	}

	var srv *http.Server
	srv = &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		q := req.URL.Query()

		if errDesc := q.Get("error"); errDesc != "" {
			log.Printf("[mcp_auth] Auth error: %s", errDesc)
			writeCallbackPage(w, serverName, false)
			onResult(Result{Code: nil, RedirectURI: redirectURI})
			closeAfterFlush(w, srv)
			return
		}
		if q.Get("state") != state {
			log.Printf("[mcp_auth] State mismatch")
			writeCallbackPage(w, serverName, false)
			onResult(Result{Code: nil, RedirectURI: redirectURI})
			closeAfterFlush(w, srv)
			return
		}
		code := q.Get("code")
		if code != "" {
			log.Printf("[mcp_auth] Authorization code received")
			writeCallbackPage(w, serverName, true)
			onResult(Result{Code: &code, RedirectURI: redirectURI})
		} else {
			log.Printf("[mcp_auth] No authorization code in callback")
			writeCallbackPage(w, serverName, false)
			onResult(Result{Code: nil, RedirectURI: redirectURI})
		}
		closeAfterFlush(w, srv)
	})}

	done := make(chan struct{})
	go func() {
		_ = srv.Serve(ln)
		close(done)
	}()

	// Timeout: an abandoned flow (user never completes the browser
	// dance) must not leak the listener/goroutine.
	go func() {
		select {
		case <-done:
		case <-time.After(5 * time.Minute):
			log.Printf("[mcp_auth] Timed out waiting for callback, declining")
			onResult(Result{Code: nil, RedirectURI: redirectURI})
			_ = srv.Close()
		}
	}()

	return filledURL, nil
}

// closeAfterFlush flushes the response body to the browser, then closes
// the callback server shortly after so the client can finish reading.
func closeAfterFlush(w http.ResponseWriter, srv *http.Server) {
	if f, ok := w.(http.Flusher); ok {
		f.Flush()
	}
	go func() {
		time.Sleep(300 * time.Millisecond)
		_ = srv.Close()
	}()
}

// writeCallbackPage writes the HTML page shown after the OAuth callback.
func writeCallbackPage(w http.ResponseWriter, serverName string, success bool) {
	status := "Failed"
	if success {
		status = "Successful"
	}
	body := fmt.Sprintf(
		"<!DOCTYPE html><html><body style='display:flex;justify-content:center;align-items:center;height:100vh;font-family:sans-serif;'>"+
			"<div style='text-align:center;'><h2>Authorization %s</h2>"+
			"<p style='color:#666;'>Server: %s</p>"+
			"<p style='color:#666;'>You can close this window.</p></div></body></html>",
		status, htmlEscape(serverName),
	)
	w.Header().Set("Content-Type", "text/html")
	w.Header().Set("Connection", "close")
	_, _ = fmt.Fprint(w, body)
}

// htmlEscape is a minimal HTML escaper for config values shown in the
// callback page.
func htmlEscape(s string) string {
	r := strings.NewReplacer(
		"&", "&amp;",
		"<", "&lt;",
		">", "&gt;",
		"\"", "&quot;",
	)
	return r.Replace(s)
}

// randomState generates a 128-bit hex CSRF state.
func randomState() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// openBrowserURL opens a URL in the default browser.
func openBrowserURL(u string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "darwin":
		cmd = exec.Command("open", u)
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", u)
	default:
		cmd = exec.Command("xdg-open", u)
	}
	if err := cmd.Start(); err != nil {
		log.Printf("[mcp_auth] Failed to open browser: %v", err)
	}
}
