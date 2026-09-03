// alayaface-server is the Go backend for AlayaFace: it hosts the shared
// Elm client and provides the RPC + WebSocket API for managing AlayaCore
// sessions. See docs/go-backend.md.
package main

import (
	"context"
	"flag"
	"log"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"alayaface/src-go/internal/dirs"
	"alayaface/src-go/internal/server"
)

// hostList is a repeatable / comma-separated flag value (the Host allowlist).
type hostList []string

func (h *hostList) String() string { return strings.Join(*h, ",") }

func (h *hostList) Set(v string) error {
	for _, part := range strings.Split(v, ",") {
		if part = strings.TrimSpace(part); part != "" {
			*h = append(*h, part)
		}
	}
	return nil
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8765", "listen address")
	static := flag.String("static", "../src-elm", "directory of the Elm frontend assets")
	token := flag.String("token", "", "optional bearer token (RPC: Authorization header, WS: ?token=)")
	bin := flag.String("alayacore-bin", "", "path to the alayacore binary (default: ALAYACORE_BIN env or PATH discovery)")
	configPath := flag.String("config-path", "", "base directory for AlayaFace config (presets, sessions, etc.); overrides $HOME/.alayaface. Leading \"~\" is expanded against $HOME.")
	var allowHosts hostList
	flag.Var(&allowHosts, "allow-host", "restrict serving to this Host header (repeatable or comma-separated; \"*\" = any). Defeats DNS rebinding; needed when the client is reached by a name the operator controls, e.g. --allow-host 192.168.1.20:8765.")
	flag.Parse()

	// Install the override BEFORE anything reads the config dir
	// (server.New wires handlers, and the session manager starts
	// accepting RPCs as soon as Routes() is mounted).
	if *configPath != "" {
		dirs.SetConfigPath(*configPath)
	}

	if *bin != "" {
		// core.FindBinary checks ALAYACORE_BIN first; the flag takes
		// precedence over the environment (handlers pass empty binaryPath,
		// so FindBinary is the only resolution path).
		_ = os.Setenv("ALAYACORE_BIN", *bin)
	}

	srv := server.New(*static, *token, server.WithAllowedHosts(allowHosts))
	httpSrv := &http.Server{
		Addr:    *addr,
		Handler: srv.Routes(),
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	go func() {
		log.Printf("alayaface-server listening on http://%s (static: %s)", *addr, *static)
		if server.IsExposedAddr(*addr) && *token == "" && len(allowHosts) == 0 {
			// Cross-origin browser calls are refused regardless (authz.go),
			// but anyone who can reach this port directly and load the page
			// can use the whole API — including the file and session
			// commands. Say so out loud; `make run-go` binds 0.0.0.0.
			log.Printf("WARNING: listening on a non-loopback address with no --token: anyone who can reach the port can drive the API (sessions, fs_write_file_text, delete_session_dir). Add --token <t>, and --allow-host <name> to also pin the Host.")
		}
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	<-ctx.Done()
	// Stop accepting requests FIRST so no new session can be created
	// after the close sweep starts — the previous order (close sessions,
	// then shutdown) let a create_session racing shutdown slip past the
	// sweep and orphan its alayacore child when the process exited.
	log.Println("shutting down: stopping HTTP…")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := httpSrv.Shutdown(shutdownCtx); err != nil {
		log.Printf("shutdown error: %v", err)
	}
	// Cancel-first graceful close (cancel → save → EOF, SIGKILL only
	// after the grace period) so in-flight tasks are aborted cleanly and
	// their history is persisted — a hard kill would lose the partial
	// conversation. Runs in parallel, bounded by one grace period.
	log.Println("closing sessions…")
	srv.Sessions.CloseAllGracefully()
	log.Println("bye")
}
