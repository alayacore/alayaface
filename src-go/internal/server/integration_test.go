package server

import (
	"bytes"
	"crypto/sha256"
	"encoding/json"
	"fmt"
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

// waitSessionFile blocks until fakecore has written <sid>/session.alaya
// on disk. resume_session checks the file BEFORE the in-memory
// "Session is already active" guard, and fakecore writes the file
// asynchronously during boot — so any test asserting the double-resume
// guard must wait for the file first or it races (flaky "Session file
// not found" instead of "Session is already active").
func waitSessionFile(t *testing.T, sid string) {
	t.Helper()
	path := filepath.Join(dirs.AlayafaceDir(), "sessions", sid, "session.alaya")
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("session.alaya not written for %s", sid)
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
	// Both sessions must be listed. Ordering is by dir mtime;
	// same-second timestamps make it ambiguous, so assert set membership
	// (matches Rust, which has the same granularity ambiguity).
	ids := map[string]bool{}
	for _, item := range list {
		ids[item["id"].(string)] = true
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

// TestIntegrationResumeKeepsSpawnArgs: the capability envelope of a
// session (tool_confirm, builtin_tools restriction, system prompt, work
// dir) must survive close + resume — a Plan Session with NO tools must
// not come back with ALL tools after a restart.
func TestIntegrationResumeKeepsSpawnArgs(t *testing.T) {
	e := newTestEnv(t, "")

	// Boot frame of a session created with a restricted envelope.
	waitBoot := func(sid string, want map[string]any) {
		t.Helper()
		e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
			js, _ := p["json"].(map[string]any)
			if p["session_id"] != sid || p["tag"] != "SM" || js == nil || js["type"] != "task" {
				return false
			}
			data, _ := js["data"].(map[string]any)
			if data == nil {
				return false
			}
			for k, v := range want {
				if data[k] != v {
					return false
				}
			}
			return true
		})
	}

	workDir := filepath.Join(t.TempDir(), "plan-work")
	body := e.rpcOK(t, "create_session", map[string]any{
		"binaryPath":   "",
		"configPath":   "",
		"toolConfirm":  "allow",
		"builtinTools": "", // explicitly NO builtin tools (Plan Session)
		"systemPrompt": "planner-hint",
		"workDir":      workDir,
	})
	var sid string
	if err := json.Unmarshal(body, &sid); err != nil {
		t.Fatalf("create_session: %s", body)
	}
	waitBoot(sid, map[string]any{
		"tool_confirm":      "allow",
		"builtin_tools":     "",
		"builtin_tools_set": true,
		"system":            "planner-hint",
		"cwd":               workDir,
	})

	// The spawn args were persisted next to the session.
	spawnFile := filepath.Join(dirs.AlayafaceDir(), "sessions", sid, "session.spawn.json")
	if _, err := os.Stat(spawnFile); err != nil {
		t.Fatalf("session.spawn.json missing: %v", err)
	}

	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})

	// Resume WITHOUT passing workDir (the frontend omits it) — the
	// persisted envelope must be re-applied.
	resumeBody := e.rpcOK(t, "resume_session", map[string]any{"sessionId": sid, "binaryPath": ""})
	var newID string
	if err := json.Unmarshal(resumeBody, &newID); err != nil {
		t.Fatalf("resume_session: %s", resumeBody)
	}
	waitBoot(newID, map[string]any{
		"tool_confirm":      "allow",
		"builtin_tools":     "",
		"builtin_tools_set": true,
		"system":            "planner-hint",
		"cwd":               workDir,
	})
	e.rpcOK(t, "close_session", map[string]any{"sessionId": newID})

	// A legacy session without spawn.json resumes with the old behavior
	// (no restrictions): build one by deleting the file.
	legacyID := e.createSession(t)
	waitBoot(legacyID, map[string]any{"builtin_tools_set": false})
	os.Remove(filepath.Join(dirs.AlayafaceDir(), "sessions", legacyID, "session.spawn.json"))
	e.rpcOK(t, "close_session", map[string]any{"sessionId": legacyID})
	resumeBody = e.rpcOK(t, "resume_session", map[string]any{"sessionId": legacyID, "binaryPath": ""})
	var legacyNewID string
	if err := json.Unmarshal(resumeBody, &legacyNewID); err != nil {
		t.Fatalf("resume legacy: %s", resumeBody)
	}
	// No --builtin-tools flag → boot frame has builtin_tools_set=false.
	waitBoot(legacyNewID, map[string]any{"builtin_tools_set": false})
	e.rpcOK(t, "close_session", map[string]any{"sessionId": legacyNewID})
}

