package server

import (
	"encoding/json"
	"net/http"

	"alayaface/src-go/internal/server/handlers"
)

// rpcError carries an HTTP status with an error message.
type rpcError struct {
	status int
	msg    string
}

func (e *rpcError) Error() string { return e.msg }

// rpcHandlers is built once; handlers.Registry() allocates a fresh map
// on every call, so cache it.
var rpcHandlers = handlers.Registry()

// handleRPC dispatches POST /rpc/{command} to the registered handler.
// Success: 200 + raw result JSON (mirrors Tauri invoke resolve).
// Failure: 4xx/5xx + {"error": msg} (mirrors Tauri rejection).
func (s *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	s.logRequest(r)
	if !s.authorized(r) {
		writeRPCError(w, &rpcError{status: http.StatusUnauthorized, msg: "unauthorized"})
		return
	}

	cmd := r.PathValue("command")
	fn, ok := rpcHandlers[cmd]
	if !ok {
		writeRPCError(w, &rpcError{status: http.StatusNotFound, msg: "unknown command: " + cmd})
		return
	}
	if err := fn(s.Handler, w, r); err != nil {
		writeRPCError(w, err)
	}
}

// writeRPCError writes {"error": msg} with an appropriate status.
func writeRPCError(w http.ResponseWriter, err error) {
	status := http.StatusInternalServerError
	if re, ok := err.(*rpcError); ok {
		status = re.status
	} else if _, ok := err.(*json.SyntaxError); ok {
		status = http.StatusBadRequest
	} else if _, ok := err.(*json.UnmarshalTypeError); ok {
		status = http.StatusBadRequest
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}
