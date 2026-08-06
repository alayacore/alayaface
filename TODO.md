# TODO: Plan Mode（AlayaFace）

Tracking file for the **Plan Mode** feature (任务规划 → DAG → 执行/重试)。
If interrupted, the next agent should read `docs/plan-mode.md` first, then
continue from the first unchecked item in this file.

> This file IS git-tracked (unlike before). Design doc: `docs/plan-mode.md`
> (authoritative). Old Go-backend notes archived at `docs/go-backend-todo.md`.

## How to continue after an interruption (read first)

1. Read `docs/plan-mode.md` — full design (architecture, schema, runner state
   machine, backend changes, constraints C1–C5).
2. Read this file — progress table + phase checklists. Start from the first
   `[ ]` item in the earliest non-complete phase.
3. Constraints reminder: **NEVER modify AlayaCore** (it's a separate repo);
   dual backend parity (Rust + Go, same JSON contract); Elm logic stays pure
   (`Plan/*` modules, elm-test); all new params optional/backward-compatible.
4. Update this file (checkboxes + progress table) as you go. Commit when a
   phase is done.

## Environment / verification

```bash
# Elm (src-elm/)
cd src-elm && elm-test                       # unit tests
elm make src/Main.elm --output=elm.js        # compile

# Rust (src-tauri/)
cd src-tauri && cargo test                   # unit tests
cargo build

# Go (src-go/)
cd src-go && go vet ./... && go test -race ./...
go run ./cmd/alayaface-server --addr 127.0.0.1:8765 --static ../src-elm
```

Manual E2E: `make run` (Tauri) or browser via Go backend + `make run-go`.
Integration tests use `src-go/internal/fakecore` (scriptable alayacore stand-in).

## Progress

| Phase | Status |
|-------|--------|
| P0 Plan data model + detection (pure Elm) | [x] |
| P1 fs_write_file_text / fs_read_file_text (Rust+Go+bridge+Ports) | [x] |
| P2 Create Plan flow + plans dir + Plans manager | [ ] |
| P3 DAG layout + SVG view + node→session click | [ ] |
| P4 Runner state machine + retry + run.json + resume | [ ] |
| P4.5 create_session preset/builtinTools + settings.conf + seed presets | [ ] |
| P5 Polish (badges/logs/concurrency/export/docs/README) | [ ] |

## Design decisions (defaults, see docs/plan-mode.md §13)

- Concurrency default 2 (1–8); default_max_attempts 3; retry backoff 2s.
- Failure = SM task_error | SM error | session disconnect. Timeout: OFF (v2).
- v1 prompts are self-contained (no upstream output injection).
- Runner sessions: toolConfirm="allow"; node-level `preset`/`tools` optional.
- Persistence: `~/.alayaface/plans/<planId>.json` + `<planId>.run.json`.
- Resume v1 = re-run unfinished/failed/blocked nodes from scratch (new sessions).
- Seed presets: Default / Fast / Deep / Data / Safe (Safe disables execute_command).
- `--builtin-tools` semantics: empty config = don't pass flag = alayacore all-on;
  non-empty comma list = subset. MCP-only ("none") deferred to v2.

---

## P0 — Plan data model + detection (pure Elm)

- [x] `src/Plan/Types.elm`: Plan / TaskNode / NodeStatus / RunState / FailureRecord
      types + JSON decoders/encoders (snake_case, matching schema in design §5)
- [x] `Plan/Types.elm`: normalize (fill defaults: concurrency=2,
      default_max_attempts=3, depends_on=[], max_attempts←default,
      schema_version=1) + validate (id unique/non-empty, title/prompt non-empty,
      deps exist, no self-dep, Kahn cycle detection) → readable error list
- [x] `Plan/Detect.elm`: `extractPlanJson : String -> Maybe String` (first
      ```json … ``` fence, unescape)
- [x] tests: `tests/PlanTypesTest.elm` (decode ok/err, cycle, unknown dep, dup id,
      normalize, roundtrip) + `tests/PlanDetectTest.elm` (fence edges: no fence,
      empty, multiple, ```json vs ```text, CRLF)
- [x] `elm-test` green (87 tests; note: elm-explorations/test 2.2.0 has no
      Expect.true/false — use Expect.equal True; RunStatus ctors renamed
      InProgress/FailedRun to avoid NodeStatus ctor clash)

## P1 — fs_write_file_text / fs_read_file_text (dual backend)

- [x] Rust `src-tauri/src/commands/fs.rs`: `fs_write_file_text(path, content,
      createParents)` + `fs_read_file_text(path)`; errors
      `Cannot write file: ...` / `Cannot read file: ...`; register in
      `lib.rs generate_handler!`
- [x] Go `src-go/internal/server/handlers/fs.go`: same commands + register in
      RPC dispatcher; error-message parity with Rust
- [x] `src-elm/src/Ports.elm`: `fsWriteFileText` / `fsReadFileText` ports +
      `onFsWriteResult` / `onFsReadResult` subs
- [x] `src-elm/bridge.js`: wire both ports (invoke + result ports)
- [x] `src-elm/src/Main.elm`: subscriptions for result ports; new Msg(s) in
      App/Types + App/Update handlers (FsWriteResult/FsReadResult — NoOp
      until P2 wires them into plan save/load)
- [x] Tests: Rust fs roundtrip + createParents + errors; Go same + parity
      (server/fs_test.go via testEnv, full HTTP path)
- [x] `cargo test` (30) + `go test -race` + `elm-test` (87) green

## P2 — Create Plan flow + plans dir + Plans manager

- [ ] App shell integration: `showPlanView`, `plans`, `planManager`,
      `pendingPlanOffers` in App/Types Model; Msg wiring in Main/Update
- [ ] "Create Plan" button under assistant message when `pendingPlanOffers`
      has an entry for it (View)
- [ ] Create Plan flow: decode→validate→normalize→planId (name slug + ts)→
      `fs_write_file_text` to `~/.alayaface/plans/<planId>.json` (createParents)→
      open Plan window; validation errors shown in view
- [ ] Plans manager overlay: list `~/.alayaface/plans/*.json` (via fs_home_dir +
      fs_list_dir), Open / Delete / Import from file (reuse FilePicker)
- [ ] Global menu: add "Plans" entry
- [ ] Manual smoke (Go backend browser)

## P3 — DAG layout + SVG view + node→session click

- [ ] `Plan/Layout.elm`: Kahn longest-path layering → columns; per-node (x,y);
      edge paths (cubic Bézier); tests: diamond/chain/parallel graphs
- [ ] `Plan/View.elm`: SVG canvas (viewBox, scroll/zoom v1 simple), node cards
      (title, status color, retry badge, preset badge, hover failure reason),
      edges, node click handling
- [ ] Node click: sessionId exists → `ActivateSession` (bring window to front);
      else → node detail panel (prompt, deps, failures, Retry/Run buttons)
- [ ] Plan window header: name/goal/status badge + Run/Pause/Stop/Retry +
      concurrency select + Export JSON (FilePicker + fs_write_file_text)
- [ ] CSS (style.css): DAG styles, plan window
- [ ] Manual visual acceptance

## P4 — Runner state machine + retry + run.json + resume

- [ ] `Plan/Runner.elm`: types (NodeStatus incl. Starting/Blocked/Canceled,
      Effect, Event) + `step : Event -> RunState -> (RunState, List Effect)`
- [ ] Scheduler: runnable = Pending && all deps Succeeded; cap
      `concurrency - Running`
- [ ] Event handling: SessionCreatedFor→SendPrompt; TaskDone (task_error vs ok);
      SessionError; SessionDisconnected; Stop/Pause/Resume; RetryNode
- [ ] Retry: FailureRecord{attempt, reason, at} append; attempts<max→Close+
      ScheduleRetry(2000)→Pending; else Failed→downstream Blocked
- [ ] App/Update wiring: runner effects ↔ ports (createSession with
      toolConfirm="allow", sendPrompt, closeSession); FrameEvent/StatusEvent
      for node-owned sessions feed step()
- [ ] run.json persistence: write on transitions (terminal always, interim
      throttled); read on open for Resume
- [ ] Resume: from run.json, re-run unfinished/failed/blocked from scratch
- [ ] Tests: `tests/PlanRunnerTest.elm` (concurrency cap, dep gating, retry
      count + FailureRecord, stop/pause/manual retry, disconnect/task_error)
- [ ] fakecore integration: task_error → retry → success; E2E create→run→
      parallel windows→node click opens window
- [ ] `elm-test` + `go test -race` + manual E2E green

## P4.5 — create_session preset/builtinTools + settings.conf + seed presets

- [ ] Rust `alayacore.rs` spawn(): `builtin_tools: &str` arg → `--builtin-tools`
      when non-empty (alongside --tool-confirm)
- [ ] Go `core.go` Spawn(): same
- [ ] Rust `commands/settings.rs` + Go `handlers/settings.go`: GlobalSettings
      + `builtin_tools` field; get/sync read-write; normalize via existing
      normalize_tool_confirm; tests both sides + parity
- [ ] Rust `commands/sessions.rs` create_session: optional `preset` (copy that
      preset into session_dir/config, exclude settings.conf) + optional
      `builtinTools` (default = active preset settings.conf; passed to spawn)
- [ ] Go `handlers/sessions.go`: same
- [ ] `bridge.js` + `Ports.elm`: createSession carries toolConfirm/preset/
      builtinTools
- [ ] `Overlay/Settings.elm`: "Built-in tools" input (per-preset, like tool
      confirm); View + Update wiring
- [ ] Seed presets: `dirs.rs`/`dirs.go` create_preset_defaults extended to seed
      Fast/Deep/Data/Safe (model/mcp placeholders; Safe settings.conf sets
      builtin_tools without execute_command)
- [ ] DAG node cards: preset badge + tools badge
- [ ] Tests: Rust+Go unit (spawn args, settings roundtrip, create_session
      preset copy/builtinTools, seed presets), parity
- [ ] `cargo test` + `go test -race` green

## P5 — Polish

- [ ] Retry badge/tooltips, run log stream, concurrency selector polish
- [ ] Export JSON button flow (FilePicker)
- [ ] README section (Plan Mode usage + seed presets)
- [ ] docs/go-backend.md command table update (fs_write/read, create_session
      new args)
- [ ] Full manual acceptance (Tauri + Go browser)

---

## Known pitfalls

- Never edit `../alayacore` — tool set = spawn params only.
- JSON contract: snake_case returns, camelCase args, null keys must exist,
  error messages capitalized & identical across Rust/Go.
- `--builtin-tools` empty ≠ all: empty config means DON'T pass the flag
  (alayacore all-on); explicit empty string means no builtin tools (v2).
- Don't pass preset dir as `configPath` in create_session — breaks
  resume_session (needs session_dir/config); use the `preset` param instead.
- settings.conf is per-preset and NOT copied into session dirs.
- Runner sessions: keep toolConfirm="allow" so tasks don't stall on confirm
  dialogs.
- Plan JSON saved to disk must be the NORMALIZED version (schema_version=1,
  defaults filled).
- `pendingPlanOffers` is per message id; clear after Create Plan consumed.
- bufferPendingEvent pattern: runner-created sessions race with events —
  reuse existing buffering for node-owned sessions.