// TestIntegrationCloseAllSessionsReclaimsOnPageLoad: a page refresh
// leaves the backend holding session handles whose windows are gone —
// resume then fails with "Session is already active" until the backend
// restarts. The frontend fires close_all_sessions on page load to
// reclaim them (graceful close, history kept on disk).
func TestIntegrationCloseAllSessionsReclaimsOnPageLoad(t *testing.T) {
	e := newTestEnv(t, "")
	sid1 := e.createSession(t)
	sid2 := e.createSession(t)
	// resume_session's "already active" guard only fires after the
	// on-disk session.alaya check passes; fakecore writes it during
	// boot, so wait for both files before the assertion.
	waitSessionFile(t, sid1)
	waitSessionFile(t, sid2)

	// Both are active: a direct resume must be rejected.
	if msg := e.rpcErr(t, "resume_session", map[string]any{"sessionId": sid1, "binaryPath": ""}); msg != "Session is already active" {
		t.Fatalf("pre-reclaim double resume = %q, want 'Session is already active'", msg)
	}

	// Page load: reclaim ALL active sessions.
	e.rpcOK(t, "close_all_sessions", map[string]any{})

	// Old handles are gone.
	for _, sid := range []string{sid1, sid2} {
		if msg := e.rpcErr(t, "close_session", map[string]any{"sessionId": sid}); msg != "Session not found" {
			t.Errorf("close %s after close_all_sessions = %q, want 'Session not found'", sid, msg)
		}
	}

	// Resume now works again (history preserved on disk) — this is the
	// exact flow that used to require a backend restart.
	for _, sid := range []string{sid1, sid2} {
		body := e.rpcOK(t, "resume_session", map[string]any{"sessionId": sid, "binaryPath": ""})
		var newID string
		if err := json.Unmarshal(body, &newID); err != nil {
			t.Fatalf("resume_session after close_all_sessions: %s", body)
		}
		e.rpcOK(t, "close_session", map[string]any{"sessionId": newID})
	}
}

// TestIntegrationCloseAllSessionsScopedByClient: close_all_sessions
// with a clientId must reclaim only THAT client's sessions — another
// client's live sessions survive (multi-client LAN/SSH scenario; a
// second tab's page load must not kill the first tab's sessions). An
// empty clientId (legacy client) still closes everything.
func TestIntegrationCloseAllSessionsScopedByClient(t *testing.T) {
	e := newTestEnv(t, "")

	createFor := func(client string) string {
		t.Helper()
		body := e.rpcOK(t, "create_session", map[string]any{
			"binaryPath": "", "configPath": "", "toolConfirm": nil, "clientId": client,
		})
		var id string
		if err := json.Unmarshal(body, &id); err != nil {
			t.Fatalf("create_session: %s", body)
		}
		return id
	}
	sidA := createFor("client-a")
	sidB := createFor("client-b")
	// B's session.alaya is written asynchronously by fakecore; the
	// double-resume guard below only fires once the file exists.
	waitSessionFile(t, sidB)

	// A page load for client A reclaims only A's session.
	e.rpcOK(t, "close_all_sessions", map[string]any{"clientId": "client-a"})
	if msg := e.rpcErr(t, "close_session", map[string]any{"sessionId": sidA}); msg != "Session not found" {
		t.Errorf("client A's session after its reclaim = %q, want 'Session not found'", msg)
	}
	// B's session is still active (resume is rejected).
	if msg := e.rpcErr(t, "resume_session", map[string]any{"sessionId": sidB, "binaryPath": ""}); msg != "Session is already active" {
		t.Errorf("client B's session after A's reclaim = %q, want 'Session is already active'", msg)
	}

	// B's own page load reclaims B's session.
	e.rpcOK(t, "close_all_sessions", map[string]any{"clientId": "client-b"})
	if msg := e.rpcErr(t, "close_session", map[string]any{"sessionId": sidB}); msg != "Session not found" {
		t.Errorf("client B's session after its reclaim = %q, want 'Session not found'", msg)
	}

	// Empty clientId (legacy client) closes everything.
	sidC := createFor("client-c")
	e.rpcOK(t, "close_all_sessions", map[string]any{})
	if msg := e.rpcErr(t, "close_session", map[string]any{"sessionId": sidC}); msg != "Session not found" {
		t.Errorf("legacy close_all_sessions did not close everything: %q", msg)
	}
}

