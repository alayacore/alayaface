# TODO: Go Backend Implementation (AlayaFace)

Tracking file for implementing the Go backend (`src-go/`) per
`docs/go-backend.md`. If this file is left with unchecked items, the next
agent should continue from the first unchecked task.

> This file is git-ignored (working notes only). Update checkboxes as you go.
> `[x]` = done & verified (compiles / tests pass / smoke-tested).

## Context (read first)

- Shared Elm client: `src-elm/src/**` — do NOT modify (except `bridge.js` in P4).
- Contract: JSON shapes must match Rust serde output exactly — see
  `docs/go-backend.md` §3/§4 and `src-elm/src/Session/Protocol.elm`.
- Rust reference implementation: `src-tauri/src/**` (tlv.rs, alayacore.rs,
  session.rs, reader.rs, dirs.rs, commands/*).
- `docs/go-backend.md` = full design doc (transport, mapping table, layout,
  phased plan).
- Environment: Go 1.26, `alayacore` in PATH (`/home/wallace/go/bin/alayacore`).

## How to run / verify (after P0+P1)

```bash
cd src-go
go build ./...
go test ./...
go run ./cmd/alayacface-server --addr 127.0.0.1:8765 --static ../src-elm
# open http://127.0.0.1:8765/ in a browser
```

Manual smoke (curl):
```bash
# create session (returns sessionId string)
curl -s -X POST localhost:8765/rpc/create_session -d '{"binaryPath":"","configPath":"","toolConfirm":null}'
# list session dirs
curl -s -X POST localhost:8765/rpc/list_session_dirs -d '{}'
```

## Progress

| Phase | Status |
|-------|--------|
| P0 skeleton | [x] (module, tlv+tests, main, static server, hub) |
| P1 session core | [x] (core, dirs+tests, session+reader, rpc, sessions/io/cmd handlers, ws) |
| P2 remaining commands | [x] (list/delete/fork, model_set/sync, confirm, mcp_*) |
| P3 config domain | [x] (models+probe, presets+tests, settings+tests, mcp.conf+tests, oauth) |
| P4 frontend bridge | [x] (bridge.js transport abstraction; verified end-to-end in headless Chrome) |
| P5 wrap-up | [x] (Makefile targets, README section, .gitignore; ALL tests green) |

**Status: COMPLETE** (2026-08-05). Verification completed 2026-08-05 with
the fakecore integration suite + CI (see "Verification pass" below). The
only remaining item is the manual `make run` GUI smoke (no GUI in this
env). Next agent: run that, or extend the backend (e.g. REST facade, WS
session filtering, token auth hardening).

### Review pass 2026-08-05 (post-completion)

- [x] Fixed stdin atomicity: `session.WriteFrames` writes a whole message
      (media+text+UE) under ONE lock — matches Rust send_prompt; a
      concurrent CI command can no longer interleave between frames.
- [x] `NormalizeToolConfirm` now rejects all Unicode whitespace
      (unicode.IsSpace), matching Rust `is_whitespace()`.
- [x] `list_session_dirs` follows symlinks (os.Stat) like Rust
      `path.is_dir()`.
- [x] Added `--alayacore-bin` flag to main.go (sets ALAYACORE_BIN) —
      was documented but missing.
- [x] Re-verified: gofmt/vet/tests/build all green; regression smoke on
      :8767 (batch prompt UI→UT→UE ordering, unknown media rejection,
      list/close) passed.

### Review pass 2 (bug/hardening audit) — commit c9ee3ee

- [x] ws: close connection when hub drops a slow client (conn/goroutine
      leak) — write pump now closes conn to unblock the read pump
- [x] mcp oauth: only the FIRST callback request is processed (atomic
      CAS) — stray requests no longer duplicate mcp_confirm/decline
- [x] server: WS CheckOrigin now requires same-origin (WS bypasses CORS;
      any website could previously subscribe to the event stream)
- [x] tlv: MaxFrameSize 256 MiB cap (4-byte length allowed up to 4 GiB)
- [x] core: close pipes on spawn error paths
- [x] rpc: cache command registry (was rebuilt per request)
- [x] session: killOnce — child reaped exactly once when Close and
      reader EOF race
- [x] bridge.js: WS reconnect exponential backoff (1s→10s)
- [x] removed dead sessionDirFor helper
- [x] tests: oauth once/state/error paths, WS origin check, frame limit

### Review pass 3 (error-message parity) — pending commit

- [x] Aligned ALL user-visible error messages with the Rust backend
      (Rust uses capitalized messages: "Session not found",
      "Session is disconnected", "Failed to start alayacore: ...",
      "Preset not found: ...", "Cannot delete the last preset",
      "Invalid settings JSON: ...", "Path does not exist: ...", etc.).
      ~30 messages across session/io/sessions/presets/settings/mcp/
      models/fs/probe.
- [ ] Confirmed intentionally NOT changed (with evidence):
      - Sessions stay in Manager after disconnect (frontend
        Update.elm:194 calls closeSession with no error handling and
        depends on it succeeding; Rust keeps them too).
      - {"error": msg} RPC error shape (bridge.js contract).
      - "Session is disconnected" semantics on writes after EOF.

Smoke-tested 2026-08-05 (Go backend on 127.0.0.1:8766):
- `GET /` serves index.html; list_session_dirs / list_presets / create_session /
  list_models / close_session all return correct JSON (list_models queried real
  alayacore and returned the model list).
- WS `/ws` pushed tlv-frame/SM events with exact Rust payload shape
  (session_id/tag/raw_value/history_id/content/json/user_content_type) and
  core-status on disconnect; close_session kills the alayacore child
  (0 `--rawio` processes left).
- Caveat: prompt reply text not verified (MCP servers unreachable in this env —
  network-limited sandbox; unrelated to backend).

### Verification pass 2026-08-05 (fakecore integration suite — commit 7838e93)

Added a scriptable **fake alayacore** (`src-go/internal/fakecore`) and a full
integration suite, closing the P2 verification gap WITHOUT needing a reachable
model server (network-limited env). All previously-unverified commands are now
covered end-to-end against a real subprocess + WS:

- [x] `internal/fakecore`: TLV rawio stand-in; scripts user echoes, streaming
      deltas (Ar→At→AT/AR), SM task + model_list, and CI commands
      fork/model_set/model_load/model_sync/tool_confirm/tool_decline/cancel/
      mcp_decline/mcp_cancel (echoes the caller's call ID → CO name injection
      verifiable)
- [x] `internal/server/integration_test.go`: create → prompt → echo → deltas →
      AT/AR terminators (tlv-delta-only property) → close → core-status; ALL
      command roundtrips with injected CO names (model_set/model_sync/confirm/
      mcp_decline/mcp_cancel/cancel); fork (session file written + new session
      spawned + dir listed); list_models (probe fallback + live session +
      cache); list_default_models; sync_default_models success + error;
      resume + delete (incl. double-resume guard); token auth (401 RPC/WS +
      200 with token)
- [x] `internal/session/reader_test.go`: dispatch unit tests — delta-only,
      malformed delta fallback, empty→null, JSON frames, CO injection +
      pending deletion, SM wrap + model_list cache, invalid SM, user echoes,
      disconnect (killOnce nil-safe)
- [x] `internal/core/core_test.go`: spawn args/--session propagation + TLV
      roundtrip, spawn error, KillChild reap, FindBinary from env
- [x] `internal/hub/hub_test.go`: broadcast, unregister (no double close),
      slow-client drop, no-clients broadcast
- [x] All suites green under `-race -count=3` (no data races, no flakes)
- [x] Fixed parity bug found by the suite: `list_session_dirs.created_at` now
      uses birth time (Rust `metadata.created()`); sort stays on mtime
      (Rust `metadata.modified()`)

CI added (`.github/workflows/ci.yml`, 2026-08-05):
- [x] Go job: `go vet` + `go test -race` (uses setup-go with go.mod version)
- [x] Elm job: npm `elm@0.19.2-0` + `elm-test@0.19.2-0` (matches local
      toolchain), `elm make` + `elm-test`
- [x] Rust job: Tauri Linux system deps + `cargo test` with rust-cache

Tauri path regression (no GUI in this env — static + compile-level):
- [x] bridge.js tauriTransport invokes 30 commands; all present in Rust
      `generate_handler!` (incl. macro-generated `alayacore_cancel`)
- [x] bridge.js listens tlv-delta/tlv-frame/core-status; Rust emits exactly
      those three
- [x] `cargo test` passes (26 tests); `cargo build` compiles
- [ ] MANUAL (needs GUI): `make run` to smoke the tauriTransport path in a
      real window (bridge.js semantics unchanged — same invoke/listen calls)

---

## P0 — Skeleton (module, server, static, tlv)

- [x] `src-go/go.mod` (module `alayaface/src-go`, go 1.26)
- [x] `internal/tlv/tlv.go`: Encode / WriteFrame / ReadFrame / UnwrapDelta
      + tag constants (port `src-tauri/src/tlv.rs`)
- [x] `internal/tlv/tlv_test.go`: port ALL tlv.rs test cases (roundtrip,
      big-endian len, EOF, NUL edges, embedded NULs, json payloads)
- [x] `cmd/alayaface-server/main.go`: flags `--addr`, `--static`,
      `--alayacore-bin`, `--token`; http.Server; graceful shutdown (SIGINT/SIGTERM)
- [x] `internal/server/server.go`: static file serving from `--static`
      (MIME for .js, no-cache), `GET /` serves index.html
- [x] `internal/hub/hub.go`: Hub + Client (register/unregister/broadcast),
      no WS yet (P1 wires it)
- [x] Verify: `go build ./...`, `go test ./...` (tlv tests pass),
      `curl localhost:8765/` returns index.html

## P1 — Session core (create/resume/close/prompt/cancel + events)

- [x] `internal/core/core.go`: FindBinary (env→which→common paths→fallback),
      Spawn (--rawio, --config-path, --session, --tool-confirm),
      KillChild (close stdin, kill, wait ≤3s)
- [x] `internal/dirs/dirs.go`: AlayafaceDir, PresetsRoot, ActivePresetFile,
      ValidPresetName, Read/WriteActivePreset, ResolveConfigDir,
      ListPresetNames, Ensure (seed Default), CreateSessionDir (copy preset
      excluding settings.conf), ClonePresetDir, CreatePresetDefaults
      (port `dirs.rs`, incl. `DEFAULT_MODEL_CONF`)
- [x] `internal/dirs/dirs_test.go`: port dirs.rs tests (validation, seed,
      exclude settings.conf)
- [x] `internal/session/session.go`: Session (stdin+stdinMu, Connected
      atomic.Bool, PendingCmds sync.Map, Child, SessionDir),
      Manager (mu + map, Get/Insert/Remove), Create (spawn→insert→reader),
      Close (kill, remove), WriteFrame (lock, connected check, flush),
      SendCmd (uuid callID, register BEFORE write, return id)
- [x] `internal/session/reader.go`: reader goroutine (bufio.Reader +
      ReadFrame), dispatchFrame ported exactly:
      - At/Ar → tlv-delta ONLY
      - AT/AR → tlv-frame, empty→content null
      - Af/AF/UF/Uf → parse NUL prefix, attach json
      - CO → inject name from PendingCmds
      - SM → {type,data}; model_list → update model cache
      - echo tags → user_content_type
      - EOF/err → connected=false, KillChild, core-status, exit
- [x] `internal/session/model_cache.go`: ModelCache (mutex + []json.RawMessage)
- [x] `internal/server/rpc.go`: POST /rpc/{command} dispatcher + error
      format {"error": msg}; success = raw result JSON
- [x] `internal/server/handlers/sessions.go`: create_session, resume_session,
      close_session (P1; list/delete/fork in P2)
- [x] `internal/server/handlers/io.go`: alayacore_send_prompt (media tags
      UT/UI/UV/UA/UD + text + UE flush)
- [x] `internal/server/handlers/cmd.go`: alayacore_cancel
- [x] `internal/server/ws.go`: GET /ws upgrade; broadcast hub events
      {type, payload}; read loop for close detection
- [x] `internal/server/event.go`: DeltaEvent/FrameEvent/StatusEvent structs
      with EXACT serde field names + null semantics (no omitempty)
      (implemented as internal/session/events.go)
- [x] Verify: `go test ./...`; manual: start server, create session via curl,
      observe WS events (use a tiny ws client or browser), send prompt,
      see tlv-delta/tlv-frame flowing; close session kills alayacore
      (smoke-tested 2026-08-05: frames + status verified, alayacore killed)

## P2 — Remaining commands (list/delete/fork, cmd set, model_set/sync, confirm, mcp_*)

- [x] handlers/sessions.go: list_session_dirs (sort by modified desc,
      {id, has_session_file, created_at}), delete_session_dir (close+rm),
      fork_session (send "fork" cmd, wait_for_file, spawn new session)
- [x] `internal/server/handlers/wait.go` or in sessions: wait_for_file
      (5s, size-stable)
- [x] handlers/cmd.go: alayacore_model_set, alayacore_model_sync,
      alayacore_confirm (tool_confirm/tool_decline), alayacore_mcp_decline,
      alayacore_mcp_cancel
- [x] handlers/cmd.go: alayacore_model_set, alayacore_model_sync,
      alayacore_confirm (tool_confirm/tool_decline), alayacore_mcp_decline,
      alayacore_mcp_cancel
- [x] Verify fork/model_set/confirm roundtrips end-to-end via the fakecore
      integration suite (commit 7838e93) — no real model server needed:
      fork writes the session file + spawns the new session; model_set /
      model_sync / confirm / mcp_* / cancel all return CO frames with the
      injected command name over WS. Previously blocked on the
      network-limited env.

## P3 — Config domain (models, presets, settings, mcp, oauth)

- [x] `internal/probe/probe.go`: TempCore spawn + RunTempProbe (5s timeout,
      SM model_list + CO collection, cache refresh) — port models.rs
- [x] handlers/models.go: list_models (cache→live session→probe),
      list_default_models (probe, no cache), sync_default_models
      (probe + model_sync CI, CO is_error→err)
- [x] handlers/presets.go: list_presets, copy_preset, rename_preset,
      delete_preset, set_active_preset (+ valid name checks, active/last
      guards) — port presets.rs + tests
- [x] handlers/settings.go: get_global_settings, sync_global_settings,
      normalize_tool_confirm (+ tests)
- [x] handlers/mcp_conf.go: parse/write mcp.conf (--- blocks, kv mapping,
      args/env JSON, type inference) — port mcp.rs second half + tests
- [x] handlers/mcp.go: list_default_mcp, sync_default_mcp
- [x] `internal/mcp/oauth.go`: start_mcp_auth_flow, fill_mcp_auth_url
      (127.0.0.1:0 listener, state/redirect fill, open browser via
      xdg-open/open/rundll32, 5min timeout, callback → mcp_confirm/decline)
- [x] Verify: presets CRUD, settings roundtrip, mcp list/sync covered by
      unit tests (presets_test.go, settings_test.go, mcp_conf_test.go).
      OAuth flow not yet exercised end-to-end (needs a real OAuth provider).

## P4 — Frontend bridge (shared Elm client over HTTP/WS)

- [x] Rewrite `src-elm/bridge.js`: transport abstraction —
      `window.__TAURI__` → tauriTransport (current code); else httpTransport
      (fetch POST /rpc/{cmd} + single WS /ws + reconnect backoff)
- [x] httpTransport.invoke: non-2xx → reject {message: body.error}
- [x] httpTransport.onEvent: dispatch {type, payload}, reconnect
- [x] Window maximize: browser mode = innerHeight >= screen.availHeight +
      resize listener
- [x] Verify: FULL end-to-end in headless Chrome (CDP) against the Go
      backend: session created, model list loaded from alayacore, MCP
      status events rendered, and a complete conversation streamed
      (USER → REASONING → ASSISTANT "hello world") via WS deltas.
      Tauri path: bridge.js unchanged semantics (tauriTransport wraps the
      exact same invoke/listen calls) — re-verify with `cargo run` when a
      GUI session is available.

## P5 — Wrap-up

- [x] `Makefile`: `run-go`, `build-go`, `test-go` targets
- [x] README.md: Go backend section (requirements, quick start, flags)
- [x] Integration test (optional): full end-to-end verified via headless
      Chrome (CDP) — create session, model list, MCP init/oauth RPCs,
      streamed conversation (USER → REASONING → ASSISTANT)
- [x] Final: `go vet ./...`, `go test ./...` (all pass), `make build-go`
      works, `src-go/bin/` git-ignored
- [x] Tauri path regression (no GUI env): bridge.js command/event surface
      verified 1:1 against Rust generate_handler + emit calls; `cargo test`
      (26) + `cargo build` pass. See "Verification pass" above.
- [ ] Remaining MANUAL check (needs a GUI session): `make run` (Tauri) to
      confirm the tauriTransport path works in a real window. bridge.js
      semantics unchanged — same invoke/listen calls, just wrapped; the
      httpTransport path (same Elm client, same call sites) is covered by
      the fakecore integration suite + prior headless-Chrome E2E.

---

## Known pitfalls (from design doc §11)

- JSON field names: match Rust serde exactly (snake_case in returns,
  camelCase in args); null keys must exist (no omitempty).
- stdin writes need per-session mutex.
- KillChild on every exit path (close, reader EOF, server shutdown).
- Register PendingCmds BEFORE writing CI frame.
- list_default_models must use temp probe, not session cache.
- create_session must return only after session registered + reader started.
- Do not run Tauri and Go backends on the same session dir simultaneously.
