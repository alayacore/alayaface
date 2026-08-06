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
| P2 Create Plan flow + plans dir + Plans manager | [x] |
| P3 DAG layout + SVG view + node→session click | [x] |
| P4 Runner state machine + retry + run.json + resume | [x] |
| P4.5 create_session preset/builtinTools + settings.conf + seed presets | [x] |
| P5 Polish (badges/logs/concurrency/export/docs/README) | [x] |
| P6 Plan Session (menu entry, --system planner prompt, [Plan] title) | [x] |
| P7 Plan windows (multi-instance, ⚙ menu list) + SendPrompt fix | [x] |

## P7 — Plan windows + runner prompt dispatch fix（评审反馈）

- [x] **Plan 界面改为独立窗口**（不再是 overlay）：`planWindows : Dict
      String PlanWindow` + `planOrder` + `planActiveId`，每个窗口自带
      `view`/`run`/`runPath`/`runLog`/`selectedNode`/`creating`/`createQueue`/
      `resumePath`；窗口可拖动/缩放/关闭（复用 `windowPositions` + drag/
      resize 机制，新增 `PlanWindowDragStart`/`PlanResizeStart`/`PlanActivate`/
      `PlanClose`）；多 plan 可同时打开、独立运行；
- [x] **系统菜单（⚙）列出所有打开的 plan**（名称 + 运行状态），点击置顶激活
      （`viewGlobalMenuPlan`）；Plans 管理器保留为 launcher（open/delete/import）；
- [x] **Run 后节点会话为空的问题已修复**：`Plan/Runner.elm` 从未生成
      `SendPrompt` effect（只定义了类型/处理端），导致会话创建并绑定为
      `Running` 后 prompt 从未发送。现在 `bindSession`（Starting→Running）
      恰好发出一次 `SendPrompt`；测试覆盖（绑定发 prompt、重复绑定不发、
      全生命周期 create→bind→prompt→done）；
- [x] **第二轮修复（仍空窗口）**：修复后 SendPrompt 虽已生成，但
      `runStepIn` 用 step **前**的旧 run 状态应用 effects → `nodePromptIn`
      按 sessionId 查 prompt 返回空串被丢弃。修复：① effects 改为在
      step **后**状态上应用（runStepIn 先更新窗口 run 再 dispatch）；
      ② `SendPrompt` 改为携带 prompt 文本（runner 绑定会话时从 plan
      解析），Update 层不再依赖查表，杜绝此类丢失；新增测试
      “SendPrompt carries the exact plan prompt”；Elm 测试 118；
- [x] 手动关闭节点会话窗口 → 注入 `SessionDisconnected`（防 runner 悬挂）；
- [x] `planCreating`/`planCreateQueue` 升级为 `(planId, nodeId)` 全局串行，
      `SessionCreated` → `PlanBindSession ts planId nodeId sid` 无歧义绑定；
      runner 事件（TaskDone/Error/Disconnect）按 sessionId 路由到所属窗口
      （`findPlanIdBySession`）；
- [x] FsReadResult 改为 `planReadTarget`（planId/path/isResume）路由：
      打开/导入 → 新建或聚焦窗口；Load run → 恢复该窗口 run 并 ContinueRun；
- [x] 文档同步（docs/plan-mode.md §7.1/偏差说明、README）；
- [x] 测试：Elm 117（新增 prompt dispatch 3 例）。

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

- [x] App shell integration: `showPlanView`, `planView`, `planManager`,
      `pendingPlanOffers`, `homeDir` in App/Types Model; Msg wiring in
      Main/Update
- [x] "Create Plan" button under assistant message when `pendingPlanOffers`
      has an entry for it (View)
