package server

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"alayaface/src-go/internal/dirs"
)

// ─── Fake alayacore binary ──────────────────────────────────────────
//
// internal/fakecore is a scriptable alayacore stand-in (TLV rawio).
// It is built once in TestMain; every test points ALAYACORE_BIN at it,
// so create/resume/fork/commands/probes all run against a real
// subprocess without needing a reachable model server.

var fakeCorePath string

func TestMain(m *testing.M) {
	tmp, err := os.MkdirTemp("", "alayaface-fakecore-*")
	if err != nil {
		panic(err)
	}
	fakeCorePath = filepath.Join(tmp, "fakecore")
	cmd := exec.Command("go", "build", "-o", fakeCorePath, "alayaface/src-go/internal/fakecore")
	cmd.Dir = "../.." // module root (tests run with CWD = package dir)
	if out, err := cmd.CombinedOutput(); err != nil {
		os.RemoveAll(tmp)
		panic("build fakecore: " + err.Error() + "\n" + string(out))
	}
	code := m.Run()
	os.RemoveAll(tmp)
	os.Exit(code)
}

// ─── Test environment ───────────────────────────────────────────────

type testEnv struct {
	t    *testing.T
	srv  *httptest.Server
	ws   *websocket.Conn
	base string
}

// newTestEnv starts a full backend (fresh HOME, fresh sessions) with a
// connected WS client. Token empty unless tokenArg is non-empty.
func newTestEnv(t *testing.T, tokenArg string) *testEnv {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("ALAYACORE_BIN", fakeCorePath)

	s := New("", tokenArg)
	ts := httptest.NewServer(s.Routes())
	t.Cleanup(ts.Close)

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"
	if tokenArg != "" {
		wsURL += "?token=" + tokenArg
	}
	ws, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		if resp != nil {
			t.Fatalf("ws dial failed (status %d): %v", resp.StatusCode, err)
		}
		t.Fatalf("ws dial failed: %v", err)
	}
	t.Cleanup(func() { _ = ws.Close() })

	return &testEnv{t: t, srv: ts, ws: ws, base: ts.URL}
}

