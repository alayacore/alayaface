package handlers

import (
	"net/http"
	"os"
	"path/filepath"

	"alayaface/src-go/internal/dirs"
)

// ListDefaultMcp returns a preset's mcp.conf verbatim (preset REQUIRED).
// A missing file is an empty document, not an error (first run).
//
// Text, not a parsed server list: mcp.conf's schema lives in
// App/McpConfig.elm, so this backend never interprets a field. Parsing it
// here would be a second implementation of the same keys — the drift that
// produced the `&`/`<`/`>` corruption this move fixed.
func ListDefaultMcp(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Preset string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	// Ensure first so the seed presets exist on first run.
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	configDir, err := dirs.ResolveConfigDir(args.Preset)
	if err != nil {
		return err
	}
	text, err := os.ReadFile(filepath.Join(configDir, "mcp.conf"))
	if err != nil {
		if os.IsNotExist(err) {
			return writeJSON(w, map[string]string{"text": ""})
		}
		return err
	}
	return writeJSON(w, map[string]string{"text": string(text)})
}

// SyncDefaultMcp replaces a preset's mcp.conf with `config`, the whole file
// produced by App.McpConfig.encode.
//
// Atomic, and 0600: the file can hold OAuth client secrets and tokens, and
// model.conf already keeps that permission. Nothing is validated here on
// purpose — the client owns the schema (its draftProblems refuses at Save),
// and a bad block that reaches the file is reported by AlayaCore at session
// start with its block number.
func SyncDefaultMcp(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Config string `json:"config"`
		Preset string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	configDir, err := dirs.ResolveConfigDir(args.Preset)
	if err != nil {
		return err
	}
	if err := dirs.WriteFileAtomicMode(
		filepath.Join(configDir, "mcp.conf"),
		[]byte(args.Config),
		0o600,
	); err != nil {
		return err
	}
	return writeResult(w, nil)
}
