# Plan Mode Refactor (P39): session lineage + cascade state machine + in-canvas curves

> **Main refactor document.** Interrupt recovery:
> 1. Read this file (design + phase flow) → read `TODO.md` (P39 task list) → continue
>    from the first unchecked item;
> 2. Each completed phase → run the full test suite
>    (`src-elm/elm-test` / `src-tauri/cargo test` / `src-go go test ./...` /
>    `node --check src-elm/{chain,transport,overlay}.js`) → commit → push to all
>    three remotes (origin / gitee / org, main branch);
> 3. Constraints unchanged: **NEVER modify AlayaCore**; both backends stay
>    symmetric; pure logic goes into `Plan/*` for unit testing.

---

## 0. Background: why refactor

The P34–P38 patches piled up to an unmaintainable degree and repeatedly caused
user-visible failures (top-level sessions disappearing, closes hitting the wrong
window, broken curves, overlays occluded). Three root causes:

1. **Fighting the backend**: alayacore's `session.alaya` is in-place append-only
   (C1 cannot change it); the UI can only "truncate history" via the fork command,
   and P38 chose to fork to a new file — but a fork creates a NEW identity, and P38
   used a pile of patches (rebinding `node.sessionId`, moving `planNodeSessions`
   labels, rewriting `meta.origin`, closing the original session, replay markers,
   focus contention) to pretend the new identity was the old one. A structural
   cost, not an implementation problem.
2. **Cascade and truncation conflated**: cascade (A re-runs → B node re-answers →
   downstream invalidation re-runs → propagates upward) does not depend on
   truncation; P38 nonetheless made fork the cascade's carrier, introducing a
   whole async handoff.
3. **Implicit state machine**: cascade logic is scattered across
   `feedbackCompletedPlan` / `runStepIn` / `adoptCascadeFork` / `SessionCreated`,
   advanced implicitly by event arrival order (D11 vs fork result, SessionCreated
   vs adoption) — untestable, un-reason-about-able.

**Conclusion (user confirmed the direction)**: truncation = fork to a new file
(keeping the hard requirement of a clean model context); but the identity layer
is redone as **session lineage** — a stable conversation id + a physical
instance chain, bindings never change, fork is an append operation on the
lineage rather than an identity replacement. The cascade is redone as a pure
state machine.

---

## 1. Constraints (non-negotiable)