// ─── Graceful close (save + EOF + natural exit) ─────────────────────

func TestIntegrationGracefulCloseSavesSession(t *testing.T) {
	e := newTestEnv(t, "")
	sid := e.createSession(t)

	// Wait until fakecore finished startup: the startup SM task frame is
	// emitted AFTER the session file is written.
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == sid && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})

	sessionFile := filepath.Join(dirs.AlayafaceDir(), "sessions", sid, "session.alaya")
	if b, err := os.ReadFile(sessionFile); err != nil || !strings.Contains(string(b), `"version":1`) {
		t.Fatalf("session file missing before close: %v %q", err, b)
	}

	// close_session must send the CI `save` frame before EOF: fakecore
	// rewrites session.alaya with the saved marker, proving the save
	// command arrived while the child was still alive (EOF alone would
	// NOT persist — alayacore only auto-saves at task end).
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})

	b, err := os.ReadFile(sessionFile)
	if err != nil {
		t.Fatalf("read session file after graceful close: %v", err)
	}
	if !strings.Contains(string(b), `"saved":true`) {
		t.Fatalf("session file after close = %q, want save marker (graceful close did not save)", b)
	}

	// Double close still fails with the parity message.
	if msg := e.rpcErr(t, "close_session", map[string]any{"sessionId": sid}); msg != "Session not found" {
		t.Errorf("second close = %q, want 'Session not found'", msg)
	}
}

// ─── Cancel-first close (CI cancel aborts a hung task) ──────────────

func TestIntegrationCloseCancelsHungTask(t *testing.T) {
	e := newTestEnv(t, "")
	sid := e.createSession(t)

	// Wait until fakecore finished startup (SM task frame after the
	// session file is written).
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == sid && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})

	// Send a prompt that triggers fakecore's hang-once: the task hangs
	// (never answers) but the process keeps reading stdin and serving CI
	// commands — so a cancel-first close can abort it. Unique text keeps
	// the shared marker keyed to THIS run.
	text := "hang-once-" + fmt.Sprintf("%d", time.Now().UnixNano())
	e.rpcOK(t, "alayacore_send_prompt", map[string]any{"sessionId": sid, "text": text})

	// Wait until the task is actually hung (marker written).
	h := sha256.Sum256([]byte(text))
	marker := filepath.Join(os.TempDir(), fmt.Sprintf("alayaface-fakecore-hang-once-%x.marker", h[:8]))
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(marker); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("hang marker never appeared — fakecore did not enter hang mode")
		}
		time.Sleep(50 * time.Millisecond)
	}

	// close_session runs cancel → save → EOF. The CI `cancel` must abort
	// the hung task so the process exits naturally and quickly. WITHOUT
	// cancel-first, the close would have to wait out the whole hang (the
	// old fakecore slept 30s) plus the 5s grace SIGKILL.
	start := time.Now()
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Fatalf("close_session took %v — CI cancel did not abort the hung task", elapsed)
	}
}

// ─── Work-dir isolation (per-plan working directory) ────────────────