- [x] Create Plan flow: detect ```json in AT frame → offer → decode→validate→
      normalize→planId (name slug + timestamp)→ `fs_write_file_text` to
      `~/.alayaface/plans/<planId>.json` (createParents)→ open Plan window;
      validation errors shown in Plan view
- [x] Plans manager overlay: list `~/.alayaface/plans/*.json` (via fs_home_dir +
      fs_list_dir, filters out *.run.json), Open / Delete / Import via path input
      (added fs_delete_file command Rust+Go+ports+tests)
- [x] Global menu: "Plans" entry (🕸)
- [x] Plan view (P2 list form; P3 upgrades to SVG DAG): name/goal/meta/path +
      task list with id/title/preset/deps
- [ ] MANUAL smoke (Go backend browser / Tauri) — needs GUI env
- [x] Note: fs_list_dir results are shared with the file picker; the
      FsListDirResult branch routes to plan list when planManager.show
- [x] Note: Elm record-update requires a variable on the left — cannot
      `{ model.planManager | ... }`; bind `pm = model.planManager` first

## P3 — DAG layout + SVG view + node→session click

- [x] `Plan/Layout.elm`: Kahn longest-path layering → columns; per-node (x,y);
      orthogonal edge routing (same-row: right→left horizontal; diff-row:
      bottom→top). Tests: diamond/chain/parallel layers + geometry
      (plan-layout tests, 8 cases)
- [x] `Plan/View.elm`: HTML/CSS DAG canvas (NO elm/svg — not in offline
      package cache; pure-div rendering), node cards (title, status color,
      retry badge, preset badge, hover failure reason), edges, node click
- [x] Node click → `PlanSelectNode` → detail panel (prompt, deps, preset,
      maxAttempts, Retry placeholder disabled); session-open wiring lands
      in P4 (needs node→session association)
- [x] Plan window header: name/goal/meta + Run/Pause/Stop (disabled
      placeholders, enabled in P4) + Export JSON (path input +
      fs_write_file_text; setPlanErrors now preserves the open plan)
- [x] CSS (style.css): plan-dag/plan-node/edge/detail styles
- [x] Elm 95 tests green
- [ ] Manual visual acceptance (needs GUI env)
- [x] Note: `Expect.lessThan a b` asserts b < a in test 2.2.0 (argument
      order is expected-first, actual-second) — use `Expect.equal True (a < b)`

## P4 — Runner state machine + retry + run.json + resume

- [x] `Plan/Runner.elm`: Event/step state machine (Started via
      `step now ev run -> (run, effects)`); NodeStatus gains `Waiting`
      (backoff before auto-retry). Effects: CreateSessionFor/SendPrompt/
      CloseSessionFor/ScheduleRetry(2000ms)/PersistRunState/Notify
- [x] Scheduler: runnable = Pending && all deps Succeeded; cap
      `concurrency - running`; marks launched nodes Starting
- [x] Event handling: SessionCreatedFor→bind+SendPrompt; TaskDone (only
      for Running nodes — idle SM task frames while Starting are ignored);
      SessionError; SessionDisconnected (Running/Starting); Stop/Pause/
      Resume/ContinueRun; RetryNode (auto tick + manual, reactivates a
      finished run)
- [x] Retry: FailureRecord{attempt, reason, at} appended; attempts<max →
      Waiting + ScheduleRetry(2000) + CloseSession; attempts>=max → Failed
      + downstream Blocked (fixpoint propagation) + run FailedRun;
      run Completed when all terminal & none failed
- [x] App/Update wiring: `runStep now ev model` + applyEffects ↔ ports;
      serialized session creation (planCreating/planCreateQueue,
      PlanBindSession binds SessionCreated to its node); frame/status
      events for node-owned sessions feed the machine (PlanRunFrame with
      Time.now via Task); SendPrompt uses the node prompt
- [x] run.json persistence: PersistRunState → fs_write_file_text
      <plan>.run.json (encodeRunState/decodeRunStateOverlay/
      applyRunStateOverlay codecs in Plan/Types); written on every step
      (throttling deferred)
- [x] Resume: PlanResume reads run.json → applyRunStateOverlay →
      R.resumeState (Starting/Running/Waiting → Pending, drop stale
      sessions) → ContinueRun relaunches unfinished nodes from scratch
- [x] Tests: `tests/PlanRunnerTest.elm` (17 cases: concurrency cap, dep
      gating, retry count + FailureRecord, stop/pause/resume/manual retry,
      disconnect/task_error, late-event ignore) + run-state codec
      roundtrip in PlanTypesTest → elm-test 114 green
- [x] UI: Run/Pause/Resume/Stop/Load-run buttons (enabled by run status),
      run status badge, node click opens its session window (ActivateSession)
      when it has one else detail panel; Retry node button; failure
      history in detail panel
- [ ] fakecore/E2E: task_error → retry → success, parallel windows, node
      click opens window — needs GUI/browser env (manual)
- [x] `elm-test` green

## P4.5 — create_session preset/builtinTools + settings.conf + seed presets

- [x] Rust `alayacore.rs` spawn() + Go `core.go` Spawn(): `builtin_tools`
      arg → `--builtin-tools=<list>` when non-empty (alongside
      --tool-confirm; empty = don't pass flag = alayacore all-on)
- [x] Rust `commands/settings.rs` + Go `handlers/settings.go`:
      GlobalSettings + `builtin_tools` field; get/sync read-write (per
      preset); normalize via existing tool-list normalizer; tests both
      sides + parity (Safe seed carries the no-execute_command list)
- [x] Rust `commands/sessions.rs` create_session: optional `preset`
      (dirs::create_session_dir_from copies that preset into
      session_dir/config, excluding settings.conf) + optional
      `builtinTools` (explicit override; default = active preset
      settings.conf; passed to spawn). Go `handlers/sessions.go` same.
      NOTE: never pass preset dir as configPath (breaks resume)
- [x] `bridge.js` + `Ports.elm`: createSession carries toolConfirm/preset/
      builtinTools; syncGlobalSettings carries builtin_tools
- [x] `Overlay/Settings.elm`: "Built-in tools" input (per-preset, like
      tool confirm) + SetBuiltinTools msg + SettingsEditor.builtinTools
- [x] Seed presets: `dirs.rs`/`dirs.go` Ensure() seeds Default/Fast/Deep/
      Data/Safe (idempotent); Safe's settings.conf sets builtin_tools
      without execute_command; create_session_dir_from for a named preset
- [x] DAG node cards: tools badge (when node overrides); preset badge
      already present; runner createSession passes node preset/tools
- [x] Tests: Rust (35: spawn chain, settings builtin_tools roundtrip,
      seed presets, create_session_dir_from) + Go (parity + integration:
      create_session with Safe preset → config copied w/o settings.conf,
      unknown preset error parity, explicit builtinTools)
- [x] `cargo test` (35) + `go test -race` (8 pkgs) + `elm-test` (114) green

## P5 — Polish

- [x] Retry badge/tooltips (node attempts badge xN, hover failure reason,
      detail-panel failure history) — already landed in P3/P4
- [x] Export JSON button (path input + fs_write_file_text) — landed in P3
- [x] Run log stream in the Plan view (node status transitions, bounded 80)
- [x] README section (Plan Mode usage + presets/tool sets + never-modify
      AlayaCore note)
- [x] docs/go-backend.md command table update (fs_write/read/delete,
      create_session preset/builtinTools, get_global_settings builtin_tools)
- [x] docs/plan-mode.md status + implementation-deviation notes synced
- [ ] Concurrency selector in the Plan header (edit before run) — deferred
      to v2; concurrency comes from the plan JSON
- [ ] Manual GUI acceptance (Tauri + Go browser) — needs GUI env; E2E via
      fakecore covers backend, runner covered by 114 elm tests

## P6 — Plan Session (menu entry + --system planner prompt + [Plan] title)

User-facing flow: ⚙ menu → **New Plan Session** → describe the goal in
plain language → model emits the plan JSON → existing Create Plan flow.
No implementation details exposed to the user.

- [x] spawn()/Spawn() gain `system_prompt` → `--system=<text>` when
      non-empty (appended to alayacore's default system prompt; AlayaCore
      untouched) — Rust alayacore.rs + Go core.go
- [x] create_session gains optional `systemPrompt` (Rust+Go) + SessionConfig/
      CreateConfig fields; resume/fork pass empty
- [x] Ports.createSession carries systemPrompt; bridge.js passes it
- [x] App: `CreatePlanSession` Msg → createSession with the built-in
      `planSystemPrompt` (planner instructions: emit ONE ```json block,
      schema + quality rules, then answer normally); `planSessionPending`
      marks the next SessionCreated; `planSessionIds : Set String`
- [x] View: ⚙ menu "New Plan Session" (⧉) next to New Session; session
      window title gets a "[Plan] " prefix for plan sessions
- [x] Tests: Go integration (create_session with systemPrompt works,
      fakecore answers prompts); Rust 35 / Go 8 pkgs / Elm 114 all green
- [ ] Manual GUI smoke (needs GUI env)

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
