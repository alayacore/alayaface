package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"alayaface/src-go/internal/core"
	"alayaface/src-go/internal/dirs"
)

// AlayacoreCheck is the result of the startup check_alayacore RPC. The
// frontend probes this on init() so the home screen can show a
// "AlayaCore not found" banner when the binary is missing, instead of
// letting the user click New Session and only learn at spawn time.
type AlayacoreCheck struct {
	OK    bool   `json:"ok"`
	Path  string `json:"path"`
	Error string `json:"error"`
}

// CheckAlayacore resolves the alayacore binary path, confirms it
// exists on disk, and verifies its wire protocol `message_version`
// matches the one this adapter implements. find_binary() already
// filters most candidates by os.Stat; the only branch that returns a
// non-existent path is the fallback ("alayacore" on PATH, which is
// not stat'd). We stat the returned path one more time so the result
// is decisive: if a stale ALAYACORE_BIN env var points to a deleted
// file, the env-var AND the `which` AND the candidate paths would all
// fail — the user gets a clear error pointing at the exact path that
// was tried.
//
// When the binary IS reachable, we also probe its protocol version by
// spawning it briefly and reading its first boot SM frame
// (`{"type":"version","data":{"message_version":N,...}}`). A wrong
// version is as unusable as a missing binary (the wire format has
// drifted — silently talking to a mismatched core is worse than
// refusing to start), so the same `OK=false` UX is surfaced with a
// message that names the observed and expected versions.
func CheckAlayacore(h *Handler, w http.ResponseWriter, r *http.Request) error {
	path := core.FindBinary()
	if _, err := os.Stat(path); err != nil {
		abs, _ := filepath.Abs(path)
		return writeResult(w, AlayacoreCheck{
			OK:    false,
			Path:  "",
			Error: fmt.Sprintf("AlayaCore binary not found at '%s'. Set the ALAYACORE_BIN environment variable or install alayacore on PATH.", abs),
		})
	}
	// Binary exists on disk; verify the protocol version matches
	// what this adapter implements. The probe spawns alayacore
	// briefly and kills it — same UX surface as a missing binary
	// (OK=false, empty path, descriptive error).
	if err := core.CheckMessageVersion(path); err != nil {
		return writeResult(w, AlayacoreCheck{
			OK:    false,
			Path:  "",
			Error: err.Error(),
		})
	}
	return writeResult(w, AlayacoreCheck{OK: true, Path: path})
}

// CancelTask sends the "cancel" command to a session.
func CancelTask(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	if _, err := s.SendCmd("cancel", ""); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// ModelSet sends the "model_set" command (modelId as argument string).
func ModelSet(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
		ModelID   uint32 `json:"modelId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	if _, err := s.SendCmd("model_set", fmt.Sprintf("%d", args.ModelID)); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// Reason sends the "reasoning_level_set" command (level 0|1|2 as argument).
func Reason(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
		Level     uint32 `json:"level"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	if _, err := s.SendCmd("reasoning_level_set", fmt.Sprintf("%d", args.Level)); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// WriteSessionModels replaces one session's model.conf with the whole file
// (`config`, see Session.ModelConfig.encodeModels), then makes the running
// session reload it.
//
// This replaced alayacore_model_sync when AlayaCore v19 removed the wire-side
// write path: the adapter now owns the file. It is still transactional from the
// caller's point of view:
//
//   - the previous text is kept, so a refusal can put it back;
//   - the file is written atomically and 0600 (it can hold the only copy of an
//     API key, and AlayaCore writes it 0600);
//   - model_load is sent with a WAIT on its CO, and an error result (a busy
//     session is the common one — model_load is idle-only) restores the
//     previous file before the error reaches the UI.
//
// The model list the core broadcasts on success refreshes the session's rows
// through the normal SM path; the RPC's answer only closes the editor.
func WriteSessionModels(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
		Config    string `json:"config"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	path := filepath.Join(s.SessionDir, "config", "model.conf")
	previous, readErr := os.ReadFile(path)
	if readErr != nil && !os.IsNotExist(readErr) {
		// Refuse to touch a file we cannot read: restoring it is the whole
		// safety property, and a permission error is not "there was no file".
		return fmt.Errorf("cannot read %s: %w", path, readErr)
	}
	existed := readErr == nil

	if err := dirs.WriteFileAtomicMode(path, []byte(args.Config), 0o600); err != nil {
		return err
	}

	raw, loadErr := s.SendCmdWait("model_load", "", 5*time.Second)
	if loadErr != nil {
		restoreModelConf(path, previous, existed)
		return loadErr
	}

	var co struct {
		IsError bool `json:"is_error"`
		Result  struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"result"`
	}
	if err := json.Unmarshal(raw, &co); err != nil {
		restoreModelConf(path, previous, existed)
		return fmt.Errorf("model_load: unreadable result: %w", err)
	}
	if co.IsError {
		restoreModelConf(path, previous, existed)
		// A CONFIG_* refusal happened INSIDE the handler, and model_load
		// replaces the in-memory list BEFORE it reports validation errors
		// (loadFromFile runs first). Restoring the file alone would leave the
		// running session on the candidate, so reload the restored file to make
		// memory and disk agree again. A STATE_* refusal (the usual one:
		// model_load is idle-only) never entered the handler and changed
		// nothing.
		if strings.HasPrefix(co.Result.Code, "CONFIG_") {
			_, _ = s.SendCmd("model_load", "")
		}
		msg := co.Result.Message
		if msg == "" {
			msg = "model_load failed"
		}
		return fmt.Errorf("%s", msg)
	}
	return writeResult(w, nil)
}

// restoreModelConf undoes a model.conf replacement. When the file did not
// exist, restoring it means deleting ours (AlayaCore recreates the default
// config on the next load).
func restoreModelConf(path string, previous []byte, existed bool) {
	if !existed {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			log.Printf("[model] failed to remove %s: %v", path, err)
		}
		return
	}
	if err := dirs.WriteFileAtomicMode(path, previous, 0o600); err != nil {
		log.Printf("[model] failed to restore %s: %v", path, err)
	}
}

// ConfirmTool sends tool_confirm or tool_decline for a pending tool call.
func ConfirmTool(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
		ID        string `json:"id"`
		Allowed   bool   `json:"allowed"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	name := "tool_decline"
	if args.Allowed {
		name = "tool_confirm"
	}
	if _, err := s.SendCmd(name, args.ID); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// McpDecline sends the "mcp_decline" command for a server.
func McpDecline(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
		Server    string `json:"server"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	if _, err := s.SendCmd("mcp_decline", args.Server); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// McpCancel sends the "mcp_skip" command (cancels MCP initialization).
func McpCancel(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	s, err := h.Sessions.Get(args.SessionID)
	if err != nil {
		return err
	}
	if _, err := s.SendCmd("mcp_skip", ""); err != nil {
		return err
	}
	return writeResult(w, nil)
}
