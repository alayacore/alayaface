package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"

	"alayaface/src-go/internal/dirs"
	"alayaface/src-go/internal/probe"
	"alayaface/src-go/internal/session"
)

// ListModels lists available models: cache → any connected session →
// temporary alayacore probe. Port of commands/models.rs list_models.
func ListModels(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		BinaryPath string `json:"binaryPath"`
		ConfigPath string `json:"configPath"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	// Try cache first.
	if !h.Cache.IsEmpty() {
		return writeJSON(w, h.Cache.Get())
	}

	// Ask any connected session: send model_load and WAIT for the SM
	// model_list reply to populate the cache. The reply arrives via the
	// reader goroutine (asynchronous), so checking the cache immediately
	// after SendCmd would always miss it and silently fall through to
	// the probe — while also spamming the live session with a pointless
	// model_load on every call.
	asked := false
	h.Sessions.ForEach(func(s *session.Session) bool {
		if !s.Connected() {
			return false // keep looking for a connected session
		}
		if _, err := s.SendCmd("model_load", ""); err == nil {
			asked = true
		}
		return true // only ask the first connected session
	})
	if asked {
		// Wait for the model_list SM (alayacore answers fast): sleep on
		// the cache's notification instead of polling — a Set that
		// happened before this call is still observed (WaitCh re-checks
		// under the cache lock). 2s bound; on timeout fall back to the
		// probe rather than hanging the RPC.
		select {
		case <-h.Cache.WaitCh():
			if !h.Cache.IsEmpty() {
				return writeJSON(w, h.Cache.Get())
			}
		case <-time.After(2 * time.Second):
		}
	}

	// Fallback: probe with a temporary process.
	bin := ResolveBinary(args.BinaryPath)
	res, err := probe.RunTempProbe(bin, args.ConfigPath, nil, h.Cache)
	if err != nil {
		return err
	}
	models := res.Models
	if models == nil {
		models = []json.RawMessage{}
	}
	return writeJSON(w, models)
}

// ListDefaultModels lists the model list from a preset's model.conf
// (preset REQUIRED) plus the preset's DEFAULT model id. Always reads the
// config directly via a temporary alayacore process (never the session
// cache), so it reflects what new sessions will load. The default
// (active) model is stored by alayacore in the preset's runtime.conf as
// `active_model: <name>`; the response's active_id is the matching index
// in the returned model list (null when none matches).
func ListDefaultModels(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		BinaryPath string `json:"binaryPath"`
		Preset     string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	// Ensure first so the seed presets exist on first run (preset is now
	// a required argument, so nothing else triggers Ensure here).
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	configDir, err := dirs.ResolveConfigDir(args.Preset)
	if err != nil {
		return err
	}
	bin := ResolveBinary(args.BinaryPath)
	res, err := probe.RunTempProbe(bin, configDir, nil, nil)
	if err != nil {
		return err
	}
	models := res.Models
	if models == nil {
		models = []json.RawMessage{}
	}
	// The default model id = the ID of the model whose name matches
	// runtime.conf's active_model (alayacore falls back to the first
	// model when the name is missing/unknown; model IDs are runtime IDs
	// carried by the model_list payload, not list indexes).
	var activeID *int
	if name, ok := readActiveModelName(configDir); ok {
		for _, m := range models {
			var obj struct {
				ID   int    `json:"id"`
				Name string `json:"name"`
			}
			if json.Unmarshal(m, &obj) == nil && obj.Name == name {
				id := obj.ID
				activeID = &id
				break
			}
		}
	}
	return writeJSON(w, map[string]any{"models": models, "active_id": activeID})
}

// readActiveModelName reads the `active_model: <name>` line from a
// preset's runtime.conf (alayacore-managed key:value file). Returns
// (name, false) when the file is missing or has no active_model.
func readActiveModelName(configDir string) (string, bool) {
	text, err := os.ReadFile(filepath.Join(configDir, "runtime.conf"))
	if err != nil {
		return "", false
	}
	for _, line := range strings.Split(string(text), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#") {
			continue
		}
		if idx := strings.Index(line, ":"); idx >= 0 {
			key := strings.TrimSpace(line[:idx])
			if key == "active_model" {
				value := strings.TrimSpace(line[idx+1:])
				if value == "" {
					return "", false
				}
				// alayacore writes strings DOUBLE-QUOTED
				// (`active_model: "MyModel"`), like model.conf.
				if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
					if unquoted, err := strconv.Unquote(value); err == nil {
						value = unquoted
					}
				}
				return value, true
			}
		}
	}
	return "", false
}

// SetDefaultModel sets a preset's DEFAULT model: spawns a temporary
// alayacore with the preset config dir and sends model_set, so alayacore
// persists `active_model: <name>` into the preset's runtime.conf. New
// sessions under the preset copy runtime.conf and start on that model.
func SetDefaultModel(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Preset  string `json:"preset"`
		ModelID uint32 `json:"modelId"`
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
	bin := ResolveBinary("")

	commandID := uuid.NewString()
	res, err := probe.RunTempProbe(bin, configDir, &probe.ProbeCmd{
		CommandID: commandID,
		Name:      "model_set",
		Args:      fmt.Sprintf("%d", args.ModelID),
	}, nil)
	if err != nil {
		return err
	}

	if res.CmdOutput != nil {
		var v map[string]any
		if err := json.Unmarshal(res.CmdOutput, &v); err != nil {
			return err
		}
		if isErr, _ := v["is_error"].(bool); isErr {
			msg, _ := v["result"].(map[string]any)["message"].(string)
			if msg == "" {
				msg = "model_set failed"
			}
			return fmt.Errorf("%s", msg)
		}
		out, _ := json.Marshal(v["result"])
		return writeJSON(w, json.RawMessage(out))
	}

	switch res.End {
	case probe.EndTimeout:
		return fmt.Errorf("model_set timed out")
	case probe.EndEOF:
		return fmt.Errorf("alayacore exited before model_set completed")
	default:
		return fmt.Errorf("Failed to read from alayacore")
	}
}

// SyncDefaultModels replaces a preset's model.conf with `config` (the whole
// file, see Session.ModelConfig.encodeModels).
//
// Since AlayaCore v19 the wire has no model-list write path, so the adapter
// writes the file — but it must not write a file the core would reject. The
// candidate is therefore committed in a THROWAWAY config dir first and read
// back with model_load; only a clean load is written to the preset. A rejected
// candidate leaves the user's file untouched, which is what model_sync's
// validate-then-persist used to guarantee.
func SyncDefaultModels(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		BinaryPath string `json:"binaryPath"`
		Config     string `json:"config"`
		Preset     string `json:"preset"`
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
	target := filepath.Join(configDir, "model.conf")
	bin := ResolveBinary(args.BinaryPath)

	// An empty list writes an empty file. There is nothing to validate (the
	// core treats an empty model.conf as "no config" and would create its
	// defaults in the probe, which is not this file's meaning), and the cache
	// must say "no models" rather than keep the previous list.
	if strings.TrimSpace(args.Config) == "" {
		if err := dirs.WriteFileAtomicMode(target, []byte(""), 0o600); err != nil {
			return err
		}
		h.Cache.Set([]json.RawMessage{})
		return writeJSON(w, nil)
	}

	scratch, err := os.MkdirTemp("", "alayaface-model-probe-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(scratch)

	// Copy runtime.conf so the probe resolves the SAME active model the preset
	// would: model_load reinitializes it, and a keyless local model that is
	// not active must not fail the candidate (the core refuses to switch to a
	// model with no API key).
	if runtime, err := os.ReadFile(filepath.Join(configDir, "runtime.conf")); err == nil {
		if err := os.WriteFile(filepath.Join(scratch, "runtime.conf"), runtime, 0o600); err != nil {
			return err
		}
	}

	if err := os.WriteFile(filepath.Join(scratch, "model.conf"), []byte(args.Config), 0o600); err != nil {
		return err
	}
	res, err := probe.RunTempProbe(bin, scratch, &probe.ProbeCmd{
		CommandID: uuid.NewString(),
		Name:      "model_load",
		Args:      "",
		// Do NOT let the scratch probe fill the real cache: its SM model_list
		// can be the pre-load (default) list. The committed list is set below
		// from the CO that answers model_load.
	}, nil)
	if err != nil {
		return err
	}

	if res.CmdOutput == nil {
		switch res.End {
		case probe.EndTimeout:
			return fmt.Errorf("model_load timed out")
		case probe.EndEOF:
			return fmt.Errorf("alayacore exited before model_load completed")
		default:
			return fmt.Errorf("Failed to read from alayacore")
		}
	}

	var co struct {
		IsError bool `json:"is_error"`
		Result  struct {
			Message string            `json:"message"`
			Models  []json.RawMessage `json:"models"`
		} `json:"result"`
	}
	if err := json.Unmarshal(res.CmdOutput, &co); err != nil {
		return err
	}
	if co.IsError {
		msg := co.Result.Message
		if msg == "" {
			msg = "model_load failed"
		}
		return fmt.Errorf("%s", msg)
	}

	// Commit only after the core accepted the exact bytes.
	if err := dirs.WriteFileAtomicMode(target, []byte(args.Config), 0o600); err != nil {
		return err
	}
	models := co.Result.Models
	if models == nil {
		models = res.Models
	}
	if models == nil {
		models = []json.RawMessage{}
	}
	h.Cache.Set(models)
	return writeJSON(w, map[string]any{"models": models})
}
