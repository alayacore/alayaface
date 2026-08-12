# Guidelines for AI Agents

## Before Proposing Changes

1. **Check browser console for errors.** If `init()` crashes partway, some features work while others silently fail—the app looks operational but tracking is dead. Always verify infrastructure is running before debugging logic.

2. **Confirm the baseline.** Is the relevant event listener attached? Is the function being called? Don't assume—verify with console output or user observation.

3. **Find the minimal change.** Start from the working original. Change one thing at a time. If a single variable substitution fixes it, don't rewrite the surrounding logic.

## Code Principles

4. **One source of truth.** Don't duplicate a mechanism that already exists (e.g., JS-side scroll guard when Elm already has `atBottom`). Two parallel systems drift apart and confuse future readers.

5. **Reuse checked variables.** If a DOM lookup is validated non-null at the top of a function, reuse that variable later instead of querying the DOM again. A second lookup can fail unexpectedly (element removed, race condition).

## Language

- **All documents (docs/, README, design notes, archive) are written in English.**
- **No Chinese in code** — comments, identifiers, log strings, and UI text must
  be English. The only allowed exception is **test fixtures that verify Chinese
  text renders/round-trips correctly** (Chinese display effect tests).
- User-facing UI copy is English; keep translations in sync across the codebase.

## Architecture (current)

Three parts share ONE Elm client:

- `src-tauri/` — Rust/Tauri backend. Commands in `commands/*.rs`; TLV frame
  dispatch in `reader.rs`; session lifecycle in `session.rs`. Tests: `cargo test`.
- `src-go/` — Go backend (browser/HTTP+WS), a symmetric port of the Rust one.
  Commands in `internal/server/handlers/`; reader/dispatch in
  `internal/session/`. Tests: `go test -race ./...` (integration tests build
  `fakecore` automatically).
- `src-elm/` — Elm frontend (no bundler). `App/Update.elm` is the message
  dispatcher; Plan Mode logic lives in `Plan/Update.elm` (pure, injects the
  dispatcher as `Dispatch`); window/canvas/zoom/z-index in `App/Windows.elm`
  (pure); the plan state machine in `Plan/Runner.elm` (pure). The JS bridge
  is split: `transport.js` (RPC ports ↔ tauri/http), `chain.js`
  (connection-chain SVG overlays), `overlay.js` (scrollbar/canvas zoom).
  Tests: `elm-test`.

**The two backends must stay symmetric.** Any behavior/protocol change goes
into Go AND Rust together — command-name parity alone does not prevent
behavioral drift (B2: Rust held a lock across a 5s graceful close, Go did
not). `scripts/check-backend-parity.sh` asserts the command names match
(Rust `commands::<name>` == Go `"<name>": Handler` == `transport.js`
`invoke("<name>")`, bridge ⊆ backends).

**NEVER modify AlayaCore.** Capability differences are expressed only through
spawn arguments (`--tool-confirm`, `--builtin-tools`, `--system`, work dir)
and the config files (`model.conf`, `mcp.conf`, `settings.conf`, `global.conf`).

## Verification (run before every commit)

```bash
cd src-go && go vet ./... && go test -race ./...
cd src-elm && elm make src/Main.elm --output=/tmp/m.js && elm-test
cd src-tauri && cargo test
./scripts/check-backend-parity.sh
cd e2e && node plan-e2e.mjs && node restart-e2e.mjs   # headless Chrome + fakecore
```

## M-series refactor workflow (gitignored)

The maintainability refactor is tracked in **root `TODO.md` / `REFACTOR.md`** —
both are **gitignored local working files** (the project's history lives in
`docs/archive/`). Interrupt recovery: read `REFACTOR.md` (design + confirmed
decisions D1–D8) → `TODO.md` → continue from the first unchecked item.

Every phase: implement → full verification above → `git commit` → push to
**all three remotes** (`origin`, `gitee`, `org`, branch `main`) and verify
with `git ls-remote`. M-series is behavior-preserving (except M3's
performance-equivalent semantics); tests + E2E are the backstop.

## Routing: tagged fs ports (B3/B4)

`fsListDir` and `fsReadFileText` are shared by TWO flows: the plan-meta scan
(sessions/ → plans/ dirs → *.meta.json rebuild) and the normal UI flows
(session manager, file picker, plan open/load). Responses are routed by
**reqId** (`fs-N`, allocated by `nextFsReq` in `Plan/Update.elm`): a response
whose reqId matches `planMetaScanReqId`/`planMetaReadReqId`/`planReadTarget`
belongs to that flow; anything else belongs to the UI. Never route by global
flags alone — a user listing racing the scan would be swallowed (stuck file
picker) or parsed as plan dirs (corrupted scan). `fsHomeDirResult`,
`fsReadFileUriResult`, `sessionDirsResult` are untagged but fire once per
request (no shared-flow ambiguity).

## History

`docs/archive/` holds the archived P/R-series design notes (`TODO.md`,
`REFACTOR.md`, `go-backend-todo.md` were archived there — they are tracked
history, not live working files).
