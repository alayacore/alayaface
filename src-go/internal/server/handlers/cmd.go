package handlers

import (
	"fmt"
	"net/http"
)

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