// rpc invokes a command and returns the raw body + HTTP status.
func (e *testEnv) rpc(t *testing.T, cmd string, args any) ([]byte, int) {
	t.Helper()
	body, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	req, err := http.NewRequest("POST", e.base+"/rpc/"+cmd, bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	return data, resp.StatusCode
}

// rpcOK invokes a command expecting 200 and returns the body.
func (e *testEnv) rpcOK(t *testing.T, cmd string, args any) []byte {
	t.Helper()
	body, status := e.rpc(t, cmd, args)
	if status != http.StatusOK {
		t.Fatalf("%s: expected 200, got %d: %s", cmd, status, body)
	}
	return body
}

// rpcErr invokes a command expecting a non-2xx error and returns {"error"}.
func (e *testEnv) rpcErr(t *testing.T, cmd string, args any) string {
	t.Helper()
	body, status := e.rpc(t, cmd, args)
	if status >= 200 && status < 300 {
		t.Fatalf("%s: expected error status, got %d: %s", cmd, status, body)
	}
	var errBody struct {
		Error string `json:"error"`
	}
	if err := json.Unmarshal(body, &errBody); err != nil {
		t.Fatalf("%s: error body not JSON: %s", cmd, body)
	}
	return errBody.Error
}

// createSession runs create_session and returns the new session id.
func (e *testEnv) createSession(t *testing.T) string {
	t.Helper()
	body := e.rpcOK(t, "create_session", map[string]any{"binaryPath": "", "configPath": "", "toolConfirm": nil})
	var id string
	if err := json.Unmarshal(body, &id); err != nil {
		t.Fatalf("create_session: bad id body %q: %v", body, err)
	}
	return id
}

// waitEvent reads WS events until one of type typ matches pred (or a
// 6s deadline). Non-matching events are drained. Single read deadline:
// gorilla connections cannot be re-read after a read error, so a
// deadline hit fails the test (fine for deterministic fakecore tests).
func (e *testEnv) waitEvent(t *testing.T, typ string, pred func(payload map[string]any) bool) map[string]any {
	t.Helper()
	return e.collectUntil(t, typ, pred, nil)
}

// collectUntil reads WS events, calling collect (if given) for each,
// until an event of type typ matches pred. Returns the matching payload.
func (e *testEnv) collectUntil(t *testing.T, typ string, pred func(payload map[string]any) bool, collect func(typ string, payload map[string]any)) map[string]any {
	t.Helper()
	e.ws.SetReadDeadline(time.Now().Add(6 * time.Second))
	for {
		_, msg, err := e.ws.ReadMessage()
		if err != nil {
			t.Fatalf("ws read while waiting for %s: %v", typ, err)
		}
		var ev struct {
			Type    string         `json:"type"`
			Payload map[string]any `json:"payload"`
		}
		if err := json.Unmarshal(msg, &ev); err != nil {
			continue
		}
		if collect != nil {
			collect(ev.Type, ev.Payload)
		}
		if ev.Type == typ && (pred == nil || pred(ev.Payload)) {
			return ev.Payload
		}
	}
}

// ─── Conversation flow: create → prompt → stream → close ───────────

func TestIntegrationConversationFlow(t *testing.T) {
	e := newTestEnv(t, "")
	sid := e.createSession(t)

	// Session start: core-status connected, plus an SM task frame.
	status := e.waitEvent(t, "core-status", func(p map[string]any) bool {
		return p["session_id"] == sid && p["connected"] == true
	})
	if status["message"] == "" {
		t.Error("core-status connected message should be non-empty")
	}
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "SM" && js != nil && js["type"] == "task"
	})

	// Send a prompt.
	e.rpcOK(t, "alayacore_send_prompt", map[string]any{
		"sessionId": sid, "text": "hello", "media": []any{},
	})

	// User echo: tlv-frame with user_content_type set to the echo tag.
	echoPayload := e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		return p["tag"] == "UT" && p["user_content_type"] == "UT"
	})
	if echoPayload["content"] != "hello" {
		t.Errorf("echo content = %v, want hello", echoPayload["content"])
	}
	if echoPayload["history_id"] == nil {
		t.Error("echo should carry the NUL-prefixed history_id")
	}

	// Streaming deltas: collect everything until the AT terminator.
	// Expected order (fakecore replies Ar first, then At deltas, then
	// empty AT/AR terminators): Ar, At, At — as tlv-delta ONLY (never
	// tlv-frame for At/Ar).
	var deltas []string
	var badFrameTags []string
	at := e.collectUntil(t, "tlv-frame", func(p map[string]any) bool { return p["tag"] == "AT" }, func(typ string, p map[string]any) {
		tag, _ := p["tag"].(string)
		switch typ {
		case "tlv-delta":
			deltas = append(deltas, tag+":"+p["content"].(string))
		case "tlv-frame":
			if tag == "At" || tag == "Ar" {
				badFrameTags = append(badFrameTags, tag)
			}
		}
	})
	if len(badFrameTags) > 0 {
		t.Errorf("At/Ar must emit tlv-delta only, got tlv-frame for %v", badFrameTags)
	}
	want := []string{"Ar:Thinking about it...", "At:Hello", "At: world"}
	if strings.Join(deltas, "|") != strings.Join(want, "|") {
		t.Errorf("deltas = %v, want %v", deltas, want)
	}
	// AT terminator: tlv-frame with content null (empty payload).
	if at["content"] != nil {
		t.Errorf("AT content = %v, want null (empty terminator)", at["content"])
	}

	// AR terminator arrives after AT.
	ar := e.waitEvent(t, "tlv-frame", func(p map[string]any) bool { return p["tag"] == "AR" })
	if ar["content"] != nil {
		t.Errorf("AR content = %v, want null", ar["content"])
	}

	// Close: session killed, core-status disconnected, manager emptied.
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})
	e.waitEvent(t, "core-status", func(p map[string]any) bool {
		return p["session_id"] == sid && p["connected"] == false
	})
	if msg := e.rpcErr(t, "alayacore_send_prompt", map[string]any{"sessionId": sid, "text": "x"}); msg != "Session not found" {
		t.Errorf("send after close = %q, want 'Session not found'", msg)
	}
}

// ─── Command roundtrips: model_set / model_sync / confirm / mcp / cancel ─

