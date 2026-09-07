.PHONY: all elm run-tauri dev build-tauri test-tauri clean-tauri run-go build-go test-go check-parity check-invariants check-schema e2e clean-go

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
	cd $(TAURI) && $(CARGO) tauri build

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

# Backend command-parity check: the Elm client runs against both the
# Tauri (Rust) commands and the Go RPC registry; drift breaks one
# deployment silently. Also validates the command names bridge.js invokes.
.PHONY: check-parity
check-parity:
	./scripts/check-backend-parity.sh

# Layout invariants: windowPositions may only be READ through
# App/Windows' winRect/winRectList/hasWin (INV1), and the JS bridge stays
# free of solo behavior (SD7). The Elm client draws, drags and chains off
# geometry; a second read path means two models of what is on screen.
.PHONY: check-invariants
check-invariants:
	./scripts/check-layout-invariants.sh

# Model-config schema check: AlayaFace must model every model.conf field —
# :model_sync replaces the list, so an unmodelled key is deleted from the
# user's model.conf. Compares src-elm/src/Session/ModelConfig.elm against
# AlayaCore's protocol.ModelInfo (or the checked-in fixture when AlayaCore,
# a separate repo, is not checked out).
.PHONY: check-schema
check-schema:
	./scripts/check-model-schema.sh

# Run Go backend test suites (-race: the backends are concurrent by design —
# session readers, the hub, graceful close — and AGENTS.md requires -race
# before every commit; CI passes it too, so the target must not be the one
# place that silently skips it)
test-go:
	cd $(SRC_GO) && $(GO) vet ./... && $(GO) test ./... -race

# Headless-browser E2E for Plan Mode (Go backend + fakecore + system
# Chrome). Requires node + puppeteer-core (npm install once in e2e/) and
# google-chrome on PATH. No real model needed.
# Which scripts to run comes from e2e/scripts.txt — the SAME file CI reads.
# Four scripts rotted for weeks because they were in neither runner's list
# (and the lists had already drifted: CI ran 2, this target ran 7).
# Every script runs even after a failure and the target fails if any did:
# `|| exit 1` stops at the first and hides the rest.
e2e: elm
	cd e2e && $(NPM) install
	cd e2e && failed=""; for t in $$(grep -v '^\s*\#' scripts.txt | grep -v '^\s*$$'); do \
		echo "== $$t-e2e.mjs"; node "$$t-e2e.mjs" || failed="$$failed $$t"; done; \
	if [ -n "$$failed" ]; then echo "FAILED e2e suites:$$failed"; exit 1; fi; \
	echo "all e2e suites passed"

# Clean Go build artifacts
clean-go:
	rm -rf $(SRC_GO)/bin
