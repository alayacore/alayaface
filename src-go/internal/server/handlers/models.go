package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"

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

	// Ask any connected session.
	found := false
	h.Sessions.ForEach(func(s *session.Session) bool {
		if s.Connected() {
			// SendCmd registers the call ID → name mapping so the
			// matching CO frame is rendered with the command name.
			_, _ = s.SendCmd("model_load", "")
			if !h.Cache.IsEmpty() {
				found = true
			}
			return true // only try the first connected session
		}
		return false
	})
	if found {
		return writeJSON(w, h.Cache.Get())
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
// (`preset` empty = active). Always reads the config directly via a
// temporary alayacore process (never the session cache), so it reflects
// what new sessions will load.
func ListDefaultModels(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		BinaryPath string `json:"binaryPath"`
		Preset     string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
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
	return writeJSON(w, models)
}

// SyncDefaultModels replaces the model list in a preset's model.conf
// (`preset` empty = active): spawns a temporary alayacore with that
// config dir and sends model_sync, waiting for the CO result. Validation,
// key-value serialization and persistence are all performed by alayacore.
func SyncDefaultModels(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		BinaryPath string `json:"binaryPath"`
		Config     string `json:"config"`
		Preset     string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	configDir, err := dirs.ResolveConfigDir(args.Preset)
	if err != nil {
		return err
	}
	bin := ResolveBinary(args.BinaryPath)

	callID := uuid.NewString()
	res, err := probe.RunTempProbe(bin, configDir, &probe.ProbeCmd{
		CallID: callID,
		Name:   "model_sync",
		Input:  args.Config,
	}, h.Cache)
	if err != nil {
		return err
	}

	if res.CmdOutput != nil {
		var v map[string]any
		if err := json.Unmarshal(res.CmdOutput, &v); err != nil {
			return err
		}
		if isErr, _ := v["is_error"].(bool); isErr {
			msg, _ := v["output"].(map[string]any)["message"].(string)
			if msg == "" {
				msg = "model_sync failed"
			}
			return fmt.Errorf("%s", msg)
		}
		out, _ := json.Marshal(v["output"])
		return writeJSON(w, json.RawMessage(out))
	}

	switch res.End {
	case probe.EndTimeout:
		return fmt.Errorf("model_sync timed out")
	case probe.EndEOF:
		return fmt.Errorf("alayacore exited before model_sync completed")
	default:
		return fmt.Errorf("failed to read from alayacore")
	}
}
