# AlayaFace

[![CI](https://github.com/wallacegibbon/alayaface/actions/workflows/ci.yml/badge.svg)](https://github.com/wallacegibbon/alayaface/actions/workflows/ci.yml)

A Tauri GUI frontend for [AlayaCore](https://github.com/alayacore/alayacore).
Built with **Elm** for the frontend and **Rust** for the Tauri backend.

## Architecture

The codebase is three parallel source trees: **src-elm/** — a pure Elm
frontend (no npm, no bundler), with domain modules (App, Plan, Session,
Overlay) and a thin JS bridge (`transport.js`) that abstracts the backend
transport (Tauri IPC or HTTP/WebSocket); **src-tauri/** — the Rust Tauri
backend (IPC commands, session lifecycle, TLV protocol); and **src-go/** —
a Go backend (HTTP + WebSocket) that serves the same Elm client and is a
port of the Rust backend, so either backend can run the app. Both backends
speak the TLV wire protocol to an AlayaCore subprocess over stdin/stdout;
the Elm core has no Tauri dependencies and is platform-agnostic.

### Data Flow

```
AlayaCore (subprocess)
    │  stdout: TLV frames
    ▼
backend reader (reader.rs / internal/session/reader.go)
    │  app.emit("tlv-frame") 或 hub.Broadcast("tlv-frame")
    ▼
transport.js → listen("tlv-frame")   ← Tauri event 或 WS /ws 推送
    │
    ▼  Elm port
Main.elm → subscriptions → Ports.onFrame → FrameEvent raw
    │
    ▼  Decode + handle
Handlers.elm → handleFrameEvent → update SessionState
    │
    ▼  Render
Main.elm → view → HTML
```

## Requirements

- [Elm](https://elm-lang.org/) 0.19.2 (`elm` in PATH)
- [elm-test](https://elm-test.readthedocs.io/) for running the Elm test suite
- [Rust](https://www.rust-lang.org/) with Cargo
- [AlayaCore](https://github.com/alayacore/alayacore) binary (`alayacore` in PATH or `ALAYACORE_BIN` env var)
- Linux: `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, etc. (see [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/))
- [Go](https://go.dev/) 1.22+ (Go backend only)

## Quick Start

```bash
make run     # Tauri desktop app
make run-go  # Go backend (browser: http://127.0.0.1:8765, binds 0.0.0.0)
```

### Individual commands

```bash
make elm      # Compile Elm frontend only (src-elm/ → elm.js)
make run      # Compile Elm + launch Tauri
make dev      # Alias for run
make build    # Release build
make test     # Run Rust unit tests + Elm tests
make clean    # Remove build artifacts
make run-go   # Go backend: serves the Elm client + RPC/WS API
make build-go # Build Go backend binary
make test-go  # Run Go unit tests
make clean-go # Remove Go build artifacts
```

### Manual build

```bash
cd src-elm && elm make src/Main.elm --output=elm.js
cd ../src-tauri && cargo run
```

## Go Backend (browser / HTTP)

The same Elm client also runs against a Go backend (`src-go/`) that
hosts the frontend and implements the equivalent of the Tauri commands as
an HTTP API. `bridge.js` auto-detects the runtime: with `window.__TAURI__`
present it uses Tauri IPC, otherwise it uses `fetch` + WebSocket.

```bash
make run-go
# open http://127.0.0.1:8765/ (local) or http://<host>:8765/ (LAN)
```

The server binds `0.0.0.0:8765` (all interfaces), so it can be reached
over SSH port forwarding (`ssh -L 8765:localhost:8765 <host>` then open
`http://127.0.0.1:8765/`) or directly on the LAN — handy for dev/debug.

Options:

```
alayaface-server --addr 0.0.0.0:8765 --static ../src-elm [--token <token>]
```

> ⚠️ With `0.0.0.0` and no `--token`, anyone who can reach the port can
> create sessions and read files via the API. Add `--token <t>` when the
> port is exposed beyond localhost/SSH. The token is injected into the
> served page (`<meta name="alayaface-token">`) and `bridge.js` attaches
> it automatically (RPC `Authorization: Bearer`, WS `?token=`), so the
> browser client works unchanged; anyone who can fetch the page itself
> also gets the token (the page is the credential).

- Commands: `POST /rpc/{command}` with JSON args (mirrors Tauri `invoke`).
- Events: WebSocket `GET /ws` pushes `{type, payload}` messages
  (`tlv-delta`, `tlv-frame`, `core-status`).
- See `docs/go-backend.md` for the full API mapping and design
  (historical phase records: `docs/archive/TODO.md`).

## Plan Mode (DAG task planning & execution)

Plan Mode turns a big task into a dependency graph that AlayaFace executes
for you:

1. **Plan**: in any session, ask the model to decompose the task and output
   a fenced ```json block (schema in `docs/plan-mode.md` §5). The plan is
   auto-created when the block explicitly carries the top-level
   `"type": "alayaface-plan"` marker, so ordinary ```json code samples never
   trigger it.
2. **Save**: the plan is validated (unique ids, deps exist, no cycles),
   normalized, and written to `~/.alayaface/sessions/<originSessionId>/plans/<planId>/<planId>.json`
   (every plan lives inside the session that created it).
3. **Run**: each plan opens in its own **window** (like a session window —
   drag / resize / close, and the ⚙ menu lists all open plans). The DAG is
   shown in the window; **Run** launches each task in its own session window
   — the **top-level plan waits for your Run click; sub-plans auto-run**.
   **Clicking a node opens its session** (focusing it, or automatically
   resuming it from disk if it was closed / after a restart — bindings are
   persisted in `<plan>.run.json`), respecting dependencies and parallelism
   (`concurrency`, default 8). Tasks run under their node-level `preset` /
   `tools` (see below) with tool confirmation auto-approved.
4. **Retry**: failed tasks record the failure reason and attempt number
   (shown on the node and in the detail panel), auto-retry up to
   `max_attempts` (default 3, 2s backoff), then mark dependents **Blocked**.
   Failed/canceled nodes can be retried manually. Run state persists to
   `<plan>.run.json` — **Load run** resumes unfinished tasks after a restart.

### Presets and tool sets

- `~/.alayaface/presets/<name>/` bundles a model list (`model.conf`), MCP
  servers (`mcp.conf`) and AlayaFace-owned `settings.conf`
  (`tool_confirm`, `builtin_tools`, `reasoning_level` 0|1|2,
  `system_prompt`) — edit via **Preset Manager** → Edit → Settings.
- `~/.alayaface/global.conf` is the **cross-preset global config overlay**
  (applies to every preset): currently `recursion_limit` (default 8) —
  edit via ⚙ → **Global config**. Plan Mode recursion is bounded by it:
  node sessions of a plan whose depth (top-level = 1, each sub-plan +1,
  persisted in the plan's `meta.json`) exceeds the limit get **no plan
  system prompt**, so the model stops creating sub-plans.
- Built-in tools are passed to AlayaCore as `--builtin-tools=id1,id2,...`
  on session start (empty = all tools). Per preset (Settings editor) or
  per plan node (`tools` field).
- Seed presets are created on first run: `Default`, `Fast`, `Deep`,
  `Data`, and `Safe` (no `execute_command`). Copy/rename them in the
  Presets manager; plan nodes select one via `"preset": "Name"`.

**Plan recursion is model-autonomous**: only the **top-level plan** needs
your Run click; every **sub-plan** (a node's model outputting another plan
JSON) is auto-created **and auto-runs** — node sessions execute with tools
auto-approved, so the top-level Run click is the single human gate for the
whole delegated subtree.

**AlayaCore is never modified** — every capability difference is expressed
through spawn arguments and preset config files.

**Plan node sessions are isolated**: every node of a plan runs with cwd
`sessions/<originSessionId>/plans/<planId>/work/` (created by the backend
on spawn), so tasks exchange files within the plan while plans stay
isolated from each other and from the backend's directory. **No task
timeouts** (removed in the R-series refactor): a hung node stays Running
until the user stops it or the session disconnects.

**Output injection**: a downstream node prompt may reference an upstream
task's result with `{{<taskId>.output}}` (e.g. `{{t1.output}}`); when the
downstream node launches, the template is replaced with the upstream
task's final answer (recorded on success, persisted in
`<plan>.run.json`, so it survives restarts). The node detail panel shows
each node's recorded output.

**Session close is cancel-first**: `close_session` now sends CI `cancel`
(AlayaCore aborts the running task and auto-saves the conversation up to
the cancel point), then `save`, then closes stdin — the child exits
immediately instead of draining a long task to completion. This is what
makes **Stop** actually stop every running node: a running task is
aborted (history kept up to the cancel point), not allowed to finish.
SIGKILL only after a 5s grace period. (AlayaCore itself is untouched;
`cancel` and `save` are its own commands.)

## Automated E2E (headless browser, no real model)

`make e2e` runs a full Plan Mode browser test — no GUI, no real model:

- builds `fakecore` (scriptable alayacore stand-in) + the Go backend,
  launches system Chrome headless via `puppeteer-core` (install once:
  `cd e2e && npm install`)
- walks the real UI: New Session → prompt → fakecore answers with a
  fenced plan JSON → the Plan window **auto-creates** (R2, no button) →
  Plan window DAG → concurrency override → **Run** → nodes succeed (t2
  fails once via a marker, then auto-retries) → run completes → status
  bar shows Completed → clicking a node activates its session with the
  assistant reply; Stop / resume / Browse-import / marker-rejection paths
  are covered too
- asserts via DOM selectors, saves screenshots to a temp artifact dir
  (removed on exit; `ALAYAFACE_KEEP_ARTIFACTS=1` keeps them for debugging),
  and cleans up the server/Chrome/tmp dir — Ctrl-C also kills the backend
  child so no orphan server is left behind

This already caught real bugs that unit tests missed (see
`docs/archive/TODO.md` P15).
It does **not** cover real-model behavior — that still needs an OpenAI
compatible API key (or a local `.gguf`) for `manual-acceptance.md`.

## CI (GitHub Actions)

`.github/workflows/ci.yml` runs on push to `main` and on pull requests:
**Go** (`go vet` + `go test -race`), **Elm** (`elm make` + `elm-test`),
**Tauri/Rust** (`cargo test` + `cargo build` — full app compile), and a
full **E2E** job (Go backend + fakecore + headless Chrome, running both
`plan-e2e.mjs` and `restart-e2e.mjs`). Status badge at the top of this
file.

## TLV Protocol

AlayaFace communicates with AlayaCore via TLV (Tag-Length-Value) frames
over stdin/stdout. See the [adapter guide](../alayacore/adapter-guide/README.md)
for the full protocol specification.

Key tags:

| Tag | Direction | Description |
|-----|-----------|-------------|
| UT  | stdin     | User text input |
| UI  | stdin     | User image (data URI or URL) |
| UE  | stdin     | User message end (flush) |
| At  | stdout    | Assistant text streaming delta |
| Ar  | stdout    | Assistant reasoning streaming delta |
| Af  | stdout    | Tool argument streaming delta |
| Uf  | stdout    | Tool result preview snapshot (ephemeral, display-only; UF overwrites) |
| AT  | stdout    | Assistant text complete |
| AR  | stdout    | Assistant reasoning complete |
| AF  | stdout    | Tool call lifecycle |
| UF  | stdout    | Tool result |
| SM  | stdout    | System message (JSON) |

All stdout frames are prefixed with `\x00<history_id>\x00` for streaming
correlation.

## Debugging

TLV frame logs are printed to stderr with the `[tlv]` prefix:

```
[tlv] << abc-123 AT 0b
[tlv] >> abc-123 UT 15b :cancel
[tlv] << abc-123 SM 80b {"type":"task",...}
```

These appear in the terminal when running `cargo run`.

## Porting to Web / VS Code

The Elm core is platform-agnostic (`Session/` modules have no Tauri
dependencies), and `bridge.js` already abstracts the backend transport:

- With `window.__TAURI__` → Tauri IPC (`tauriTransport`)
- Without it → `fetch POST /rpc/{command}` + WebSocket `/ws`
  (`httpTransport`, used by the Go backend)

To port to another target (e.g. VS Code postMessage), add another
transport implementation at the top of `bridge.js`; the Elm ports and
`Session/` modules remain unchanged.
