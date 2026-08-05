// Package server wires the HTTP server: RPC dispatcher, WebSocket
// event hub, and static file hosting for the shared Elm client.
package server

import (
	"log"
	"net/http"

	"github.com/gorilla/websocket"

	"alayaface/src-go/internal/hub"
	"alayaface/src-go/internal/server/handlers"
	"alayaface/src-go/internal/session"
)

// Server holds all shared state and routing.
type Server struct {
	Hub      *hub.Hub
	Sessions *session.Manager
	Cache    *session.ModelCache
	Handler  *handlers.Handler

	StaticDir string
	Token     string

	upgrader websocket.Upgrader
}

// New creates a server. token, when non-empty, is required on RPC calls
// (Authorization: Bearer) and WS connections (?token=).
func New(staticDir, token string) *Server {
	h := hub.New()
	mgr := session.NewManager()
	cache := session.NewModelCache()
	return &Server{
		Hub:       h,
		Sessions:  mgr,
		Cache:     cache,
		Handler:   &handlers.Handler{Sessions: mgr, Hub: h, Cache: cache},
		StaticDir: staticDir,
		Token:     token,
		upgrader: websocket.Upgrader{
			// Loopback-only server; same-origin Elm page.
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
}

// Routes returns the root HTTP handler.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /rpc/{command}", s.handleRPC)
	mux.HandleFunc("GET /ws", s.handleWS)
	mux.Handle("/", s.staticHandler())
	return mux
}

// staticHandler serves the Elm frontend from StaticDir.
func (s *Server) staticHandler() http.Handler {
	fs := http.FileServer(http.Dir(s.StaticDir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		fs.ServeHTTP(w, r)
	})
}

// authorized reports whether the request carries the bearer token.
func (s *Server) authorized(r *http.Request) bool {
	if s.Token == "" {
		return true
	}
	auth := r.Header.Get("Authorization")
	if len(auth) > 7 && auth[:7] == "Bearer " && auth[7:] == s.Token {
		return true
	}
	return false
}

func (s *Server) logRequest(r *http.Request) {
	log.Printf("[rpc] %s %s", r.Method, r.URL.Path)
}
