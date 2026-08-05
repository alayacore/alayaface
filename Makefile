.PHONY: all elm run dev build test clean run-go build-go test-go clean-go

ELM       := elm
CARGO     := cargo
GO        := go
ELM_SRC   := src-elm
TAURI     := src-tauri
SRC_GO := src-go

all: elm

# Compile Elm frontend
elm:
	cd $(ELM_SRC) && $(ELM) make src/Main.elm --output=elm.js

# Run Tauri desktop app (auto-compiles Elm first)
run: elm
	cd $(TAURI) && $(CARGO) run

# Alias for run
dev: run

# Build release binary
build: elm
	cd $(TAURI) && $(CARGO) build --release

# Run all test suites (Rust unit tests + Elm tests)
test:
	cd $(TAURI) && $(CARGO) test
	cd $(ELM_SRC) && elm-test

# Clean build artifacts
clean:
	rm -f $(ELM_SRC)/elm.js
	cd $(TAURI) && $(CARGO) clean
	rm -rf $(ELM_SRC)/elm-stuff

# ─── Go backend (browser/HTTP; shares the Elm client) ───────────────

# Run the Go backend: serves the Elm client + RPC/WS API.
# Binds 0.0.0.0 so the dev machine can be reached over SSH port
# forwarding or the LAN (e.g. http://<host>:8765). Add --token <t> to
# require a bearer token when the port is reachable by others.
run-go: elm
	cd $(SRC_GO) && $(GO) run ./cmd/alayaface-server --addr 0.0.0.0:8765 --static ../src-elm

# Build the Go backend binary
build-go: elm
	cd $(SRC_GO) && $(GO) build -o bin/alayaface-server ./cmd/alayaface-server

# Run Go backend test suites
test-go:
	cd $(SRC_GO) && $(GO) test ./...

# Clean Go build artifacts
clean-go:
	rm -rf $(SRC_GO)/bin
