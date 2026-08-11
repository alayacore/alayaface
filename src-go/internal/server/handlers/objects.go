package handlers

// Content-addressed object store (C architecture, arch-persistent.md §6.1):
// immutable objects (message blocks, plan defs, run snapshots, session
// versions) stored by sha256(content) under ~/.alayaface/objects/<hash>/.
// Identity is the hash: equal content = equal hash = shared object (no
// duplicates); objects are written once and never modified.

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"os"
	"path/filepath"

	"alayaface/src-go/internal/dirs"
)

// ObjectPut stores content idempotently and returns its hash. Existing
// objects are not overwritten (content-addressed: same hash = same
// content). Mirrors Rust object_put exactly.
func ObjectPut(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Content string `json:"content"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	sum := sha256.Sum256([]byte(args.Content))
	hash := hex.EncodeToString(sum[:])
	dir := filepath.Join(dirs.AlayafaceDir(), "objects", hash)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("Cannot write object: %w", err)
	}
	path := filepath.Join(dir, "content.json")
	if _, err := os.Stat(path); os.IsNotExist(err) {
		if err := os.WriteFile(path, []byte(args.Content), 0o644); err != nil {
			return fmt.Errorf("Cannot write object: %w", err)
		}
	}
	return writeResult(w, map[string]string{"hash": hash})
}

// ObjectGet reads an object by hash. Mirrors Rust object_get exactly.
func ObjectGet(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Hash string `json:"hash"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	path := filepath.Join(dirs.AlayafaceDir(), "objects", args.Hash, "content.json")
	if err := checkFileSize(path, maxTextFileSize); err != nil {
		return err
	}
	content, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("Cannot read object: %w", err)
	}
	return writeResult(w, string(content))
}