func TestIntegrationSessionWorkDir(t *testing.T) {
	e := newTestEnv(t, "")
	workDir := filepath.Join(dirs.AlayafaceDir(), "plans", "demo-1", "work")

	// create_session with workDir: the backend must create it and spawn
	// the child with it as cwd (fakecore reports cwd in the boot SM).
	sid := e.rpcOK(t, "create_session", map[string]any{
		"binaryPath": "", "configPath": "", "toolConfirm": nil, "workDir": workDir,
	})
	var id string
	if err := json.Unmarshal(sid, &id); err != nil {
		t.Fatalf("create_session: %s", sid)
	}
	ev := e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == id && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})
	js, _ := ev["json"].(map[string]any)
	data, _ := js["data"].(map[string]any)
	if cwd, _ := data["cwd"].(string); cwd != workDir {
		t.Fatalf("create_session cwd = %q, want %q", cwd, workDir)
	}
	if _, err := os.Stat(workDir); err != nil {
		t.Fatalf("workDir not created: %v", err)
	}
	e.rpcOK(t, "close_session", map[string]any{"sessionId": id})

	// resume_session with workDir: the resumed child keeps the cwd.
	body := e.rpcOK(t, "resume_session", map[string]any{"sessionId": id, "binaryPath": "", "workDir": workDir})
	var newID string
	if err := json.Unmarshal(body, &newID); err != nil {
		t.Fatalf("resume_session: %s", body)
	}
	ev2 := e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == newID && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})
	js2, _ := ev2["json"].(map[string]any)
	data2, _ := js2["data"].(map[string]any)
	if cwd, _ := data2["cwd"].(string); cwd != workDir {
		t.Fatalf("resume_session cwd = %q, want %q", cwd, workDir)
	}
	e.rpcOK(t, "close_session", map[string]any{"sessionId": newID})

	// Without workDir the child keeps the backend's cwd (pre-isolation).
	sid2 := e.createSession(t)
	ev3 := e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == sid2 && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})
	js3, _ := ev3["json"].(map[string]any)
	data3, _ := js3["data"].(map[string]any)
	cwd, _ := data3["cwd"].(string)
	backendCwd, _ := os.Getwd()
	if cwd != backendCwd {
		t.Fatalf("default cwd = %q, want backend cwd %q", cwd, backendCwd)
	}
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid2})
}

// ─── Nested plan-session directories ────────────────────────────────

