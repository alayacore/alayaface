// Package server wires the HTTP server: RPC dispatcher, WebSocket
// event hub, and static file hosting for the shared Elm client.
package server

import (
	"bytes"
	"html"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"

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

	StaticDir   string
	Token       string
	cachedIndex []byte

	// allowHosts restricts which Host headers are served (see authz.go).
	// Empty = any host, so a no-token server stays usable on the LAN as
	// documented in README.md; set it (or use --token) when the address is
	// reachable by people you do not trust.
	allowHosts []string

	upgrader websocket.Upgrader
}

// Option configures a Server at construction time.
type Option func(*Server)

// WithAllowedHosts sets the Host allowlist (see authz.go's hostAllowed).
// Entries may carry a port ("192.168.1.20:8765"); a bare entry then matches
// any port. The single entry "*" disables the restriction.
func WithAllowedHosts(hosts []string) Option {
	return func(s *Server) { s.allowHosts = hosts }
}

// New creates a server. token, when non-empty, is required on RPC calls
// (Authorization: Bearer) and WS connections (?token=).
func New(staticDir, token string, opts ...Option) *Server {
	h := hub.New()
	mgr := session.NewManager()
	cache := session.NewModelCache()

	var cachedIndex []byte
	if _, err := os.Stat(filepath.Join(staticDir, "index.html")); err == nil {
		cachedIndex, _ = os.ReadFile(filepath.Join(staticDir, "index.html"))
	}

	s := &Server{
		Hub:         h,
		Sessions:    mgr,
		Cache:       cache,
		Handler:     &handlers.Handler{Sessions: mgr, Hub: h, Cache: cache},
		StaticDir:   staticDir,
		Token:       token,
		cachedIndex: cachedIndex,
		upgrader: websocket.Upgrader{
			// Same-origin check: the page is served by this server, so
			// its Origin host must match the request Host. This blocks
			// malicious websites from subscribing to the event stream
			// (WebSocket bypasses CORS; without this check any origin
			// could eavesdrop on conversations). Requests without an
			// Origin header (curl, local tools) are allowed.
			//
			// NOTE: this alone does not stop DNS rebinding (where Origin
			// and Host agree because both are attacker-supplied) —
			// Server.checkAccess adds Sec-Fetch-Site, the Host
			// allowlist and the RPC content-type rule on top.
			CheckOrigin: func(r *http.Request) bool {
				origin := r.Header.Get("Origin")
				if origin == "" {
					return true
				}
				u, err := url.Parse(origin)
				if err != nil {
					return false
				}
				return u.Host == r.Host
			},
		},
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

// Routes returns the root HTTP handler. Every request first passes the
// access policy (authz.go), which is what keeps a drive-by browser page from
// reaching the destructive RPC commands.
func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /rpc/{command}", s.handleRPC)
	mux.HandleFunc("GET /ws", s.handleWS)
	mux.Handle("/", s.staticHandler())
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if err := s.checkAccess(r); err != nil {
			s.logRequest(r)
			writeRPCError(w, err)
			return
		}
		mux.ServeHTTP(w, r)
	})
}

// staticHandler serves the Elm frontend from StaticDir. When a token is
// configured, the index document gets a
// <meta name="alayaface-token" content="..."> tag injected so bridge.js
// can attach the token to its RPC calls (Authorization header) and the
// WebSocket connection (?token=). Without this the documented --token
// mode would reject every request the shipped client makes — bridge.js
// has no other way to learn the token (the page itself is the
// credential, served by this same server).
func (s *Server) staticHandler() http.Handler {
	fs := http.FileServer(http.Dir(s.StaticDir))
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-cache")
		if s.Token == "" || !servesIndex(r.URL.Path) {
			fs.ServeHTTP(w, r)
			return
		}
		if s.cachedIndex == nil {
			fs.ServeHTTP(w, r)
			return
		}
		meta := `<meta name="alayaface-token" content="` + html.EscapeString(s.Token) + `">`
		headEnd := bytes.Index(bytes.ToLower(s.cachedIndex), []byte("</head>"))
		if headEnd < 0 {
			headEnd = len(s.cachedIndex)
		}
		index := append(s.cachedIndex[:headEnd], append([]byte(meta), s.cachedIndex[headEnd:]...)...)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write(index)
	})
}

// servesIndex reports whether the request path resolves to the app's
// index document (the only page that needs the token meta tag).
func servesIndex(path string) bool {
	return path == "/" || path == "" || path == "/index.html"
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
