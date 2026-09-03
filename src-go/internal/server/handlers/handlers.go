// Package handlers implements the RPC command handlers for the Go
// backend. Port of src-tauri/src/commands/*.
package handlers

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"alayaface/src-go/internal/core"
	"alayaface/src-go/internal/hub"
	"alayaface/src-go/internal/session"
)

// Handler carries the shared server state for all RPC commands.
type Handler struct {
	Sessions *session.Manager
	Hub      *hub.Hub
	Cache    *session.ModelCache
}

// Command is an RPC command handler: decode args, run logic, write result.
// Returning an error produces {"error": msg} with status 500 (or the
// status carried by an rpcError).
type Command func(h *Handler, w http.ResponseWriter, r *http.Request) error

// Registry maps Tauri command names to Go handlers (see docs/go-backend.md §3).
func Registry() map[string]Command {
	return map[string]Command{
		// sessions
		"create_session":     CreateSession,
		"resume_session":     ResumeSession,
		"close_session":      CloseSession,
		"close_all_sessions": CloseAllSessions,
		"list_session_dirs":  ListSessionDirs,
		"delete_session_dir": DeleteSessionDir,
		"fork_session":       ForkSession,
		// io
		"alayacore_send_prompt": SendPrompt,
		// cmd
		"alayacore_cancel":      CancelTask,
		"alayacore_model_set":   ModelSet,
		"alayacore_reason":      Reason,
		"alayacore_model_sync":  ModelSync,
		"alayacore_confirm":     ConfirmTool,
		"alayacore_mcp_decline": McpDecline,
		"alayacore_mcp_cancel":  McpCancel,
		// startup check (frontend probes on init)
		"check_alayacore": CheckAlayacore,
		// models
		"list_models":         ListModels,
		"list_default_models": ListDefaultModels,
		"sync_default_models": SyncDefaultModels,
		"set_default_model":   SetDefaultModel,
		// mcp
		"list_default_mcp": ListDefaultMcp,
		"sync_default_mcp": SyncDefaultMcp,
		// settings
		"get_global_settings":  GetGlobalSettings,
		"sync_global_settings": SyncGlobalSettings,
		// global config overlay (cross-preset)
		"get_global_config":  GetGlobalConfig,
		"sync_global_config": SyncGlobalConfig,
		// voice input ASR (cross-preset)
		"get_asr_config":  GetAsrConfig,
		"sync_asr_config": SyncAsrConfig,
		"asr_transcribe":  AsrTranscribe,
		// presets
		"list_presets":    ListPresets,
		"copy_preset":     CopyPreset,
		"rename_preset":   RenamePreset,
		"delete_preset":   DeletePreset,
		"reorder_presets": ReorderPresets,
		// fs
		"fs_list_dir":           FsListDir,
		"fs_home_dir":           FsHomeDir,
		"fs_resolve_path":       FsResolvePath,
		"fs_read_file_data_uri": FsReadFileDataUri,
		"fs_write_file_text":    FsWriteFileText,
		"fs_read_file_text":     FsReadFileText,
		"fs_delete_file":        FsDeleteFile,
		// content-addressed object store (C architecture)
		"object_put": ObjectPut,
		"object_get": ObjectGet,
		// mcp auth
		"start_mcp_auth_flow": StartMcpAuthFlow,
		"fill_mcp_auth_url":   FillMcpAuthUrl,
	}
}

// ─── Helpers ────────────────────────────────────────────────────────

// decodeArgs decodes the request body into v. An empty body is treated
// as {}.
func decodeArgs(r *http.Request, v any) error {
	defer r.Body.Close()
	dec := json.NewDecoder(r.Body)
	if err := dec.Decode(v); err != nil {
		// Compare with errors.Is, not err.Error(): the decoder wraps the
		// sentinel, and a message comparison silently stops matching on any
		// Go change (or a real syntax error whose text happens to differ).
		if errors.Is(err, io.EOF) {
			return nil // empty body → zero value args
		}
		return err
	}
	return nil
}

// writeResult writes the command return value (mirrors Tauri invoke
// resolve). A nil value writes an empty 200 body.
func writeResult(w http.ResponseWriter, v any) error {
	if v == nil {
		w.WriteHeader(http.StatusOK)
		return nil
	}
	w.Header().Set("Content-Type", "application/json")
	return json.NewEncoder(w).Encode(v)
}

// writeJSON writes a structured JSON payload.
func writeJSON(w http.ResponseWriter, v any) error {
	w.Header().Set("Content-Type", "application/json")
	return json.NewEncoder(w).Encode(v)
}

// ResolveBinary returns the configured binary path or the discovered one.
func ResolveBinary(binaryPath string) string {
	if binaryPath != "" {
		return binaryPath
	}
	return core.FindBinary()
}