| # | Constraint |
|---|---|
| C1 | **NEVER modify AlayaCore**. `session.alaya` is in-place append-only, with no delete/rewrite commands; the `fork` CI command (input `<historyId> <targetFile>`) is the only channel that can produce a "truncated history file" — it writes the truncated history to **any target file** (technically it can also overwrite the source session's own file, i.e. in-place truncation); **this project always passes a new session directory's file** (see D2) — a usage decision, not an alayacore capability limit |
| C2 | Both backends symmetric (Rust `src-tauri` / Go `src-go`): any backend change goes into both identically + each has its own tests |
| C3 | Pure logic goes into `Plan/*.elm`, pure functions + unit tests; App/Update only dispatches |
| C4 | Frontend = Elm 0.19 (no extra package dependencies; elm/svg unavailable — curves use native `<svg>` DOM, via chain.js) |
| C5 | New parameters/fields are all backward compatible (old data decodes, missing gets defaults) |

---

## 2. Confirmed decisions (approved item by item by the user; do not change)

| # | Decision |
|---|---|
| D1 | **Re-run = replace semantics**: when a re-run succeeds and the result changed, the parent session continues from the new result (truncate the old + insert the new) |
| D2 | **Truncation = fork to a new file** (not append+trim): a clean model context is a hard requirement — the old result and its old continuation must truly disappear from the model-visible history; history files stay bounded |
| D3 | **Identity = session lineage, first-class + persisted**: conversation = stable id (= the root id that created the session) + a physical instance chain (root → fork1 → fork2 …). Bindings (plan origin, node session) point at the conversation id and **never change**; physical instance → conversation resolves via the lineage table |
| D4 | **Cascade = pure state machine** (`Plan/Cascade.elm` upgraded to Plan/Runner's peer): Event/Effect/step, explicit handoff states (WaitingFork / WaitingInstance / WaitingNode / BranchRunning), **zero ordering assumptions** |
| D5 | **Curves drawn inside the canvas**: canvas coordinates + transform give free pan/zoom; redraw only on discrete events (window drag/zoom, plan canvas scroll); eliminate the body-level SVG, `canvasZBase()` offset, per-frame rAF, and overlay occlusion |
| D6 | **Bounded z**: focus = window list order (the DOM end is the topmost) + rebase over a threshold; eliminate unbounded `nextZIndex` and the z-cap patch |
| D7 | **Close = one ownership-graph traversal**: session → the plans it created → their node sessions → child plans; eliminate the `PlanClose ⇄ CloseSession` mutual recursion |
| D8 | **Keep**: `parentPlanId` (lineage query / impact scope), impactScope + confirm dialog (wording changed to "old results will be truncated"), ancestor reopen queue (cascade needs ancestor runs), `ResumeBranchFrom`, summary gate, `Plan/Runner`, the `fork_session` backend extension (Rust+Go, optional params, used by both manual fork and lineage instances) |
| D9 | **Delete the P38 adoption mechanism**: the UI-side `cascadeForkSession` port/transport handler, `adoptCascadeFork`, the `planCascadeFork` field, the `parentSessionId`/`parentSessionOf` patches, the fork replay-marker patches, deferred D11, closing the original session on adoption, closing child plans on confirm, fork focus contention — all replaced by lineage + the state machine |

---

## 3. Architecture

### 3.1 Session lineage (identity layer, Phase B)

**Persistence**: each session directory gains `sessions/<id>/session.meta.json`
(UI-written, via fs_write):
```json
{ "conversation_id": "<root session id, never changes>",
  "parent_instance_id": "<parent instance id; null for root>" }
```
The lineage chain = backtracking the parent pointers to the root. On fork: the
new instance writes `{ conversation_id: same root, parent_instance_id: current head }`.

**In-memory registry**: `instanceId → conversationId` (root maps to itself),
rebuilt by session open / extending the existing plan-meta scan (reading each
session.meta.json).

**Binding semantics (change points)**:
- `meta.origin.sessionId` = conversationId (= the root id that created the
  session, **never changes**; planIndex unchanged)
- Node bindings: `NodeRunState.sessionId` **renamed/re-semantized to
  `conversationId`** (stable, persisted into run.json); drop the physical-id
  dependencies in `lastSessionId`/`attemptSessions` (either conversationId or
  instance id works — see TODO B3 details)
- Frame routing: physical instance id → registry → conversationId →
  `nodeBySessionId(conversationId)` (one dict lookup per event, O(1))
- Open/resume node session: conversationId → instance chain → **head (latest
  live instance)** → activate / resume head

**Fork handoff (inside the state machine — the only allowed "state switch")**:
```
Fork(conversation) → backend fork_session(head instance, historyId=one before the insertion point) → InstanceReady(newId)
  → register lineage (write session.meta.json + in-memory table)
  → close the old head instance's window (after a disconnect resolves through the
     registry, the node for this conversation is not found? — no: the node binds
     conversationId; the old instance's disconnect event carries the physical id
     → resolves to the conversation → the node is WaitingForPlan (reset by the
     machine) → no false failure; closing the old instance's window only cleans UI)
  → send [Plan Result] to the new instance (after the insertion point) → ResumeNode(conversationId)
```
**Deleted**: `parentSessionId`, `adoptCascadeFork`, `planCascadeFork`, replay
marker patches, fork focus contention (the new instance's window = the same
conversation's window, same title — no "adoption" needed).

### 3.2 Cascade state machine (Phase C)

`Plan/Cascade.elm` (in the style of Plan/Runner's Event/Effect/step):
```elm
type Event
    = ReRunConfirmed ImpactScope          -- user confirms the re-run
    | PlanCompleted String                -- planId (gate judged inside the machine)
    | NodeSucceeded String String         -- planId, nodeId (resumed node answered)
    | LevelFailed String String           -- planId, nodeId (fail/stop → cascade aborts)
    | InstanceReady String (Result String String)  -- fork result (new instance id / error)

type Effect
    = ForkInstance ForkArgs               -- backend fork_session
    | InsertResult String String String   -- planId, instanceId, summary (send [Plan Result])
    | ResumeNode String String String     -- planId, nodeId, conversationId
    | BranchRerun String String           -- planId, nodeId (reset propagates downstream)
    | OpenAncestor String                 -- reopen the ancestor window (to get the run)
    | PersistMeta String                  -- write meta / session.meta.json

cascadeStep : Int -> Event -> CascadeState -> ( CascadeState, List Effect )

type alias CascadeState =
    { rootPlanId : String
    , rootOldSummary : String
    , levels : List CascadeLevel          -- nearest ancestor first
    , phase : CascadePhase }              -- WaitingFork | WaitingNode | BranchRunning | Done

type alias CascadeLevel =
    { planId : String, nodeId : String, conversationId : String, oldSummary : String }
```
- Every async boundary is an event: `InstanceReady` (fork result), window
  opening (OpenAncestor's completion is driven by the planReadTarget stream-end
  event; the machine does not care, it only waits for PlanCompleted).
- **gate** (summary unchanged → silently skip the whole level, cascade ends)
  lives inside the machine.
- Fail/stop: LevelFailed → cascade aborts, state rolls back to "not started"
  (no identity change, naturally residue-free).

### 3.3 In-canvas curves (Phase A)

- One `<svg class="connection-layer">` inside `.canvas`, `position:absolute; left/top:0`,
  sized to the participating windows' bounding box (recomputed when the chain changes).
- **Coordinates = canvas coordinates**: window positions come from
  `model.windowPositions` (known to Elm); node coordinates = plan window position
  + `Plan.Layout` layout coordinates − plan canvas `scrollTop` (DOM state,
  reported back via a scroll port).
- **Redraw triggers (discrete)**: window drag/zoom (Elm mousemove/resize events),
  plan canvas scroll (scroll port), chain changes. **No per-frame rAF loop.**
- Stacking: curves render as canvas children, sorted by z → no body stacking, no
  `canvasZBase`, never covers overlays (overlays are outside the canvas, z=1000000 kept).
- Stroke-width compensation: `stroke-width = 3 / canvasScale`.

### 3.4 Z manager (Phase A)

- Focus = window list order: the last of `sessionOrder`/`planOrder` is topmost
  (DOM order layers naturally).
- The only places needing numeric z are curves (in-canvas sorting) and windows
  overlapping — all through `App/Windows.elm`'s `raiseWindow`: `nextZIndex` over a
  threshold (e.g. 500) → rebase everyone (subtract a constant).
- Deleted: `canvasZBase()`, chain.js's z-cap (replaced by in-canvas sorting),
  `CHAIN_Z_CAP`.

### 3.5 Close semantics (Phase D)

- Ownership graph (after lineage resolution): conversation → the plans it created
  (meta.origin match) → each plan's node sessions (conversationId match) → recurse.
- `CloseConversation` / `ClosePlan` each do a single traversal; no more mutual
  `dispatch` recursion.
- `Ctrl+W` closes the topmost window (the already-fixed `planFocusAboveSession`
  stays; folded into this phase's verification).

---

## 4. Module map (current → target)

| File | Action | Notes |
|---|---|---|
| `src-elm/src/Plan/Cascade.elm` | **rework** | currently pure helpers (impactScope/insertPrefix/transitiveSuccessors/findInsertionIndex/feedbackSummary…): keep the pure helpers, add the `CascadeState`/`Event`/`Effect`/`cascadeStep` state machine |
| `src-elm/src/Plan/Runner.elm` | keep + tweak | `ResumeBranchFrom` kept; `nodeBySessionId` semantics change to conversationId with B3 |
| `src-elm/src/Plan/Meta.elm` | **change** | keep `parentPlanId`; **delete** `parentSessionId`/`parentSessionOf`; add session.meta codec (or a new module) |
| `src-elm/src/Plan/Update.elm` | **big change** | delete `adoptCascadeFork`/`forkRequestFor`/`forkLevelFor`/`rewriteParentSession`/`resetDelegatedNode`/`advanceCascade`/`cascadeAfterStep` (merged into the machine); `feedbackCompletedPlan` only: gate → result insert (fork handoff driven by the machine); `openNextOrStart`/`startCascadeNow` kept and reworked |
| `src-elm/src/App/Update.elm` | **change** | delete `PlanCascadeForkResult`; `PlanCascadeConfirm` simplified (no longer closes child plans); `scopeCtx` kept; `planFocusAboveSession` kept |
| `src-elm/src/App/Types.elm` | **change** | delete `planCascadeFork`; `planCascade`/`planCascadePreview`/`planCascadeOpenQueue`/`planSuppressFeedback` reorganized per the machine (suppressFeedback may go if no child-plan closing) |
| `src-elm/src/App/Windows.elm` | **change** | `raiseWindow` + rebase (D6); `chainCtx.planOrigins` uses `meta.origin.sessionId` (no parentSessionOf needed after lineage) |
| `src-elm/src/App/View.elm` | **change** | confirm-dialog wording; no collapse-section UI needed (fork, no trim); curves untouched (canvas layer lives in chain.js) |
| `src-elm/chain.js` | **rewrite (Phase A)** | body SVG → in-canvas SVG; canvas coordinates; discrete redraw; remove rAF loop/z-cap/canvasZBase |
| `src-elm/transport.js` | **delete** | `cascadeForkSession` handler (fork results go through the generic `onSessionCreated` + events into the machine) |
| `src-elm/Ports.elm` | **delete/change** | delete `cascadeForkSession`/`onCascadeForkResult`; add the plan canvas scroll port (Phase A) |
| `src-elm/style.css` | **change** | `.connection-layer` in-canvas styles; `.overlay` z=1000000 kept; `.media-preview-overlay` z=1000001 kept |
| `src-tauri/.../sessions.rs` + `src-go/.../sessions.go` | **keep** | the `fork_session` extension (optional params) unchanged; lineage instance registration is the UI writing session.meta.json |
| `src-elm/tests/PlanCascadeTest.elm` | **extend** | state-machine step unit tests (each event/each phase/failure/gate) |
| `e2e/plan-e2e.mjs` | add later | cascade + fork handoff + curve-existence assertions |

---

## 5. Phase flow

> Each phase is independently verifiable and committable. A is orthogonal to B/C/D.

- **Phase A — curves into canvas + bounded z** (pure frontend, fastest payoff)
  1. `raiseWindow` + rebase; delete unbounded `nextZIndex` growth
  2. in-canvas `connection-layer` SVG; canvas-coordinate drawing; scroll port; discrete redraw
  3. delete chain.js body-SVG mechanism; verify: pan/zoom/scroll follow, overlay never occluded, drag-window follows live
- **Phase B — session lineage (identity layer)**
  1. `session.meta.json` codec + scan registry rebuild
  2. node bindings → conversationId; frame routing through the registry; head instance resolution
  3. fork handoff (machine prototype: register → close old → send result → resume); delete P38 adoption patches
  4. restart-consistency verification (restart after fork → lineage rebuild → open head correctly)
- **Phase C — cascade state machine**
  1. `Plan/Cascade` state machine (Event/Effect/step) + unit tests
  2. wiring (PlanCompleted/NodeSucceeded/InstanceReady/LevelFailed)
  3. delete scattered logic; confirm dialog/impactScope kept with wording adjusted
- **Phase D — close semantics**
  1. ownership-graph single traversal; delete mutual recursion
  2. Ctrl+W/✕/cascade-close regression (e2e 8b/8d/8e updated accordingly)

---

## 6. Verification and workflow

- Tests: `src-elm/elm-test` (existing 324+), `src-go go test ./...`,
  `src-tauri cargo test --lib`, `node --check src-elm/{chain,transport,overlay}.js`,
  `make e2e` (when a GUI is available).
- Per phase: all tests → commit → push origin/gitee/org (main).
- Commit message style: `refactor: ... (P39-A/B/C/D)`.
