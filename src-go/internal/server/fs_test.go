package server

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// ─── fs_write_file_text / fs_read_file_text ─────────────────────────
// Mirrors Rust commands/fs.rs; error messages must match exactly.

func TestFsWriteReadTextRoundtrip(t *testing.T) {
	e := newTestEnv(t, "")
	dir := t.TempDir()
	path := filepath.Join(dir, "hello.txt")

	e.rpcOK(t, "fs_write_file_text", map[string]any{
		"path":    path,
		"content": "hello 世界\nline2",
	})

	var got string
	body := e.rpcOK(t, "fs_read_file_text", map[string]any{"path": path})
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode read result: %v body=%s", err, body)
	}
	if got != "hello 世界\nline2" {
		t.Fatalf("read content mismatch: %q", got)
	}
}

func TestFsWriteFileTextCreateParents(t *testing.T) {
	e := newTestEnv(t, "")
	dir := t.TempDir()
	path := filepath.Join(dir, "deep", "nested", "b.txt")

	e.rpcOK(t, "fs_write_file_text", map[string]any{
		"path":          path,
		"content":       "x",
		"createParents": true,
	})
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("expected file to exist: %v", err)
	}
}

func TestFsWriteFileTextWithoutParentsFailsParity(t *testing.T) {
	// Error message must match the Rust backend ("Cannot write file: ...").
	e := newTestEnv(t, "")
	dir := t.TempDir()
	path := filepath.Join(dir, "missing", "c.txt")

	msg := e.rpcErr(t, "fs_write_file_text", map[string]any{
		"path":    path,
		"content": "x",
	})
	if !strings.HasPrefix(msg, "Cannot write file:") {
		t.Fatalf("error message parity broken: %q", msg)
	}
}

func TestFsReadFileTextMissingParity(t *testing.T) {
	// Error message must match the Rust backend ("Cannot read file: ...").
	e := newTestEnv(t, "")
	dir := t.TempDir()
	path := filepath.Join(dir, "nope.txt")

	msg := e.rpcErr(t, "fs_read_file_text", map[string]any{"path": path})
	if !strings.HasPrefix(msg, "Cannot read file:") {
		t.Fatalf("error message parity broken: %q", msg)
	}
}

func TestFsDeleteFileParity(t *testing.T) {
	e := newTestEnv(t, "")
	dir := t.TempDir()
	path := filepath.Join(dir, "del.txt")

	// missing → exact parity message
	if msg := e.rpcErr(t, "fs_delete_file", map[string]any{"path": path}); msg != "Cannot delete file: Path does not exist" {
		t.Fatalf("missing-file parity broken: %q", msg)
	}

	// write then delete succeeds
	e.rpcOK(t, "fs_write_file_text", map[string]any{"path": path, "content": "x"})
	e.rpcOK(t, "fs_delete_file", map[string]any{"path": path})
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expected file removed, err=%v", err)
	}

	// directory → exact parity message
	msg := e.rpcErr(t, "fs_delete_file", map[string]any{"path": dir})
	if msg != "Cannot delete file: Is a directory" {
		t.Fatalf("directory parity broken: %q", msg)
	}
}

// ─── create_session with preset / builtinTools (P4.5) ──────────────

func TestCreateSessionWithPreset(t *testing.T) {
	e := newTestEnv(t, "")

	// Unknown preset is rejected with the Rust-parity message.
	msg := e.rpcErr(t, "create_session", map[string]any{
		"binaryPath": "", "configPath": "", "toolConfirm": nil,
		"preset": "nope",
	})
	if msg != "Preset not found: nope" {
		t.Fatalf("preset error parity broken: %q", msg)
	}

	// Creating with the Safe preset works and returns a session id.
	body := e.rpcOK(t, "create_session", map[string]any{
		"binaryPath": "", "configPath": "", "toolConfirm": nil,
		"preset": "Safe", "builtinTools": "",
	})
	var sid string
	if err := json.Unmarshal(body, &sid); err != nil || sid == "" {
		t.Fatalf("create with preset failed: body=%s err=%v", body, err)
	}

	// Session dir must exist and its config must contain model.conf but
	// NOT settings.conf (Safe's builtin_tools must not leak into sessions).
	sessionsDir := filepath.Join(os.Getenv("HOME"), ".alayaface", "sessions", sid)
	if _, err := os.Stat(filepath.Join(sessionsDir, "config", "model.conf")); err != nil {
		t.Fatalf("session config missing model.conf: %v", err)
	}
	if _, err := os.Stat(filepath.Join(sessionsDir, "config", "settings.conf")); err == nil {
		t.Fatal("settings.conf leaked into session config")
	}

	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})
}

func TestCreateSessionExplicitBuiltinTools(t *testing.T) {
	e := newTestEnv(t, "")
	body := e.rpcOK(t, "create_session", map[string]any{
		"binaryPath": "", "configPath": "", "toolConfirm": nil,
		"builtinTools": "read_file,write_file",
	})
	var sid string
	if err := json.Unmarshal(body, &sid); err != nil || sid == "" {
		t.Fatalf("create failed: body=%s err=%v", body, err)
	}
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})
}

// ─── create_session with systemPrompt (Plan Sessions, P6) ──────────

func TestCreateSessionWithSystemPrompt(t *testing.T) {
	e := newTestEnv(t, "")
	body := e.rpcOK(t, "create_session", map[string]any{
		"binaryPath":   "",
		"configPath":   "",
		"toolConfirm":  nil,
		"systemPrompt": "你是任务规划助手，输出 ```json 计划块。",
	})
	var sid string
	if err := json.Unmarshal(body, &sid); err != nil || sid == "" {
		t.Fatalf("create with systemPrompt failed: body=%s err=%v", body, err)
	}

	// Session works (fakecore answers prompts regardless of --system).
	e.rpcOK(t, "alayacore_send_prompt", map[string]any{
		"sessionId": sid, "text": "hello", "media": []any{},
	})
	e.rpcOK(t, "close_session", map[string]any{"sessionId": sid})
}
