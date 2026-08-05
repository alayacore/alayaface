package mcp

import (
	"net/http"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// startAuth starts a flow with a callback that records invocations and
// returns the filled URL plus the local callback base (http://127.0.0.1:PORT).
func startAuth(t *testing.T) (filledURL, callbackBase string, calls *atomic.Int32) {
	t.Helper()
	calls = &atomic.Int32{}
	u, err := StartAuthFlow("test-server", "https://example.com/auth?redirect={{redirect_uri}}&state={{state}}", false, func(Result) {
		calls.Add(1)
	})
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := url.Parse(u)
	if err != nil {
		t.Fatal(err)
	}
	redirect, err := url.QueryUnescape(parsed.Query().Get("redirect"))
	if err != nil {
		t.Fatal(err)
	}
	callbackBase = strings.TrimSuffix(redirect, "/callback")
	return u, callbackBase, calls
}

// hit sends one HTTP GET to the local callback. mustSucceed requires the
// request to be accepted; later requests may arrive after the callback
// server has closed.
func hit(t *testing.T, callbackURL string, mustSucceed bool) {
	t.Helper()
	client := &http.Client{
		Timeout:   3 * time.Second,
		Transport: &http.Transport{Proxy: nil}, // never go through env proxy
	}
	resp, err := client.Get(callbackURL)
	if err != nil {
		if mustSucceed {
			t.Fatalf("GET %s: %v", callbackURL, err)
		}
		return
	}
	_ = resp.Body.Close()
}

func stateOf(t *testing.T, filledURL string) string {
	t.Helper()
	u, err := url.Parse(filledURL)
	if err != nil {
		t.Fatal(err)
	}
	return u.Query().Get("state")
}

// TestCallbackHandledOnce: stray requests (browser retries, favicon)
// must not trigger onResult a second time.
func TestCallbackHandledOnce(t *testing.T) {
	_, cb, calls := startAuth(t)
	hit(t, cb+"/callback?code=abc123", true)
	hit(t, cb+"/callback?code=abc123", false)
	hit(t, cb+"/favicon.ico", false)
	time.Sleep(200 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("onResult called %d times, want exactly 1", got)
	}
}

// TestCallbackStateMismatchDeclines: a tampered state must produce a
// single decline callback.
func TestCallbackStateMismatchDeclines(t *testing.T) {
	_, cb, calls := startAuth(t)
	hit(t, cb+"/callback?state=attacker-controlled&code=abc123", true)
	time.Sleep(200 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("onResult called %d times, want 1 (decline)", got)
	}
}

// TestCallbackSuccessPath: matching state + code → single confirm.
func TestCallbackSuccessPath(t *testing.T) {
	url, cb, calls := startAuth(t)
	hit(t, cb+"/callback?state="+stateOf(t, url)+"&code=abc123", true)
	time.Sleep(200 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("onResult called %d times, want 1 (confirm)", got)
	}
}

// TestCallbackErrorParamDeclines: an error param must produce a single
// decline callback.
func TestCallbackErrorParamDeclines(t *testing.T) {
	url, cb, calls := startAuth(t)
	hit(t, cb+"/callback?state="+stateOf(t, url)+"&error=access_denied&error_description=user%20said%20no", true)
	time.Sleep(200 * time.Millisecond)
	if got := calls.Load(); got != 1 {
		t.Fatalf("onResult called %d times, want 1 (decline)", got)
	}
}
