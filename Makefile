.PHONY: all elm run dev build test clean

ELM     := elm
CARGO   := cargo
ELM_SRC := src-elm
TAURI   := src-tauri

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