func TestIntegrationCommandRoundtrips(t *testing.T) {
	e := newTestEnv(t, "")
	sid := e.createSession(t)

	// model_set: CO must carry the injected command name and echoed id.
	e.rpcOK(t, "alayacore_model_set", map[string]any{"sessionId": sid, "modelId": 7})
	co := e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "model_set"
	})
	js := co["json"].(map[string]any)
	if js["output"].(map[string]any)["modelId"] != "7" {
		t.Errorf("model_set output = %v, want modelId 7", js["output"])
	}

	// model_sync.
	e.rpcOK(t, "alayacore_model_sync", map[string]any{"sessionId": sid, "config": `{"name":"x"}`})
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "model_sync"
	})

	// tool_confirm (allowed=true → command name tool_confirm).
	e.rpcOK(t, "alayacore_confirm", map[string]any{"sessionId": sid, "id": "tool-1", "allowed": true})
	co2 := e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "tool_confirm"
	})
	out := co2["json"].(map[string]any)["output"].(map[string]any)
	if out["id"] != "tool-1" || out["allowed"] != true {
		t.Errorf("tool_confirm output = %v", out)
	}

	// tool_decline (allowed=false → command name tool_decline).
	e.rpcOK(t, "alayacore_confirm", map[string]any{"sessionId": sid, "id": "tool-2", "allowed": false})
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "tool_decline"
	})

	// mcp_decline + mcp_cancel.
	e.rpcOK(t, "alayacore_mcp_decline", map[string]any{"sessionId": sid, "server": "srv-a"})
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "mcp_decline"
	})
	e.rpcOK(t, "alayacore_mcp_cancel", map[string]any{"sessionId": sid})
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "mcp_cancel"
	})

	// cancel.
	e.rpcOK(t, "alayacore_cancel", map[string]any{"sessionId": sid})
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "cancel"
	})

	// Errors: unknown session.
	if msg := e.rpcErr(t, "alayacore_model_set", map[string]any{"sessionId": "nope", "modelId": 1}); msg != "Session not found" {
		t.Errorf("model_set on unknown session = %q", msg)
	}
}

// ─── Fork: source session → history → new session with session file ─

func TestIntegrationForkSession(t *testing.T) {
	e := newTestEnv(t, "")
	src := e.createSession(t)
	e.waitEvent(t, "core-status", func(p map[string]any) bool {
		return p["session_id"] == src && p["connected"] == true
	})

	// Fork up to the fake's history id.
	body := e.rpcOK(t, "fork_session", map[string]any{
		"sourceSessionId": src, "historyId": "hist-1", "binaryPath": "",
	})
	var newID string
	if err := json.Unmarshal(body, &newID); err != nil {
		t.Fatalf("fork_session: bad id body %q", body)
	}
	if newID == "" || newID == src {
		t.Fatalf("fork returned invalid id %q", newID)
	}

	// The fork CO arrives with the injected command name.
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["tag"] == "CO" && js != nil && js["name"] == "fork"
	})

	// New session connected; session file exists on disk.
	e.waitEvent(t, "core-status", func(p map[string]any) bool {
		return p["session_id"] == newID && p["connected"] == true
	})
	file := filepath.Join(dirs.AlayafaceDir(), "sessions", newID, "session.alaya")
	if _, err := os.Stat(file); err != nil {
		t.Fatalf("forked session file missing: %v", err)
	}

	// list_session_dirs shows both sessions, newest (forked) first.
	dirsBody := e.rpcOK(t, "list_session_dirs", map[string]any{})
	var list []map[string]any
	if err := json.Unmarshal(dirsBody, &list); err != nil {
		t.Fatalf("list_session_dirs: %s", dirsBody)
	}
	if len(list) != 2 {
		t.Fatalf("list_session_dirs len = %d, want 2: %s", len(list), dirsBody)
	}
	// Both sessions must be listed with their session files. Ordering
	// is by dir mtime; same-second timestamps make it ambiguous, so
	// assert set membership (matches Rust, which has the same
	// granularity ambiguity).
	ids := map[string]bool{}
	for _, item := range list {
		ids[item["id"].(string)] = true
		if item["has_session_file"] != true {
			t.Errorf("session %v should have session.alaya", item["id"])
		}
	}
	if !ids[src] || !ids[newID] {
		t.Errorf("list_session_dirs missing src/new: %s", dirsBody)
	}
}

// ─── Models: cache / live session / probe fallback ──────────────────

func TestIntegrationListModels(t *testing.T) {
	// No sessions → probe fallback (temp fakecore, stdin closed).
	e := newTestEnv(t, "")
	body := e.rpcOK(t, "list_models", map[string]any{"binaryPath": "", "configPath": ""})
	var models []map[string]any
	if err := json.Unmarshal(body, &models); err != nil {
		t.Fatalf("list_models (probe): %s", body)
	}
	if len(models) != 2 || models[0]["name"] != "fake-model-1" {
		t.Fatalf("list_models (probe) = %s", body)
	}

	// Live session: cache or model_load path — result must be the same.
	e2 := newTestEnv(t, "")
	sid := e2.createSession(t)
	e2.waitEvent(t, "core-status", func(p map[string]any) bool {
		return p["session_id"] == sid && p["connected"] == true
	})
	body = e2.rpcOK(t, "list_models", map[string]any{"binaryPath": "", "configPath": ""})
	if err := json.Unmarshal(body, &models); err != nil {
		t.Fatalf("list_models (live): %s", body)
	}
	if len(models) != 2 {
		t.Fatalf("list_models (live) = %s", body)
	}
	// Second call must come from cache.
	if body2 := e2.rpcOK(t, "list_models", map[string]any{"binaryPath": "", "configPath": ""}); !bytes.Equal(body, body2) {
		t.Errorf("cached list_models differs: %s vs %s", body, body2)
	}
}

