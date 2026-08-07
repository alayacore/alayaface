# Plan Mode Design Document (AlayaFace)

> Status: **Implemented (P0–P11 done; includes several review-round fixes)**.
> Development progress lives in the root `TODO.md` (read it first).
> This document is the single authoritative design source for Plan Mode;
> after an interruption, read this + `TODO.md` before continuing.
> Deviations from the design are annotated (e.g. NodeStatus gained `Waiting`,
> session creation is serialized).

---

## 1. Overview

Add **Plan Mode** to AlayaFace: let the model decompose a large task into a
**DAG (directed acyclic graph)** produced as JSON; AlayaFace is responsible for:

1. **Producing correct JSON**: capture the plan from the model output → decode → validate (dependencies exist, acyclic, unique ids) → normalize → **writable to a file**;
2. **Visualization**: show the DAG to the user as SVG; **each task node is clickable and opens the corresponding session window for details**;
3. **Execution**: a DAG Runner (**pure Elm state machine**) parses the JSON, detects parallel tasks, and creates/drives the corresponding sessions;
4. **Failure retry**: records the failure reason and **which attempt failed**, auto-retries up to the limit, and supports manual retry.

---

## 2. Project Constraints (red lines, must be honored)

| # | Constraint | Description |
|---|------|------|
| C1 | **Never modify AlayaCore** | AlayaCore is a separate repo (`~/playground/alayacore`). Even if changes are needed, they are not made in this project. All capability differences are achieved through **spawn arguments** (`--tool-confirm` / `--builtin-tools` / `--config-path` / `--model`, etc.) and **preset configs** (model.conf / mcp.conf / settings.conf) |
| C2 | **Dual-backend parity** | New commands must be implemented in both Rust (Tauri) and Go (HTTP/WS) with strictly identical JSON contracts (snake_case returns, camelCase args, no omitted null keys, error messages capitalized and identical). See `docs/go-backend.md` and `src-elm/src/Session/Protocol.elm` |
| C3 | **Elm pure logic** | Scheduling/validation/layout/state machine are all pure-function modules (`Plan/*`), fully covered by elm-test; side effects only go through `Ports.elm` ↔ `bridge.js` |
| C4 | **Backward compatibility** | All new arguments are optional (default = existing behavior); new settings.conf fields default to fully enabled |
| C5 | No wheel reinvention | Session creation / prompt sending / event streaming all reuse the existing `createSession` / `sendPrompt` / `onFrame` / `onStatus` ports |

---

## 3. Current State & Design Basis (verified facts)

