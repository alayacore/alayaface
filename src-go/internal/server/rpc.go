package server

import (
	"encoding/json"
	"log"
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

// rpcRecorder tracks whether the handler already wrote the response, so
// a panic AFTER a partial write is logged without emitting a second,
// superfluous error body (net/http would otherwise just reset the
// connection and the client would see a network error instead of JSON).
type rpcRecorder struct {
	http.ResponseWriter
	wrote bool
}

func (r *rpcRecorder) WriteHeader(code int) {
	r.wrote = true
	r.ResponseWriter.WriteHeader(code)
}

func (r *rpcRecorder) Write(b []byte) (int, error) {
	r.wrote = true
	return r.ResponseWriter.Write(b)
}

// handleRPC dispatches POST /rpc/{command} to the registered handler.
// Success: 200 + raw result JSON (mirrors Tauri invoke resolve).
// Failure: 4xx/5xx + {"error": msg} (mirrors Tauri rejection).
// A panicking handler is recovered and converted into a 500 JSON error
// instead of an aborted connection (net/http alone would just close it).
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

	recorder := &rpcRecorder{ResponseWriter: w}
	defer func() {
		if rec := recover(); rec != nil {
			log.Printf("[rpc] panic in %s: %v", cmd, rec)
			if !recorder.wrote {
				writeRPCError(w, &rpcError{status: http.StatusInternalServerError, msg: "internal error"})
			}
		}
	}()
	if err := fn(s.Handler, recorder, r); err != nil {
		writeRPCError(recorder, err)
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
