package server

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"alayaface/src-go/internal/server/handlers"
)

// TestRPCPanicReturns500: a handler panic must be recovered into a 500
// {"error": "internal error"} JSON response — not an aborted connection
// (net/http's default behavior) and not a crashed server.
func TestRPCPanicReturns500(t *testing.T) {
	s := New("", "")
	rpcHandlers["__test_panic__"] = func(h *handlers.Handler, w http.ResponseWriter, r *http.Request) error {
		panic("boom")
	}
	defer delete(rpcHandlers, "__test_panic__")

	ts := httptest.NewServer(s.Routes())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/rpc/__test_panic__", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("status = %d, want 500", resp.StatusCode)
	}
	var body struct {
		Error string `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Error != "internal error" {
		t.Fatalf("error = %q, want 'internal error'", body.Error)
	}
}

// TestRPCPanicAfterWriteKeepsFirstResponse: a panic AFTER the handler
// already wrote a response must not emit a second (superfluous) error
// body — the client receives the first response as-is.
func TestRPCPanicAfterWriteKeepsFirstResponse(t *testing.T) {
	s := New("", "")
	rpcHandlers["__test_panic_after__"] = func(h *handlers.Handler, w http.ResponseWriter, r *http.Request) error {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "partial")
		panic("boom")
	}
	defer delete(rpcHandlers, "__test_panic_after__")

	ts := httptest.NewServer(s.Routes())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/rpc/__test_panic_after__", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (first write wins)", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "partial" {
		t.Fatalf("body = %q, want 'partial'", b)
	}
}

// TestRPCErrorAfterWriteKeepsFirstResponse: a handler that writes a
// response and THEN returns an error must not append a second JSON
// error body — the client receives the handler's response as-is (the
// error path mirrors the panic path's first-write-wins rule).
func TestRPCErrorAfterWriteKeepsFirstResponse(t *testing.T) {
	s := New("", "")
	rpcHandlers["__test_err_after__"] = func(h *handlers.Handler, w http.ResponseWriter, r *http.Request) error {
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "done")
		return &rpcError{status: http.StatusInternalServerError, msg: "late failure"}
	}
	defer delete(rpcHandlers, "__test_err_after__")

	ts := httptest.NewServer(s.Routes())
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/rpc/__test_err_after__", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200 (first write wins)", resp.StatusCode)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "done" {
		t.Fatalf("body = %q, want 'done' (no error body appended)", b)
	}
}
