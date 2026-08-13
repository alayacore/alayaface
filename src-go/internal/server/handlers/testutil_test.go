package handlers

import (
	"bytes"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"alayaface/src-go/internal/dirs"
	"alayaface/src-go/internal/hub"
	"alayaface/src-go/internal/session"
)

// newTestHandler builds a Handler with fresh state.
func newTestHandler() *Handler {
	return &Handler{
		Sessions: session.NewManager(),
		Hub:      hub.New(),
		Cache:    session.NewModelCache(),
	}
}

// call invokes an RPC command with JSON args and returns the recorder.
func call(t *testing.T, fn Command, args any) *httptest.ResponseRecorder {
	t.Helper()
	body, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("POST", "/rpc/test", bytes.NewReader(body))
	rr := httptest.NewRecorder()
	if err := fn(newTestHandler(), rr, req); err != nil {
		t.Fatal(err)
	}
	return rr
}

// callErr invokes an RPC command expecting an error; returns the error.
func callErr(t *testing.T, fn Command, args any) error {
	t.Helper()
	body, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("POST", "/rpc/test", bytes.NewReader(body))
	rr := httptest.NewRecorder()
	return fn(newTestHandler(), rr, req)
}

// isolatedHome points HOME at a fresh temp dir for the duration of f.
// Tests that mutate HOME must go through this helper (no t.Parallel).
func isolatedHome(t *testing.T, f func()) {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	f()
}

// seedPresets runs dirs.Ensure() so the Simple/Complex seed presets
// exist under the isolated HOME (many handler tests need a real preset
// now that `preset` is a required argument).
func seedPresets(t *testing.T) {
	t.Helper()
	if _, err := dirs.Ensure(); err != nil {
		t.Fatal(err)
	}
}
