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