// Plan node sessions (create_session with planId/nodeId/originSessionId)
// must be stored NESTED under sessions/<originSessionId>/plans/<planId>/<nodeId>/
// — every plan lives inside the session that created it, and the
// sessions/ top level only ever contains plain sessions. The session
// manager (list_session_dirs) must not show plan dirs, resume must find
// the nested dir, and delete must remove it.
func TestIntegrationNestedPlanSessionDir(t *testing.T) {
	e := newTestEnv(t, "")
	sessionsRoot := filepath.Join(dirs.AlayafaceDir(), "sessions")

	// Plain sessions stay at the top level. session.alaya is written by
	// the core on boot, so wait for the boot SM before asserting.
	plainSid := e.createSession(t)
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == plainSid && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})
	if _, err := os.Stat(filepath.Join(sessionsRoot, plainSid, "session.alaya")); err != nil {
		t.Fatalf("plain session dir missing: %v", err)
	}
	e.rpcOK(t, "close_session", map[string]any{"sessionId": plainSid})

	// The ORIGIN session (a plain chat session that created the plan).
	originSid := e.createSession(t)
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == originSid && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})

	// Plan node session goes NESTED under the ORIGIN session's dir (id
	// with '/' + spaces exercises the sanitizer; create and resume must
	// agree on the mapping).
	workDir := filepath.Join(sessionsRoot, originSid, "plans", "demo 1", "work")
	body := e.rpcOK(t, "create_session", map[string]any{
		"binaryPath": "", "configPath": "", "toolConfirm": nil,
		"workDir": workDir, "planId": "demo 1", "nodeId": "t1/x", "originSessionId": originSid,
	})
	var sid string
	if err := json.Unmarshal(body, &sid); err != nil {
		t.Fatalf("create_session: %s", body)
	}
	nestedDir := filepath.Join(sessionsRoot, originSid, "plans", "demo_1", "t1_x", sid)
	// The nested DIR (with config/) is created synchronously; the
	// session.alaya appears once the core boots.
	if _, err := os.Stat(filepath.Join(nestedDir, "config")); err != nil {
		t.Fatalf("plan session not nested at %s: %v", nestedDir, err)
	}
	// Top level must NOT contain the plan session id or a plan dir.
	if _, err := os.Stat(filepath.Join(sessionsRoot, sid)); err == nil {
		t.Fatal("plan child session must not live at the sessions top level")
	}
	if _, err := os.Stat(filepath.Join(sessionsRoot, "demo_1")); err == nil {
		t.Fatal("plan dir must not live at the sessions top level")
	}
	if _, err := os.Stat(workDir); err != nil {
		t.Fatalf("per-plan work dir not created: %v", err)
	}
	e.waitEvent(t, "tlv-frame", func(p map[string]any) bool {
		js, _ := p["json"].(map[string]any)
		return p["session_id"] == sid && p["tag"] == "SM" && js != nil && js["type"] == "task"
	})
	if _, err := os.Stat(filepath.Join(nestedDir, "session.alaya")); err != nil {
		t.Fatalf("nested session.alaya missing: %v", err)
	}

	// list_session_dirs shows only top-level SESSION dirs (the two plain
	// sessions) — never plan dirs or plan child sessions.
	var dirs1 []map[string]any
	body = e.rpcOK(t, "list_session_dirs", map[string]any{})
	if err := json.Unmarshal(body, &dirs1); err != nil {
		t.Fatalf("list_session_dirs: %s", body)
	}
	ids := map[string]bool{}
	for _, d := range dirs1 {
		ids[d["id"].(string)] = true
	}
	if len(dirs1) != 2 || !ids[plainSid] || !ids[originSid] {
		t.Fatalf("list_session_dirs = %v, want the two plain sessions %s/%s", dirs1, plainSid, originSid)
	}

	// Resume with originSessionId/planId/nodeId finds the nested dir
	// (close the live session first — double-resume is rejected).
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})
	body = e.rpcOK(t, "resume_session", map[string]any{
		"sessionId": sid, "binaryPath": "", "workDir": workDir,
		"planId": "demo 1", "nodeId": "t1/x", "originSessionId": originSid,
	})
	var newID string
	if err := json.Unmarshal(body, &newID); err != nil {
		t.Fatalf("resume_session: %s", body)
	}
	if newID == sid {
		t.Fatal("resume must hand out a fresh id")
	}
	e.rpcOK(t, "close_session", map[string]any{"sessionId": newID})

	// Resume WITHOUT originSessionId/planId must NOT find it (the lookup
	// is nested-aware, not a flat fallback).
	e.rpcErr(t, "resume_session", map[string]any{"sessionId": sid, "binaryPath": ""})

	// Delete with originSessionId/planId/nodeId removes the nested dir.
	e.rpcOK(t, "delete_session_dir", map[string]any{"sessionId": sid, "planId": "demo 1", "nodeId": "t1/x", "originSessionId": originSid})
	if _, err := os.Stat(nestedDir); err == nil {
		t.Fatal("nested plan session dir not deleted")
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

// ─── Core-status ordering (B5) ──────────────────────────────────────

// TestIntegrationCoreStatusOrderingImmediateExit verifies that a session
// whose child dies instantly (bad spawn) ends up with connected:false as
// its FINAL status. create_session must broadcast connected:true BEFORE
// starting the stdout reader — otherwise the reader's immediate
// disconnect broadcast can arrive first and the client would believe a
// dead session is connected (no frames, no further status updates).
func TestIntegrationCoreStatusOrderingImmediateExit(t *testing.T) {
	e := newTestEnv(t, "")

	// A binary that exits immediately after spawn (overrides the
	// fakecore path newTestEnv set).
	script := filepath.Join(t.TempDir(), "alayacore")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALAYACORE_BIN", script)

	sid := e.createSession(t)

	// Collect core-status events for this session until we have seen
	// both transitions (or a timeout — a timeout means the session was
	// reported connected and never disconnected, which is the bug).
	// The FIRST status must be connected:true — create_session emits it
	// BEFORE the reader starts, so a dying child's disconnect can never
	// arrive first and leave the client believing a dead session is
	// connected.
	sawTrue := false
	sawFalse := false
	firstConnected := "unset"
	deadline := time.Now().Add(5 * time.Second)
	for !(sawTrue && sawFalse) && time.Now().Before(deadline) {
		ev := e.collectUntil(t, "core-status", func(p map[string]any) bool {
			return p["session_id"] == sid
		}, nil)
		if firstConnected == "unset" {
			firstConnected = fmt.Sprintf("%v", ev["connected"])
		}
		if conn, _ := ev["connected"].(bool); conn {
			sawTrue = true
		} else {
			sawFalse = true
		}
	}
	if !sawTrue || !sawFalse {
		t.Fatalf("expected connected:true then connected:false for the dying session, got true=%v false=%v", sawTrue, sawFalse)
	}
	if firstConnected != "true" {
		t.Fatalf("first core-status for a dying session must be connected:true (the disconnect must follow), got %s", firstConnected)
	}
}
