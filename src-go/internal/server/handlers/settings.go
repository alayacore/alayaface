package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"alayaface/src-go/internal/dirs"
)

// GlobalSettings mirrors ~/.alayaface/presets/<name>/settings.conf.
// This file is AlayaFace-owned — alayacore does not read it.
type GlobalSettings struct {
	// ToolConfirm is a comma-separated (no spaces) list of tool IDs
	// pre-approved at session start, passed to alayacore as
	// --tool-confirm=id1,id2,...
	ToolConfirm string `json:"tool_confirm"`
	// BuiltinTools is a comma-separated (no spaces) list of built-in
	// tool IDs enabled for sessions, passed to alayacore as
	// --builtin-tools=id1,id2,... Empty = don't pass the flag (alayacore
	// default: all tools).
	BuiltinTools string `json:"builtin_tools"`
	// SystemPrompt is the preset's --system text: the plan-mode contract
	// and role framing for the preset's sessions. Free text, not
	// normalized. Passed to alayacore as --system=<text>.
	SystemPrompt string `json:"system_prompt"`
}

// readSettingsFrom reads settings from a config dir; a missing/empty
// file yields defaults.
func readSettingsFrom(configDir string) (GlobalSettings, error) {
	path := filepath.Join(configDir, "settings.conf")
	text, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return GlobalSettings{}, nil
		}
		return GlobalSettings{}, err
	}
	if strings.TrimSpace(string(text)) == "" {
		return GlobalSettings{}, nil
	}
	var s GlobalSettings
	if err := json.Unmarshal(text, &s); err != nil {
		return GlobalSettings{}, fmt.Errorf("Failed to parse settings.conf: %w", err)
	}
	return s, nil
}

// NormalizeToolConfirm normalizes a comma-separated tool list: trim each
// id, drop empties, reject duplicates and ids containing whitespace.
func NormalizeToolConfirm(raw string) (string, error) {
	seen := map[string]bool{}
	var out []string
	for _, part := range strings.Split(raw, ",") {
		id := strings.TrimSpace(part)
		if id == "" {
			continue
		}
		if strings.IndexFunc(id, unicode.IsSpace) >= 0 {
			return "", fmt.Errorf("Tool id must not contain spaces: %s", id)
		}
		if seen[id] {
			return "", fmt.Errorf("Duplicate tool id: %s", id)
		}
		seen[id] = true
		out = append(out, id)
	}
	return strings.Join(out, ","), nil
}

// readPresetSettings reads a named preset's settings; a missing or
// empty file yields defaults.
func readPresetSettings(preset string) (GlobalSettings, error) {
	configDir, err := dirs.ResolveConfigDir(preset)
	if err != nil {
		return GlobalSettings{}, err
	}
	return readSettingsFrom(configDir)
}

// effectiveToolConfirm returns the normalized tool-confirm list of a
// named preset.
func effectiveToolConfirm(preset string) (string, error) {
	s, err := readPresetSettings(preset)
	if err != nil {
		return "", err
	}
	return NormalizeToolConfirm(s.ToolConfirm)
}

// effectiveBuiltinTools returns the normalized builtin-tools list of a
// named preset (empty = don't pass the flag = all tools).
func effectiveBuiltinTools(preset string) (string, error) {
	s, err := readPresetSettings(preset)
	if err != nil {
		return "", err
	}
	return NormalizeToolConfirm(s.BuiltinTools)
}

// effectiveSystemPrompt returns a named preset's system_prompt (empty =
// no --system).
func effectiveSystemPrompt(preset string) (string, error) {
	s, err := readPresetSettings(preset)
	if err != nil {
		return "", err
	}
	return s.SystemPrompt, nil
}

// GetGlobalSettings reads a preset's settings (preset REQUIRED).
func GetGlobalSettings(h *Handler, w http.ResponseWriter, r *http.Request) error {
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
	s, err := readSettingsFrom(configDir)
	if err != nil {
		return err
	}
	tc, err := NormalizeToolConfirm(s.ToolConfirm)
	if err != nil {
		return err
	}
	bt, err := NormalizeToolConfirm(s.BuiltinTools)
	if err != nil {
		return err
	}
	return writeJSON(w, map[string]string{"tool_confirm": tc, "builtin_tools": bt, "system_prompt": s.SystemPrompt})
}

// SyncGlobalSettings replaces a preset's settings (preset REQUIRED).
// Accepts {"tool_confirm": "id1,id2", "builtin_tools": "...",
// "system_prompt": "..."}; writes atomically.
func SyncGlobalSettings(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Config string `json:"config"`
		Preset string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	var value map[string]any
	if err := json.Unmarshal([]byte(args.Config), &value); err != nil {
		return fmt.Errorf("Invalid settings JSON: %w", err)
	}
	// Ensure first so the seed presets exist on first run.
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	configDir, err := dirs.ResolveConfigDir(args.Preset)
	if err != nil {
		return err
	}
	// MERGE semantics: fields absent from the payload keep their current
	// value (a partial sync must not wipe e.g. system_prompt).
	existing, err := readSettingsFrom(configDir)
	if err != nil {
		return err
	}
	settings := existing
	if rawTc, ok := value["tool_confirm"].(string); ok {
		tc, err := NormalizeToolConfirm(rawTc)
		if err != nil {
			return err
		}
		settings.ToolConfirm = tc
	}
	if rawBt, ok := value["builtin_tools"].(string); ok {
		bt, err := NormalizeToolConfirm(rawBt)
		if err != nil {
			return err
		}
		settings.BuiltinTools = bt
	}
	if rawSp, ok := value["system_prompt"].(string); ok {
		settings.SystemPrompt = rawSp
	}

	path := filepath.Join(configDir, "settings.conf")
	tmp := filepath.Join(configDir, "settings.conf.tmp")
	text, err := json.MarshalIndent(settings, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, text, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return writeResult(w, nil)
}
