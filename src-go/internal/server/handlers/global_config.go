package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"

	"alayaface/src-go/internal/dirs"
)

// GlobalConfig is the cross-preset global config overlay
// (~/.alayaface/global.conf). Unlike per-preset settings.conf, this file
// applies to every preset. Fields present here override preset-level
// values when the effective settings are read (overlay semantics).
//
// RecursionLimit bounds Plan Mode recursion: a plan whose depth exceeds
// it gets no plan system prompt in its node sessions, so the model stops
// delegating (depth is counted 1 for top-level plans, +1 per parent plan;
// default 8).
type GlobalConfig struct {
	RecursionLimit int `json:"recursion_limit"`
}

// DefaultRecursionLimit is used when global.conf is missing or the value
// is absent/out of range.
const DefaultRecursionLimit = 8

// NormalizeRecursionLimit returns a sane limit: values below 1 fall back
// to the default (0 = absent = default; a limit must let at least the
// top-level plan run).
func NormalizeRecursionLimit(n int) int {
	if n < 1 {
		return DefaultRecursionLimit
	}
	return n
}

// readGlobalConfig reads the global config; a missing/empty file yields
// defaults. Parse errors are reported (a corrupt global.conf must not be
// silently ignored).
func readGlobalConfig() (GlobalConfig, error) {
	path := dirs.GlobalConfigFile()
	text, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return GlobalConfig{RecursionLimit: DefaultRecursionLimit}, nil
		}
		return GlobalConfig{}, err
	}
	if strings.TrimSpace(string(text)) == "" {
		return GlobalConfig{RecursionLimit: DefaultRecursionLimit}, nil
	}
	var cfg GlobalConfig
	if err := json.Unmarshal(text, &cfg); err != nil {
		return GlobalConfig{}, fmt.Errorf("Failed to parse global.conf: %w", err)
	}
	cfg.RecursionLimit = NormalizeRecursionLimit(cfg.RecursionLimit)
	return cfg, nil
}

// GetGlobalConfig returns the global config overlay.
func GetGlobalConfig(h *Handler, w http.ResponseWriter, r *http.Request) error {
	cfg, err := readGlobalConfig()
	if err != nil {
		return err
	}
	return writeJSON(w, cfg)
}

// SyncGlobalConfig replaces the global config overlay. Accepts
// {"recursion_limit": N}; writes atomically. The normalized config is
// returned so the frontend can adopt the effective values.
func SyncGlobalConfig(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Config string `json:"config"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	var cfg GlobalConfig
	if err := json.Unmarshal([]byte(args.Config), &cfg); err != nil {
		return fmt.Errorf("Invalid global config JSON: %w", err)
	}
	cfg.RecursionLimit = NormalizeRecursionLimit(cfg.RecursionLimit)

	if _, _, err := dirs.Ensure(); err != nil {
		return err
	}
	path := dirs.GlobalConfigFile()
	tmp := path + ".tmp"
	text, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, text, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return writeResult(w, cfg)
}
