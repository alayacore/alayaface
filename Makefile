.PHONY: all elm run-tauri dev build-tauri test-tauri clean-tauri run-go build-go test-go e2e clean-go

ELM       := elm
CARGO     := cargo
GO        := go
ELM_SRC   := src-elm
TAURI     := src-tauri
SRC_GO := src-go
NPM       := npm

all: elm

# Compile Elm frontend
elm:
	cd $(ELM_SRC) && $(ELM) make src/Main.elm --output=elm.js

# ─── Tauri desktop app ──────────────────────────────────────────────

# Run the Tauri desktop app (auto-compiles Elm first)
run-tauri: elm
	cd $(TAURI) && $(CARGO) run

# Alias for run-tauri
dev: run-tauri

# Build release binary
build-tauri: elm
	cd $(TAURI) && $(CARGO) build --release

# Run Tauri test suites (Rust unit tests + Elm tests)
test-tauri:
	cd $(TAURI) && $(CARGO) test
	cd $(ELM_SRC) && elm-test

# Clean Tauri build artifacts
clean-tauri:
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

# Headless-browser E2E for Plan Mode (Go backend + fakecore + system
# Chrome). Requires node + puppeteer-core (npm install once in e2e/) and
# google-chrome on PATH. No real model needed.
e2e: elm
	cd e2e && $(NPM) install && node plan-e2e.mjs && node restart-e2e.mjs

# Clean Go build artifacts
clean-go:
	rm -rf $(SRC_GO)/bin