- **Session model**: each session = one `alayacore --rawio` child process; TLV frame streaming; session windows can be dragged/resized/activated by click.
- **Task status**: SM message `{"type":"task","data":{in_progress, current_step, max_steps, task_error, context_tokens}}` already drives `taskRunning` / step counts (`Session/Handlers.elm handleSystemTask`).
- **Failure signals**: SM `task_error=true`, SM `type=error`, `core-status` disconnect (`connected=false`).
- **Tool sources**:
  - Built-in tools (`read_file`/`edit_file`/`write_file`/`execute_command`/`search_content`) are controlled by the alayacore `--builtin-tools` flag (**unspecified = all enabled**, comma list = subset, explicit empty string = no built-in tools);
  - **AlayaFace currently doesn't pass this flag on spawn** → all sessions default to all tools enabled (need a new argument, see §9);
  - External tools come from MCP (preset's mcp.conf).
- **Preset structure** (`~/.alayaface/presets/<name>/`) — **empty-shell seeds**:
  `model.conf`, `runtime.conf`, `themes/` are **not pre-created**; alayacore
  generates them on first use (verified: an empty config dir starts with zero
  errors and alayacore builds a usable local Ollama default model +
  runtime.conf); "copy an existing preset" (clone / create-session config copy)
  is the meaningful path that produces files;
  - `model.conf` — model list (capability source); missing = alayacore auto-creates defaults;
  - `mcp.conf` — MCP servers (external tool source); only copied if present;
  - `runtime.conf` — only active_model/active_theme (managed by alayacore; don't treat it as config).
    **Note: alayacore parses it as `key: value` lines, not JSON**;
  - `settings.conf` — **AlayaFace-owned, stored per preset**, `{"tool_confirm": "id1,id2"}`; not copied into session dirs; `get_global_settings(preset)` / `sync_global_settings(config, preset)` already support per-preset read/write; only the Safe seed carries it;
  - `themes/` — alayacore auto-creates default themes when missing.
  - **Legacy seed self-heal**: `dirs::ensure` removes files that still hold old
    empty seeds at startup (runtime.conf `{}` / comment, Placeholder model.conf)
    — both presets and old session config copies are scanned; alayacore
    recreates them, so removal is lossless; real files whose content differs
    (user-configured models, alayacore-written active_model) are never touched;
- **create_session command**: already supports `configPath` (non-empty = use the given dir directly as session config); `toolConfirm` defaults to the active preset's settings.conf tool_confirm; **creating a session dir copies the active preset into `session_dir/config`** (`dirs::create_session_dir`, excluding settings.conf).
- **resume_session depends on `session_dir/config`** → passing a preset path directly as configPath would break resume; the "copy template by preset name" path must be used.
- **The alayacore tool set cannot be extended on the UI side** → plan JSON can only be captured via a "fenced ```json output" or "write_file to a file".
- `TODO.md` / `REFACTOR.md` were originally gitignored → the `TODO.md` ignore was removed and it is now version-controlled (interruption recovery depends on it).

---

## 4. Overall Architecture & Data Flow

```
[Planner Session] model generates DAG JSON       ← recommended entry: ⚙ menu → New Plan Session
        │  (a) ```json code block in the AT message (main path)   (normal sessions work too, user describes the format)
        │  (b) write_file into ~/.alayaface/plans/*.json (listed by the Plans manager)
        ▼
Plan.Detect extracts → plan window AUTO-CREATES (R2, no button)
        ▼
Plan.Types decode + normalize + validate (unique ids / deps exist / acyclic)
        ▼
Save to ~/.alayaface/plans/<planId>.json     ← requirement: JSON writable to file
        ▼
Open Plan window (SVG DAG; nodes clickable)
        ▼
User clicks Run ──► Plan.Runner (pure Elm state machine)
        │   ├─ Effect: createSession {preset?, builtinTools?, toolConfirm="allow"}
        │   ├─ Effect: sendPrompt (node prompt)
        │   ├─ events: SM task / SM error / core-status → step()
        │   ├─ failure → FailureRecord{attempt, reason, at} → auto-retry ≤ maxAttempts
        │   └─ run state written back to <planId>.run.json
        ▼
Node succeeds → unlocks downstream → parallel scheduling (≤ concurrency cap)
```

### Plan Session (P6 + P22 — REMOVED in R2: fixed plan mode)

**Status: removed.** The R-series refactor (R2) dropped the dedicated
"New Plan Session" entry, the `[Plan]` title prefix (`planSessionIds`),
the `builtinTools=""` planner spawn, and the role-locked planner prompt.
Every session is now plan-capable: the planner hint
(`planSystemPrompt`, a constant in App/Update.elm) is injected via
`--system` on ALL user-created sessions — it is advisory ("complex tasks
→ output a plan JSON first"), with no role lock; the model keeps its
tools and may still execute directly. Plan detection (below) works in any
session, and plan-node sessions are unaffected (no planner hint).

> Historical design (no longer implemented): a dedicated menu entry
> created a session with `--system` role-locked to "planner, not
> executor" + `builtinTools=""` (no built-in tools) so the planner could
> physically not execute tasks; its title carried a `[Plan]` prefix.
> P22 background: the model "forgetting its role" was caused by the
> default system prompt ("execute tasks") coming first, planner
> instructions after, and tools fully enabled.

---

## 5. DAG JSON Schema (v1)

```json
{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "monthly-sales-report",
  "goal": "Produce a June sales analysis report",
  "concurrency": 2,
  "default_max_attempts": 3,
  "tasks": [
    {
      "id": "t1",
      "title": "Collect data",
      "prompt": "Collect June sales data from sales.db, tidy it and write to data/raw.json",
      "depends_on": [],
      "preset": "Data",
      "tools": "read_file,write_file,search_content",
      "max_attempts": 2
    },
    {
      "id": "t2",
      "title": "Analyze data",
      "prompt": "Read data/raw.json, do YoY/MoM analysis, write conclusions to data/analysis.md",
      "depends_on": ["t1"]
    },
    {
      "id": "t3",
      "title": "Write report",
      "prompt": "Write the final report.md based on data/analysis.md",
      "depends_on": ["t2"]
    }
  ]
}
```

### Field Reference

| Field | Required | Description |
|------|------|------|
| `type` | yes | Top-level marker `"alayaface-plan"` (P26, **required**, no backward compat): missing → validation error `Missing top-level "type": ...`; wrong value → `Not an AlayaFace plan: ...`; always written on save/export |
| `schema_version` | yes | Fixed 1 |
| `name` | yes | Plan name (used for the file-name slug) |
| `goal` | no | Overall goal, shown in the DAG view header |
| `concurrency` | no | Parallel cap, default 2 (range 1–8) |
| `default_max_attempts` | no | Node default retry cap, default 3 |
| `tasks[].id` | yes | Globally unique, non-empty |
| `tasks[].title` | yes | Node title |
| `tasks[].prompt` | yes | Full prompt sent to the node's session; may reference upstream output via `{{<taskId>.output}}` (P24: replaced at runtime with that task's final answer; can only reference tasks already declared in `depends_on`) |
| `tasks[].depends_on` | no | Dependency id list, default `[]`; references must exist, no self-dependency, overall acyclic |
| `tasks[].preset` | no | Preset name the node runs under; default = active preset |
| `tasks[].tools` | no | Node-level built-in tool set override (comma list); default = preset settings.conf builtin_tools (then default = all) |
| `tasks[].max_attempts` | no | Node-level retry cap; default = default_max_attempts |

### Validation Rules (pure Elm, after decode normalize)

- ids unique & non-empty; title/prompt non-empty;
- depends_on references exist, no self-dependency; **Kahn topological sort detects cycles**;
- normalize: fill defaults, `schema_version` fixed to 1, output **normalized JSON** (that is what is saved to the file);
- validation failure → readable errors listed at the top of the DAG view (e.g. `t2 depends on nonexistent node x`, `cycle detected: t1→t2→t1`).

---

## 6. Elm Module Design (all pure logic, unit-testable)

```
src/Plan/
├── Types.elm    — Plan / TaskNode / NodeStatus / RunState / FailureRecord + JSON codec + validate/normalize
├── Layout.elm   — DAG → layering (Kahn longest path) → per-layer coordinates (x,y) for SVG rendering
├── Runner.elm   — execution state machine: step : Event -> RunState -> (RunState, List Effect)
├── View.elm     — SVG DAG canvas + node detail panel + Plans manager overlay
└── Detect.elm   — extract ```json code blocks from assistant message text
```

### 6.1 Node State Machine

```
Pending → Starting → Running → Succeeded
              ↓          ↓
           (session create failed) Failed (attempts < maxAttempts → Waiting auto-retry → Pending; otherwise Failed terminal)
Blocked   ← any dependency Failed terminal (inherits "blocked by xx" display)
Canceled  ← incomplete nodes when user Stops / Pauses
```

> Implementation deviation: `Waiting` state introduced for the auto-retry
> backoff period (added to NodeStatus); when `ScheduleRetry` (default 2000ms)
> elapses, the `RetryNode` event returns the node to `Pending`.
> `TaskDone`/`SessionError` only take effect for `Running` nodes (idle SM task
> frames during Starting are ignored, avoiding a false task-completion).

### 6.2 Runtime Data Structures

```elm
type alias NodeRunState =
    { nodeId : String
    , status : NodeStatus
    , attempts : Int                    -- attempts so far (which run)
    , maxAttempts : Int
    , sessionId : Maybe String          -- bound session window
    , failures : List FailureRecord     -- newest first, kept cumulatively
    , startedAt : Maybe Int
    , finishedAt : Maybe Int
    }

type alias FailureRecord =
    { attempt : Int      -- which run failed (1-based)
    , reason : String    -- failure reason (SM error text / task_error / disconnect reason)
    , at : Int           -- timestamp (ms)
    }

type Effect
    = CreateSessionFor String            -- node id (carries node preset/tools/toolConfirm)
    | SendPrompt String String           -- sessionId, promptText (resolved from the plan by the runner at bind time, carried with the effect)
    | CloseSessionFor String String      -- sessionId, nodeId
    | ScheduleRetry String Int           -- nodeId, delayMs (default backoff 2000ms)
    | PersistRunState                    -- write <planId>.run.json
    | Notify String
```

### 6.3 Scheduling Rules

- `runnable` = `status == Pending && all dependencies Succeeded`;
- each step starts at most `concurrency - current Running count` → **natural parallel task detection**;
- node succeeds → recompute runnable → start downstream.

### 6.4 Events (fed to step())

- `SessionCreatedFor nodeId sessionId` → bind session → `SendPrompt`
- `TaskDone sessionId result` (SM task `in_progress:false`; `task_error` decides success/failure)
- `SessionError sessionId text` (SM error)
- `SessionDisconnected sessionId reason` (core-status connected=false; treated as failure before done)
- Manual events: `Stop` / `Pause` / `Resume` / `RetryNode nodeId` (manual retry, attempts reset and redo)

**Boot-frame gate (R5 real-core fix)**: alayacore emits a `SM task
in_progress:false` frame at session start (context 0, before any prompt) —
without a gate it is indistinguishable from a real TaskDone: the Runner
marks the just-bound node Succeeded (empty output) → `closeAndClear`
immediately issues `CloseSessionFor` (cancel-first close) → node "Canceled
right after the first prompt", run "completed" in milliseconds (reproduced
on real cores; fakecore's old boot frame lacked `in_progress` → frontend
defaulted to true → E2E never triggered). Gate: `Model.planTaskStarted :
Set String` — TaskDone is only dispatched for sessions that have seen
`in_progress:true` (a real task always starts with it, after the prompt);
the boot frame is ignored. fakecore now mirrors the frame sequence (boot
carries `in_progress:false` + emits `in_progress:true` before replying), so
E2E covers the gate.

### 6.5 Failure & Retry (requirement ③)

- failure → append `FailureRecord{attempt, reason, at}`, `attempts += 1`;
- `attempts < maxAttempts` → `CloseSessionFor` closes the old session → back to `Pending` → `ScheduleRetry` (default backoff 2s) → create a new session (**new process, clean rerun**);
- `attempts >= maxAttempts` → `Failed` terminal → direct/indirect downstream → `Blocked`;
- running nodes can be manually Retried (node detail panel button);
- node cards show a retry badge (e.g. `x2`); failure reason visible on hover; detail panel lists the full failure history (attempt/reason/time).

### 6.6 Layout (Plan/Layout.elm)

- Kahn longest-path layering → layer = column, stacked vertically within a layer → each node `(x,y)`;
- edges are SVG cubic bezier curves;
- pure functions, test cases: diamond / chain / independent parallel graphs.

### 6.7 Capture (Plan/Detect.elm)

- `extractPlanJson : String -> Maybe String`: extract the first ```json … ``` block (unescape, strip fences);
- `hasPlanTypeMarker : String -> Bool`: whether the block's top-level `"type"` == `"alayaface-plan"` (P26);
- called on the latest assistant message at AT frame completion: **first extractPlanJson, then require hasPlanTypeMarker == True** to match (plain ```json code examples — without the marker — are ignored);
- **R2 auto-create (no button)**: a match stores `messageId → rawJson` in `Model.pendingPlanOffers` and immediately issues `PlanCreateOffer` — the Plan window opens automatically, without user confirmation. `messageBoundToPlan` (meta origin) prevents replay duplicates; a parse failure is inlined back into the session as an error message.
- **Replay suppression (P24/P25)**: resuming a session replays its history,
  including plan messages from the MIDDLE (long since completed). The
  replay marker (`Model.planReplaySessions`) is keyed by the ORIGINAL dir
  id at resume-click time, but the replayed frames carry the FRESH resumed
  id — `SessionCreated` moves the marker old→new so a replayed plan
  message never auto-creates a duplicate window/file (it shows the manual
  "Open plan" button instead).
- **P25 (critical ordering fact)**: the marker must NOT be removed on the
  first SM frame. Verified against the real binary (alayadump): alayacore
  emits its boot SM frames (`version`/`task`/`model_list`/`model`/
  `reasoning`/`video_config`) BEFORE replaying history content — the
  opposite of the original assumption. Removing on the first SM dropped
  the marker before the replayed plan message arrived → duplicate
  auto-created windows (exactly the user's bug). The marker is instead
  removed when the USER sends a new message to that session
  (`SendPrompt`) — replayed content is always suppressed, and a live
  follow-up plan message can still auto-create.
- decode/validate (`type` **required**: missing or wrong value rejected, no backward compat) → normalize → generate planId → `fs_write_file_text` writes `~/.alayaface/plans/<planId>.json` → opens the Plan window.

---

## 7. UI Design

### 7.1 Plan Window (independent window, like a session window)
- Each opened plan is an **independent draggable/resizable window** (reusing the session window panel/drag/resize/z-order machinery), not an overlay; multiple plans can be open at once;
- Window title bar: `Plan — <name>` + close button; inside: plan name + goal + run status badge + **Run / Pause / Stop / Retry** + **Load run** + **Export JSON**;
- **The system menu (⚙) lists all open plan windows** (name + run status); clicking raises/activates one; the Plans manager (overlay) browses/opens/deletes/imports `~/.alayaface/plans/*.json`;
- Canvas: HTML/CSS DAG; rounded-rect node cards, colors by status (gray=ready, blue=running, green=succeeded, red=failed, orange=retrying, dashed=blocked/canceled);
- Node cards: `title`, status icon, retry badge `xN`, preset badge, hover shows the latest failure reason;
- **Clicking a node (node ↔ session binding)**:
  - node has sessionId (succeeded nodes keep the binding; run.json persists `session_id`):
    - session window still alive → `ActivateSession` raises and focuses it;
    - session closed / after restart → **automatically `resume_session` from disk** (full history restored, title shows the `[Plan · planId/nodeId]` binding marker); restore failure is reported at the top of the plan window;
  - node has no sessionId but has `lastSessionId` (Failed/Blocked/Canceled: session was closed by the runner) → **likewise auto `resume_session`** — failed/stopped node sessions are no longer lost, history can be reviewed anytime;
  - neither → right-side node detail panel (full prompt, dependencies, failure history, Retry);
  - **resume id semantics (P18 fix)**: `resume_session` issues a **new UUID** each time but **reuses the original on-disk dir**; the node **always stays bound to the original id (the dir name)**; `planResumedFrom` (live id → original id) records the mapping for the current session:
    - clicking the node while the session is alive → `findResumedLive` finds the live window and focuses it;
    - clicking again after closing → `resume_session` the original id again (the dir is still on disk), can open/close repeatedly with no "Session directory not found";
    - run.json always persists the original id → restorable after app restart;
    - `CloseSession` / `findPlanIdBySession` use `planResumedFrom` to attribute a closed live window back to its plan node (disconnect → node failure retry unchanged);
- **Opening a plan window auto-restores bindings**: opening/importing a plan file silently reads `<plan>.run.json` (best-effort) and restores node states and sessionIds — afterwards clicking any already-run node reopens its session; **Load run** goes further and continues executing unfinished tasks;
- **Node ↔ session connection curve (P19)**: when focusing a session that belongs to a plan node —
  - that plan window is automatically raised to the **second layer** (session z = plan z + 1);
  - bridge.js draws a **bezier curve** on `<body>` (rAF measures DOM `getBoundingClientRect` every frame; follows drag/resize/scroll), from the midpoint of the session window edge nearest the node to the node card center, z-index = the plan window's value (same value + inserted later in body → above the plan, below the session);
  - pure logic in `App/NodeConnection.elm` (`planNodeSessions` tags + P18's `planResumedFrom` resolves live ids from resumes; node ids may contain `/`);
  - disappearance: focusing a non-node session / plan window, closing or deleting that session or plan window; JS hides it automatically when the node scrolls out of the visible canvas;
- Bottom: run log stream (node start/success/failure/retry events);
- **Stop semantics (P23)**: clicking Stop = stop **all in-progress node sessions owned by this plan run** — the runner marks running/starting nodes Canceled, `closeAndClear` issues `CloseSessionFor` for every node with a bound session → **kills the alayacore process and closes the session window at once** (history stays on disk; clicking the node recovers it). **Not stopped**: succeeded nodes' sessions (kept viewable), other plans' sessions, normal sessions, planner sessions;
- Closing the plan window does not stop running node sessions (run.json keeps flushing; Load run can restore); manually closing a node session window injects a disconnect event into the runner → the node fails and retries.

### 7.2 Plans Manager (overlay, modeled on the Session Manager)
- Two tabs:
  - **Saved**: lists `~/.alayaface/plans/*.json` (filtering out `*.run.json`), with a fuzzy filter input (`Fuzzy.fuzzyMatch`); actions: Open (renders DAG), Delete;
  - **Browse**: file browser, **reusing the multimodal file picker** (`Overlay.FilePicker.view` + `Session.FilePicker` pure logic + `Fuzzy.elm`): directory navigation (fs_resolve_path / fs_list_dir), fuzzy filtering, click to enter a directory, click/Enter to import a plan JSON (via the `PlanReadTarget` + fs_read_file_text flow, from anywhere);
- Entry: a **Plans** item in the global menu (existing `showGlobalMenu` system).

### 7.3 Runner Sessions
- Plain session windows (clickable/viewable) with a `[Plan]` prefix in the title;
- Create args: `toolConfirm="allow"` (auto-approve tools, avoids confirmation-modal stalls), `preset`, `builtinTools` (node-level override).

---

## 8. Backend & Port Changes (minimal, dual-backend parity)

### 8.1 File Read/Write Commands (P1)

| New command | Rust | Go | bridge.js | Ports.elm |
|---|---|---|---|---|
| `fs_write_file_text {path, content, createParents}` | `commands/fs.rs` | `handlers/fs.go` | new port | `fsWriteFileText` + `onFsWriteResult` |
| `fs_read_file_text {path}` | `commands/fs.rs` | `handlers/fs.go` | new port | `fsReadFileText` + `onFsReadResult` |

- Error messages: `Cannot write file: ...` / `Cannot read file: ...` (aligned with existing style);
- `createParents=true` auto-creates parent dirs (first save of the plans dir);
- Path policy reuses existing fs commands (no absolute-path restrictions; export goes through the FilePicker);
- Tauri capabilities unchanged (custom commands don't go through the permission system);
- Registered in `generate_handler!` / the RPC dispatcher; `docs/go-backend.md` command map updated in sync.

### 8.2 Built-in Tool Set = a second tool_confirm (symmetric design, constraints C1/C4)

| Layer | Change |
|---|---|
| `src-tauri/src/alayacore.rs` `spawn()` | add a `builtin_tools: &str` argument; append `--builtin-tools=<list>` when non-empty (alongside `--tool-confirm`; **empty = not passed = alayacore default all tools**) |
| `src-go/internal/core/core.go` `Spawn` | same as above |
| `commands/settings.rs` + `handlers/settings.go` | `GlobalSettings` gains a `builtin_tools` field; get/sync support read/write; normalization reuses `normalize_tool_confirm` (trim/dedup/reject spaces) |
| `commands/sessions.rs` + `handlers/sessions.go` | `create_session` gains an optional `builtinTools` argument (explicit override; default = active preset settings.conf builtin_tools) — fully symmetric with the existing `toolConfirm` logic |
| `commands/sessions.rs` + `handlers/sessions.go` | `create_session` gains an optional `preset` argument: internally copies **the given preset** into `session_dir/config` (reusing `dirs::copy_dir_excluding`, excluding settings.conf), default = active preset (existing behavior). **Must not pass the preset path directly as configPath** (breaks resume_session) |
| `bridge.js` + `Ports.elm` | `createSession` port carries `toolConfirm` / `preset` / `builtinTools` fields |
| `Overlay/Settings.elm` | add a "Built-in tools" input (alongside Tool confirm), configurable per preset |
| Tests | Rust unit tests + Go unit tests + error-message parity assertions |

**Flag semantics note**: alayacore `--builtin-tools` unspecified = all tools; explicit empty string = no built-in tools (MCP-only). v1 supports only two states: **empty = all, non-empty list = subset**; MCP-only is an edge case — if needed, discuss a `"none"` special value.

### 8.3 Graceful Close (close_session, P12 evolution → P25 cancel-first)

**Problem**: the original `close_session` SIGKILLed the child directly. alayacore
only writes the full session to `session.alaya` in `handleTaskDone` (task end)
and on the `:save` command, and the rawio adapter has **no** SIGINT handler —
so closing a window = discarding the in-flight turn (same when the app is
killed). C1 forbids modifying alayacore, so we can only control **what we send /
how long we wait** (alayacore's exit paths were verified read-only).

**Verified alayacore facts**:
- `save` CI command with empty args = save to the `--session` file (`session.alaya`);
- `cancel` CI command = cancel the current task (`activeTask.cancel()` via the per-task context) → the task goes through `taskResultCh` → `handleTaskDone` **auto-saves** up to the cancel point; with no task it returns `NOTHING_TO_CANCEL`;
- stdin EOF + active task → `drainUntilTaskDone()`: runs the task to completion (`handleTaskDone` auto-saves) then exits; EOF + no task → exits immediately (no save);
- rawio has no SIGINT handling (only plainio/terseio do); EOF is the only graceful exit signal.

**AlayaFace-side implementation (dual-backend symmetric, P25: cancel-first, no backward compat)**:

```
close_session:
  1. send CI "cancel" (best-effort, fire-and-forget: cancels the current task →
     alayacore saves up to the cancel point; errors ignored if no task/process dead)
  2. send CI "save" (best-effort, disk-write fallback)
  3. close stdin → EOF (task already canceled → exits immediately, no drain-to-complete)
  4. wait ≤ 5s for natural exit (GRACEFUL_CLOSE_TIMEOUT)
  5. still alive → SIGKILL fallback
```

- **Why cancel-first**: Stop / closing a session window means "stop now", not
  "wait for the task to finish". P12's drain semantics (run the current task to
  completion after EOF) let a Running node keep executing up to task end after
  Stop (user-tested: Stop couldn't stop all nodes). The cancel command is
  natively supported by alayacore (C1-safe): the task is canceled →
  `handleTaskDone` auto-saves → history is kept up to the cancel point (loses
  less than SIGKILL, waits less than drain). All close_session calls are
  cancel-first with no compat argument (user explicitly required "no backward
  compatibility");
- `kill_child` / `KillChild` (Drop / disconnect path) keeps **EOF grace 3s
  then kill**: that path only has the child handle (no stdin pipe), so it can't
  send CI cancel; when stdout disconnects the child has usually exited, so it
  returns immediately;
- Rust side `SessionHandle.stdin` becomes `Arc<tokio::sync::Mutex<Option<ChildStdin>>>`:
  graceful close sets the slot to `None`, i.e. closes the pipe (not dependent on
  Arc refcount); writers (send_prompt / send_raw) return "Session is
  disconnected" for `None`; synchronous contexts use `try_lock`
  (spawn_blocking / Drop);
- Go side `closeGracefully` does **not call `cmd.Wait()` itself** — reaping is
  uniformly handled by the reader disconnect path's `killOnce → KillChild`
  (`os/exec` forbids concurrent Wait; the race detector flagged it in testing);
  it only polls `Connected()` until stdout EOF (= child exited naturally) or
  timeout, then `kill()`;
- fakecore hang mode: hang-once no longer `sleep`s and blocks the main loop —
  while hung it keeps reading stdin, swallows UE, and answers CI `cancel`
  (task-done frame + CO), simulating alayacore's "task stuck but command loop
  alive" (real alayacore's cancel goes through cancelReqCh, independent of the
  input pipe);
- Tests: Rust (cancel frame reaches child stdin before save / stubborn child
  killed on timeout / kill_child grace / dead child no panic); Go integration
  (fakecore `save` writes a session.alaya marker → after close the file contains
  the saved marker; new `TestIntegrationCloseCancelsHungTask`: hung task exits
  <3s after close, proving cancel interrupts the hang instead of waiting out
  the grace SIGKILL); E2E (after Stop, the hung t3 session closes immediately).

**Known limitation**: if the cancellation itself gets stuck (extreme), the 5s
grace + SIGKILL still backstop it — but the `save` frame has already flushed, so
at least everything before the task start survives; "resume an unkillable
process" stays v2 (resume the child).

### 8.4 Directory Isolation (per-plan working directory, P16)

**Problem**: all alayacore child processes share cwd = the backend process's
startup dir. Parallel nodes clobber each other's files, plans pollute each
other, and the backend cwd gets written into.

**Solution**: **per-plan working directory** `~/.alayaface/plans/<planId>/work/`
— all node sessions of one plan share it (file-passing mode still works: t1
writes a file, t4 can read it), plans can't see each other's files, and the
backend cwd stays clean. Normal sessions / fork / probe don't pass it (keep the
backend cwd, backward compatible).

- `create_session` / `resume_session` gain an optional `workDir`: non-empty → backend `MkdirAll` + spawn with child cwd (Rust `Command::current_dir` / Go `cmd.Dir` — **pure AlayaFace-side change, C1-safe**, alayacore is unaware);
- Plan Mode node sessions derive `planWorkDir planId model` in Elm (when homeDir is known) and pass it on both create and resume;
- Tests: Go integration (create/resume with workDir → fakecore boot frame reports `cwd`, asserted to match; without → backend cwd) + Rust mechanism-level (current_dir applies) + E2E (after Run, assert `plans/<planId>/work` exists).

### 8.5 Task Timeout (P16 — REMOVED in R1)

**Status: removed.** The R-series refactor (R1) deleted task timeouts
entirely: the `default_timeout_seconds` / `timeout_seconds` schema fields,
the `Time.every` tick subscription, and the `Tick` event are gone. Nodes
have no timeout — a hung task stays Running until the user Stops it
(cancel-first close, §8.3) or the session disconnects. Hung nodes are an
accepted experience-period limitation (see REFACTOR.md §8).

Historical design (for reference, no longer implemented): `Time.every
1000ms` → `PlanTick` → `Tick now` → `failNode "Timeout after Ns"` for
`Starting/Running` nodes past their limit, with the failure path reused
(close + auto-retry / Failed + downstream Blocked).

### 8.6 Output Injection (`{{tX.output}}`, P24)

**Problem**: downstream tasks often need upstream outputs (e.g. "write the
report based on t1's research"). v1 prompts are self-contained → the
downstream model can only re-search or make things up (real-model run testing:
t4 needed t1/t2/t3 results but couldn't get them).

**Solution**: `tasks[].prompt` supports the template `{{<taskId>.output}}`,
replaced at runtime with that task's **final answer at completion** (the last
non-empty assistant text in the session):

- **Recording**: at TaskDone (SM task-end frame), the Update layer extracts the
  last assistant text from the session's message history (frames are ordered:
  AT arrives before the SM task-done frame) → carried as `R.TaskDone sid
  isError output` → the runner writes `NodeRunState.output` on success; not
  recorded on failure/retry;
- **Injection timing**: a node is only scheduled (Starting) after all
  dependencies Succeeded, and bindSession resolves the template when generating
  `SendPrompt` — upstream outputs are guaranteed to exist by then; template
  replacement is the pure function `Plan.Inject.injectOutputs` (find
  `.output}}` after `{{`, exact match no spaces; unknown id / no output →
  replaced with a placeholder notice, **the raw template is never
  leaked to the model**; `{{` without `.output}}` is kept verbatim);
- **Persistence**: `output` is written to run.json (§10) → after restart /
  silent restore, downstream nodes can still inject when starting (upstream
  Succeeded nodes don't rerun; output must survive restarts); re-Run
  (StartRun) clears all outputs (a fresh round);
- **UI**: the node detail panel shows Output (placeholder when none);
- **Planner teaching**: the Plan Session's `planSystemPrompt` tells the model:
  when a downstream task needs upstream output, reference it with
  `{{t1.output}}` (only for tasks already declared as dependencies);
- Tests: `PlanInjectTest` (10 cases: replace/missing/unknown/keep-verbatim) +
  runner (success records, failure doesn't, downstream SendPrompt injects,
  missing → placeholder, re-Run clears) + codec roundtrip + E2E (fixture t2
  prompt references `{{t1.output}}`; fakecore echoes the received prompt →
  assert t2's session contains t1's output text and no raw template).

---

## 9. Presets & Seed Presets

- Node `preset` default = active preset (consistent with existing behavior);
- seed presets (built into the repo, seeded on first run, modeled on the Default mechanism `create_preset_defaults`):

| preset | role | model.conf | builtin_tools (settings.conf) |
|---|---|---|---|
| `Default` | general | default placeholder model | (empty = all) |
| `Fast` | quick subtasks (cheap model) | lightweight model placeholder | (empty = all) |
| `Deep` | complex analysis/planning | strong model placeholder | (empty = all) |
| `Data` | data tasks | default | (empty = all) |
| `Safe` | safety-sensitive subtasks | default | `read_file,write_file,edit_file,search_content` (**no execute_command**) |

- Seed presets are just structural templates (model/MCP placeholders); the user
  fills in api_key/connection strings; the preset manager supports
  copy/rename, so users can customize from a seed;
- v1 stage: P0–P4 nodes all use the active preset (the preset field is
  optional); preset support lands with P4.5.

---

## 10. Persistence

```
~/.alayaface/plans/
├── <planId>.json        ← normalized plan (user-exportable/editable)
└── <planId>.run.json    ← run state (node states/attempts/failure records/sessionId map/timestamps)
```

- planId = name slug + timestamp (e.g. `monthly-report-1722864000000`);
- disk write on every state transition: terminal transitions always written, intermediate transitions throttled;
- node binding multi-field persistence: `session_id` (current active binding), `last_session_id` (the most recent session that ran the node, even if closed/failed, still `resume_session`-able for review), `attempt_session_ids` (**all** session ids ever bound to the node, deduped, kept across retries/runs), `output` (the node's final answer on success, for downstream `{{tX.output}}` injection) → node ↔ session bindings survive restarts; old attempt sessions are no longer lost when retries rebind (the node detail panel's "history sessions" list opens them directly); silently restored when opening a plan window; clicking a node reopens its session;
- **Resume (v1)**: reopen the app → open the plan → restore from run.json; unfinished/failed/blocked nodes **re-execute from scratch** (new sessions; no child-process resume; true checkpoint resume is v2);
- **Close-to-persist (cancel-first close, §8.3)**: close_session first sends CI `cancel` (cancels the current task → alayacore **auto-saves up to the cancel point** via handleTaskDone), then `save`, then closes stdin (EOF → task already canceled → exits immediately) → waits ≤5s for natural exit → SIGKILL fallback; the Drop/disconnect path goes through kill_child with a 3s EOF grace. Everything before the cancel point is preserved in full (loses less than SIGKILL, waits less than drain).

---

## 11. Test Plan

| Layer | Content |
|---|---|
| Elm unit tests | `Plan/Types`: decode success/failure, cycle detection, unknown dependency, duplicate ids, normalization, roundtrip; `Plan/Layout`: diamond/chain/parallel layering coordinates; `Plan/Runner`: concurrency cap, dependency gating, retry counting & FailureRecord appending, Stop/Pause/manual retry, disconnect & task_error handling; `Plan/Detect`: fenced extraction boundaries |
| Rust unit tests | fs_write/read roundtrip, createParents, error messages; settings builtin_tools normalization; create_session preset/builtinTools arguments |
| Go unit tests | same as above + error-message parity assertions against Rust |
| Integration | fakecore extensions: simulate task_error → runner retries → second attempt succeeds; end-to-end: Create Plan → save → Run → parallel windows → click node to open window |

---

## 12. Phased Implementation Plan (progress in TODO.md)

| Phase | Content | Status |
|---|---|---|
| P0 | `Plan/Types` + `Plan/Detect` + all unit tests | ✅ done |
| P1 | `fs_write_file_text` / `fs_read_file_text` (Rust+Go+bridge+Ports) + unit tests | ✅ done |
| P2 | plan capture + auto-save plans dir + Plans manager (list/open/delete/import); R2: auto-create replaces the button | ✅ done |
| P3 | `Plan/Layout` + DAG view (HTML/CSS, not SVG) + node detail panel | ✅ done |
| P4 | `Plan/Runner` state machine + Run/Pause/Stop/Retry + failure retry & reason recording + run.json persistence + Resume | ✅ done |
| P4.5 | `create_session` gains `preset`/`builtinTools` arguments + settings.conf `builtin_tools` + seed preset seeding | ✅ done |
| P5 | polish (run log/docs/README etc.) | ✅ done |
| P6 | Plan Session (menu entry + `--system` planner instructions + `[Plan]` title) | ✅ done |
| P17–P23 | Plans manager Browse import / node-session resume dir id / node↔session connection curve / config empty shells / Plan Session role lock + no tools / Stop closes node windows (see TODO.md) | ✅ done |
| P24 | output injection `{{tX.output}}` (§8.6: TaskDone records output → run.json persistence → downstream SendPrompt replacement → detail panel display) | ✅ done |
| P25 | close_session cancel-first (§8.3: Stop/close window immediately cancels the task, history saved up to the cancel point) | ✅ done |
| P26 | plan JSON top-level `"type": "alayaface-plan"` marker (§5/§6.7: the button only recognizes the explicit marker; **required, no compat** — missing/wrong value errors out) | ✅ done |

> Implementation deviations: the DAG renders in pure HTML/CSS (absolute-positioned
> divs + orthogonal connectors) because elm/svg isn't in the offline package
> cache; the effect is equivalent to SVG. Session creation is **serialized**
> (one in-flight create at a time; `planCreating`/`planCreateQueue` globally
> record `(planId, nodeId)`), and `SessionCreated` binds to the node via
> `PlanBindSession`. **Plan windows are multi-instance**
> (`planWindows : Dict String PlanWindow`, each window owns its run
> state/log/selected node/create queue), switched via the ⚙ system menu rather
> than a single overlay; `SendPrompt` resolves the node prompt text in the
> runner **at session bind (Starting→Running) and carries it with the effect**
> (`SendPrompt sid promptText`); the Update layer doesn't re-look-up — two early
> defects (① the runner never generated SendPrompt; ② after generating it, the
> Update layer looked the prompt up in the pre-step stale run state and the
> empty result was dropped) both caused node sessions that opened with no
> messages.

---

## 13. Decision Log

### Confirmed (explicit user instructions)
- **Don't modify AlayaCore** (constraint C1);
- built-in tool set is specified **via spawn arguments** like tool confirmation (`--builtin-tools`), config lives in settings.conf (per-preset, symmetric with tool_confirm);
- design is written into this document + TODO.md manages subsequent development (read this + TODO.md first after an interruption);
- **Plan Session entry (superseded by R2 — fixed plan mode)**: originally the
  user only describes the need, a dedicated menu entry created a role-locked,
  tool-less planner session with a `[Plan]` prefix. R2 removed the entry: every
  session carries the advisory planner hint via `--system`, and plan windows
  auto-create on detection.
- **plan JSON top-level `"type": "alayaface-plan"` marker (P26, user instruction)**:
  only ```json blocks carrying the explicit marker are treated as plans (plain
  code examples don't false-trigger); always written on save/export;
  **required, no backward compat** — missing or wrong value errors out directly
  (`Missing top-level "type": "alayaface-plan" marker` /
  `Not an AlayaFace plan: ...`).

### Defaults (not explicitly confirmed; implemented as follows, adjustable at review)
- `concurrency` default 2 (1–8 adjustable);
- `default_max_attempts` default 3, retry backoff 2s;
- failure determination: SM task_error / SM error / session disconnect (**task timeouts were removed in R1** — a hung node stays Running until Stop / disconnect);
- downstream context: prompts support upstream output injection via `{{<taskId>.output}}` (P24 implemented; §8.6); unreferenced downstream prompts stay self-contained;
- Runner sessions `toolConfirm="allow"`;
- file location `~/.alayaface/plans/<planId>.json`; Resume v1 = rerun unfinished nodes;
- plans are read-only display (node editing v2);
- seed presets: Default / Fast / Deep / Data / Safe;
- graceful close (§8.3): close_session = **cancel → save → EOF → 5s grace → SIGKILL** (P25 cancel-first: cancel the task and save up to the cancel point, don't wait for completion); kill_child/KillChild = EOF → 3s grace → SIGKILL;
- the plan header can override concurrency (1–8, empty = the plan JSON's concurrency; P14 implemented);
- **per-plan working directory** (§8.4): node sessions' cwd = `plans/<planId>/work/`; normal sessions keep the backend cwd (P16 implemented).

### Pending (v2, non-blocking)
- node `outputs` field (artifact descriptions; stored but unused for now);
- true checkpoint resume (resume the child process);
- MCP-only mode (`builtin_tools: "none"`).

---

## 14. References

- `docs/go-backend.md` — Go backend contract (field naming / error messages / command map)
- `docs/manual-acceptance.md` — manual acceptance checklist for GUI environments (follow when a GUI is available)
- `src-elm/src/Session/Protocol.elm` — event decoding contract
- `src-elm/src/Session/Handlers.elm` — existing task status / tool call handling
- `src-tauri/src/dirs.rs` / `src-go/internal/dirs/dirs.go` — preset/session directory structure
- `src-tauri/src/commands/settings.rs` — existing settings.conf implementation (builtin_tools symmetric reference)
- archived old Go backend working notes: `docs/go-backend-todo.md`