func TestIntegrationListDefaultModels(t *testing.T) {
	e := newTestEnv(t, "")
	body := e.rpcOK(t, "list_default_models", map[string]any{"binaryPath": "", "preset": ""})
	var models []map[string]any
	if err := json.Unmarshal(body, &models); err != nil {
		t.Fatalf("list_default_models: %s", body)
	}
	if len(models) != 2 || models[0]["name"] != "fake-model-1" {
		t.Fatalf("list_default_models = %s", body)
	}
}

// ─── sync_default_models: success + error paths via probe ───────────

func TestIntegrationSyncDefaultModels(t *testing.T) {
	e := newTestEnv(t, "")

	// Success: CO is_error=false → handler returns CO output.
	body := e.rpcOK(t, "sync_default_models", map[string]any{
		"binaryPath": "", "preset": "", "config": `{"name":"new-model"}`,
	})
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("sync_default_models success: %s", body)
	}
	if out["message"] != "synced" {
		t.Errorf("sync_default_models output = %s", body)
	}

	// Error: CO is_error=true → handler surfaces {"error": message}.
	if msg := e.rpcErr(t, "sync_default_models", map[string]any{
		"binaryPath": "", "preset": "", "config": `{"invalid":true}`,
	}); msg != "invalid config" {
		t.Errorf("sync_default_models error = %q, want 'invalid config'", msg)
	}
}

// ─── Resume + delete session dir ────────────────────────────────────

func TestIntegrationResumeAndDeleteSession(t *testing.T) {
	e := newTestEnv(t, "")
	sid := e.createSession(t)
	// Wait until fakecore has fully started: the startup SM task frame
	// is emitted AFTER the session file is written, so receiving it
	// guarantees session.alaya exists on disk.
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == sid && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})

	// Resume the on-disk session dir → fresh session id, connected.
	body := e.rpcOK(t, "resume_session", map[string]any{"sessionId": sid, "binaryPath": ""})
	var newID string
	if err := json.Unmarshal(body, &newID); err != nil {
		t.Fatalf("resume_session: %s", body)
	}
	if newID == sid {
		t.Fatal("resume returned the same id")
	}
	// Wait until the resumed fakecore finished startup writes (SM task
	// frame is emitted after session.alaya is written) so the delete
	// below cannot race with the child recreating files.
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == newID && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})

	// Double-resume of the same dir must fail.
	if msg := e.rpcErr(t, "resume_session", map[string]any{"sessionId": sid, "binaryPath": ""}); msg != "Session is already active" {
		t.Errorf("double resume = %q, want 'Session is already active'", msg)
	}

	// Delete the session dir: the dir is removed. Rust parity: the
	// resumed session (different id, same dir) is NOT closed by
	// delete_session_dir — it only closes by the passed session id —
	// so newID stays alive and can be closed explicitly.
	e.rpcOK(t, "delete_session_dir", map[string]any{"sessionId": sid})
	dirsBody := e.rpcOK(t, "list_session_dirs", map[string]any{})
	var list []map[string]any
	if err := json.Unmarshal(dirsBody, &list); err != nil {
		t.Fatalf("list_session_dirs: %s", dirsBody)
	}
	for _, item := range list {
		if item["id"] == sid {
			t.Fatalf("session dir %s still listed after delete", sid)
		}
	}
	// The resumed session survives (matches Rust); close it explicitly.
	e.rpcOK(t, "close_session", map[string]any{"sessionId": newID})
	if msg := e.rpcErr(t, "close_session", map[string]any{"sessionId": newID}); msg != "Session not found" {
		t.Errorf("second close after delete = %q, want 'Session not found'", msg)
	}
}

// ─── Token auth hardening ───────────────────────────────────────────

func TestIntegrationTokenAuth(t *testing.T) {
	e := newTestEnv(t, "secret-token")

	// RPC without the bearer token → 401.
	body, status := e.rpc(t, "list_presets", map[string]any{})
	if status != http.StatusUnauthorized || !strings.Contains(string(body), "unauthorized") {
		t.Fatalf("rpc without token: status %d body %s", status, body)
	}

	// WS without ?token= → dial fails with 401.
	wsURL := "ws" + strings.TrimPrefix(e.base, "http") + "/ws"
	_, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err == nil {
		t.Fatal("ws without token should be rejected")
	}
	if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("ws without token: status %v", resp)
	}

	// RPC with the token → 200 (list_presets returns the Default preset).
	req, _ := http.NewRequest("POST", e.base+"/rpc/list_presets", strings.NewReader("{}"))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer secret-token")
	resp2, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("rpc with token: status %d", resp2.StatusCode)
	}
}
