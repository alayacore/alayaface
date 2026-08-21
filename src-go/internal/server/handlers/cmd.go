package handlers

import (
	"fmt"
	"net/http"
	"os"
	"path/filepath"

	"alayaface/src-go/internal/core"
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

// CheckAlayacore resolves the alayacore binary path and confirms it
// exists on disk. find_binary() already filters most candidates by
// os.Stat; the only branch that returns a non-existent path is the
// fallback ("alayacore" on PATH, which is not stat'd). We stat the
// returned path one more time so the result is decisive: if a stale
// ALAYACORE_BIN env var points to a deleted file, the env-var AND the
// `which` AND the candidate paths would all fail — the user gets a
// clear error pointing at the exact path that was tried.
func CheckAlayacore(h *Handler, w http.ResponseWriter, r *http.Request) error {
	path := core.FindBinary()
	if _, err := os.Stat(path); err == nil {
		return writeResult(w, AlayacoreCheck{OK: true, Path: path})
	}
	abs, _ := filepath.Abs(path)
	return writeResult(w, AlayacoreCheck{
		OK:    false,
		Path:  "",
		Error: fmt.Sprintf("AlayaCore binary not found at '%s'. Set the ALAYACORE_BIN environment variable or install alayacore on PATH.", abs),
	})
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

// Reason sends the "reason" command (reasoning level 0|1|2 as argument).
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
	if _, err := s.SendCmd("reason", fmt.Sprintf("%d", args.Level)); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// ModelSync sends the "model_sync" command (config JSON as argument).
func ModelSync(h *Handler, w http.ResponseWriter, r *http.Request) error {
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
	if _, err := s.SendCmd("model_sync", args.Config); err != nil {
		return err
	}
	return writeResult(w, nil)
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

// McpCancel sends the "mcp_cancel" command.
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
	if _, err := s.SendCmd("mcp_cancel", ""); err != nil {
		return err
	}
	return writeResult(w, nil)
}
