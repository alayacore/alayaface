# TODO: Plan Mode Refactor (P39) — session lineage + cascade state machine + in-canvas curves

> Task list (gitignored local working file). Design/decisions live in `REFACTOR.md`.
> Interrupt recovery: read `REFACTOR.md` → read this file → continue from the first
> unchecked item.
> Fresh session: reading these two files is enough to resume development; consult
> the listed modules for code details as needed.

## Code audit fixes (2026-08-11, independent of the P39 phases, on top of a fully green baseline)

> Full regression: elm-test 348 / cargo test 69 / go test / e2e plan 23 + restart 7 all green.

1. **Backend symmetry drift (Rust fork_session missing spawn-args persistence)**:
   Go's `fork_session` writes `session.spawn.json` (replays the capability
   envelope on resume); Rust missed it — under Tauri, a forked node session
   loses its `--builtin-tools` restriction after restart (a "no tools" plan
   session could resurrect with all tools). Added `dirs::write_spawn_args`
   (mirroring create_session + Go) + unit test.
2. **Resumed node-session event routing bug (3 sites of the same kind)**: the
   runner node binds the "original session conversation id", while a resumed
   session's frames/disconnects/window-closes carry a **fresh live id**.
   `planEventFromFrame` (TaskDone/SessionError), the `StatusEvent` disconnect
   injection, and `CloseSession`'s runnerFailCmd originally only went through
   the registry (or did not resolve at all), so a fresh id found no node
   binding → the event was dropped → the node stayed Running forever (the run
   hung). Added `Plan.Update.resolveEventSessionId` (planResumedFrom →
   registry), unified across all three sites + unit test.
3. **Residual cascade state after a fork failure**: `PlanCascadeForkResult
   {ok:false}` originally only cleared `planCascadeFork`; `planCascade` stayed
   armed — the head level still pointed at the live source session, so a later
   TaskDone on that session would wrongly trigger `ResumeBranchFrom` (re-running
   downstream without truncation). The failure path now also clears
   `planCascade` + the open queue.
4. **`subPlansOfPlan` sentinel value**: `Maybe.withDefault ""` produced `""`
   entries that could false-match a plan with an empty origin; changed to
   filterMap (skip when no binding) + 3 unit tests.

---

## Progress overview

| Phase | Content | Status |
|------|------|------|
| A | Curves into canvas + bounded z (pure frontend) | [x] committed (`refactor: curves into canvas + bounded z (P39-A)`); **curves closed on real hardware**: `e2e/plan-e2e.mjs` headless Chrome all green (23 PASS, incl. curve anchoring/following/scrolling) — fixed rect-diff coordinates + one-shot rAF retry for ports ahead of the patch |
| B | Session lineage (identity layer) | [x] **B1–B5 all done**: B1 lineage codec + scan rebuild (`refactor: session lineage codec + registry rebuild (P39-B1)`); B2 bindings by conversationId + registry frame routing (`refactor: node bindings by conversation id (P39-B2)`); B3 fork handoff — lineage registration + head resolution + bindings keep conversation + nested lineage scan (`refactor: fork handoff ... (P39-B3)`); B4 drop P38 adoption fields (`refactor: drop P38 parentSessionId ... (P39-B4)`); **B5 restart consistency closed** — `e2e/fork-e2e.mjs` (fakecore fork history replay): full cascade fork chain + lineage rebuild after refresh + resume-head replay binding, 8 assertions all pass |
| C | Cascade state machine | [x] **committed** (`refactor: cascade state machine ... (P39-C)`): `Plan/Cascade` upgraded to a pure state machine (Event/Effect/step + phase), gate inside the machine, zero ordering assumptions; scattered logic (advanceCascade/cascadeAfterStep/resetDelegatedNode/adoptCascadeFork etc.) deleted; confirm-dialog wording updated; 15 machine unit tests |
| D | Close-semantics simplification | [x] **committed** (`refactor: ownership-graph close ... (P39-D)`): ownership-graph single traversal (collectCloseSetFromSession/Plan + closeSet short-circuit), eliminating the `PlanClose ⇄ CloseSession` mutual recursion; e2e close regression (8b/8d/8e) all pass |

---

## Current state snapshot (2025 starting point, commit `53d2ef7`)

**Exists and is kept**:
- `Plan/Runner.elm`: pure state machine (Event/Effect/step); P38 added `ResumeBranchFrom` (reset propagates downstream)
- `Plan/Cascade.elm`: pure helpers — `impactScope` (walks the ancestor chain along `meta.parentPlanId`),
  `needsConfirm`, `buildCascadeState`, `findInsertionIndex`/`truncateMessagesAt`/`forkHistoryId`,
  `feedbackSummary`, `insertPrefix`, `transitiveSuccessors`, `bindingInRun`
- `Plan/Meta.elm`: `origin` (sessionId+planIndex), `feedbacks`, `depth`, `name`,
  `lastStatus`, `parentPlanId` (**kept**), `parentSessionId`+`parentSessionOf` (**P39 deletes**)
- `fork_session` backend extension (Rust+Go symmetric, optional params:
  preset/builtinTools/toolConfirm/systemPrompt/workDir/planId/nodeId/originSessionId/clientId)
  — **kept**, lineage instance registration uses it
- `App/Update.elm`: `PlanCascadeConfirm/Cancel`, `scopeCtx`, `planFocusAboveSession`
  (Ctrl+W closes the topmost window), `cascadeForkResultDecoder`
- `Plan/Update.elm`: `feedbackCompletedPlan` (with gate/truncate/fork branches),
  `openNextOrStart`/`startCascadeNow` (ancestor reopen queue), `cascadeAfterStep`,
  `forkRequestFor`/`forkLevelFor`/`adoptCascadeFork` (**P39 deletes**)
- `chain.js`: currently body-level SVG + rAF loop (hardened) + z cap 900000 —
  **Phase A rewrites it wholesale as in-canvas SVG**
- `style.css`: `.overlay` z=1000000, `.media-preview-overlay` z=1000001 (kept)
- `transport.js`: `cascadeForkSession` (on success it fires `onSessionCreated`
  first, then `onCascadeForkResult`) — **P39 deletes this handler**

**Known problems (P39 must root-fix)**:
1. The top-level session is closed when a cascade fork is adopted; a missed
   `onSessionCreated` once made the fork window never appear (fixed, but the
   adoption mechanism itself must go)
2. Curves don't redraw after "clicking around" (rAF hardened, but the body-level
   approach is inherently fragile)
3. Curve/window z is unbounded and can cover overlays (patched via z cap +
   overlay z=1000000 — a patch, not a fix)
4. Close semantics piled up across P34/P35/P38; `PlanClose ⇄ CloseSession` mutual
   recursion once made Ctrl+W close an upper session

**Test baseline**: `elm-test` 324 green; `go test ./...` green; `cargo test --lib`
green; `node --check chain.js transport.js overlay.js` green. `make e2e` needs a
GUI; not run.

---

## Phase A — curves into canvas + bounded z (pure frontend, independent)

> Goal: eliminate the body-level SVG, `canvasZBase()`, per-frame rAF, and the z
> cap; curves stay correct under pan/zoom/scroll and never cover overlays.

- [x] **A1. Z manager**: `App/Windows.elm` gains `raiseWindow : Model -> String -> Model`
      (window list order + full rebase when `nextZIndex` exceeds 500); replaces every
      bare `nextZIndex + 1` growth point (`addPlanWindow`/`activateSessionModel`/
      `PlanActivate`/`SessionCreated`/`centeredSessionPos`…)
      — implemented: raiseWindow (list order + bounded z + rebase), the only bare
      growth point converges inside raiseWindow; raiseChainWindows also rebases internally
- [x] **A2. In-canvas curve layer**: `chain.js` rewritten
  - one `<svg class="connection-seg">` inside `.canvas`, canvas coordinates (window
    positions come from Elm's `chainPayload`; nodes = plan window + node's in-panel
    offset (measured via the offsetParent chain) − planScroll)
  - new plan canvas scroll port (`Ports.onPlanScroll` + `overlay.js` listens and
    reports back scrollTop/scrollLeft)
  - redraw triggers = discrete events (drag/zoom/scroll/chain change; on zoom Elm
    resends `setConnectionChain`), **no rAF**
  - stroke width = 3 / canvasScale (the payload carries canvasScale)
- [x] **A3. Delete the old mechanism**: chain.js's body SVG/`canvasZBase`/`CHAIN_Z_CAP`/
      rAF loop/visibilitychange all deleted; CSS `.node-connection-overlay`/
      `.plan-connection-overlay` → `.connection-seg` (in-canvas absolute); e2e
      selectors updated in sync
- [x] **A4. Verify**: `node --check chain.js/transport.js/overlay.js` green;
      `elm-test` 343 green; `go test ./...` / `cargo test --lib` green;
      **`e2e/plan-e2e.mjs` headless Chrome all green (23 PASS)** — pan/zoom/plan
      canvas scroll follow, drag-window follows live, overlay never occluded, button
      anchoring, curves restored after resume all closed; committed
      `refactor: curves into canvas + bounded z (P39-A)` + follow-up fix commits
      (curve fixes: coordinates via rect diffs (auto-includes scroll), planScroll
      port removed (chain.js listens for scroll itself and redraws), one-shot rAF
      retry when the port runs ahead of the vdom patch; e2e assertions switched to
      canvas coordinates + adapted to the P38 confirm dialog)

## Curve real-hardware closure (added after user feedback)

Environment: headless Chrome (`/usr/bin/google-chrome`) + Go backend + fakecore;
`e2e/plan-e2e.mjs` runs directly (no GUI needed).
Diagnostics tool: `e2e/chain-diag.mjs` (reproduces and dumps curve/window/chain
state, incl. zoom verification). Bugs found and fixed:

1. **Wrong coordinates ("not connected to the right window")**: originally
   measured in-window points via the offsetParent chain without compensating the
   `.messages`/plan DAG scroll → after scrollIntoView the curve pointed at the
   un-scrolled position. Changed to `getBoundingClientRect` diffs (element rect −
   window rect + Elm window canvas coordinates), which include all inner scrolls.
2. **Not shown (race)**: Elm's `setConnectionChain` port can run before the vdom
   patch (the new window's panel is not rendered yet) → segment geometry failures
   were hidden. Added a **one-shot** rAF retry (idempotent, non-looping).
3. **Broken after zoom (unit mismatch)**: rect diffs are screen pixels (scaled by
   the transform); adding them straight to canvas coordinates (layout pixels) →
   the more zoom, the more drift; and payload.canvasScale may describe a transform
   not yet patched. Fix: divide the diff by the transform scale **measured at the
   same instant** (`getComputedStyle(.canvas)`, self-consistent with the rect),
   and use offsetWidth/offsetHeight (layout units) for the center offset.
4. **Dead code deleted**: planScroll port/field/listener (chain.js now listens to
   DAG scroll itself and redraws; rect diffs already include scroll).
5. **e2e assertion fixes**: old assertions used screen coordinates (body-SVG era),
   changed to canvas coordinates (svg left/top + path points); 8b/8c/8d re-Run
   must click the P38 impact-scope confirm dialog (existing behavior; Phase C
   swaps in the machine); 7b2 adds a zoom-adherence regression.

Current e2e: **ALL PASS (24 assertions)**, elm-test 343, node --check, go test,
cargo test --lib all green.

## Phase B — session lineage (identity layer)

> Goal: stable conversation id + physical instance chain; bindings never change;
> eliminate the P38 adoption patches.

- [ ] **B1. session.meta.json**: new codec (in `Plan/Meta.elm` or a new `Session/Meta.elm`)
      `{ conversation_id, parent_instance_id }`; the existing plan-meta scan extends
      to also read session.meta → rebuild the in-memory registry
      `instanceId → conversationId` (root maps to itself)
- [x] **B2. bindings by conversationId (partially done; B3/B4 pending)**:
  - [x] `NodeRunState.sessionId` → `conversationId` (persisted run.json writes
        `conversation_id`; decoding is compatible with the old `session_id`)
  - [x] frame routing: physical instance id → registry (`SM.resolveConversation`) →
        conversationId → `nodeBySessionId` (Runner tweaked); `findPlanIdBySession`
        goes through planResumedFrom **then** the registry; `planEventFromFrame`
        (TaskDone/SessionError) and the SessionDisconnected injection resolve the same way
  - [x] `PlanBindSession` resolves the conversationId and uses it as the
        planNodeSessions label key; `PlanOpenNodeSession` reads the conversation
        binding (root session conversationId == directory id; resume unchanged)
  - [ ] `meta.origin.sessionId` = conversationId, the **persistence side**: write the
        conversation id at creation (under a root the values are equal, semantics
        already hold; `parentSessionId`/`parentSessionOf` deletion comes with B4)
  - [ ] open node session = conversation → instance chain head (latest live) →
        activate/resume (head resolution depends on B3's fork handoff chain structure)
- [ ] **B3. fork handoff (machine prototype)**: confirmed re-run → complete → gate →
      `ForkInstance` (fork the current head instance, historyId = the one before the
      insertion point) → `InstanceReady(newId)`: write session.meta + registry →
      close the old head instance's window (disconnect resolves without false node
      failure) → send `[Plan Result]` to the new instance → `ResumeNode`
      — **not started**; coupled with B4 (delete P38 adoption) and the Phase C
      state machine, suggested to advance together
- [ ] **B4. delete P38 adoption**: `adoptCascadeFork`/`forkRequestFor`/`forkLevelFor`/
      `rewriteParentSession`/the `planCascadeFork` field/`PlanCascadeForkResult`/
      transport `cascadeForkSession`/fork replay marker patches/deferred D11/
      adoption closes the original session/confirm closes child plans — **not started**
- [ ] **B5. tests + restart verification**: lineage codec/rebuild/resolution unit
      tests; after restart, opening the head instance is correct; `elm-test`/`go test`/
      `cargo test --lib` all green; commit `refactor: session lineage (P39-B)`

## Phase C — cascade state machine

> Goal: `Plan/Cascade.elm` upgraded to a pure state machine (modeled on Runner),
> zero ordering assumptions, unit-testable.

- [ ] **C1. state machine**: `CascadeState` (rootPlanId/rootOldSummary/levels/phase) +
      `Event` (ReRunConfirmed/PlanCompleted/NodeSucceeded/LevelFailed/InstanceReady) +
      `Effect` (ForkInstance/InsertResult/ResumeNode/BranchRerun/OpenAncestor/PersistMeta) +
      `cascadeStep`; gate (summary unchanged → end silently) inside the machine
- [ ] **C2. wiring**: App/Update + Plan/Update only dispatch events and execute
      effects; delete scattered logic `cascadeAfterStep`/`advanceCascade`/
      `resetDelegatedNode`/`forkLevelFor` etc.
- [ ] **C3. confirm dialog**: `impactScope`/`needsConfirm`/`buildCascadeState` kept;
      wording changed to "re-run will truncate the parent session's old results and
      everything after them (including your N messages)"
- [ ] **C4. tests**: state-machine unit tests covering — each phase transition/
      InstanceReady success+failure/LevelFailed abort/gate hit/multi-level
      propagation order; `elm-test` all green; commit `refactor: cascade state machine (P39-C)`

## Phase D — close-semantics simplification

> Goal: ownership-graph single traversal, eliminating the `PlanClose ⇄ CloseSession`
> mutual recursion.

- [ ] **D1. ownership graph**: after lineage resolution, conversation → plans →
      node sessions → child plans; `CloseConversation`/`ClosePlan` each do a single
      traversal (no mutual dispatch)
- [ ] **D2. regression**: P34/P35 scenarios (closing a session cascades to plans,
      closing a plan cascades to node sessions, closing a node session fails the
      node and retries) + Ctrl+W closes the topmost window
      (`planFocusAboveSession` kept, verified)
- [ ] **D3. e2e**: `plan-e2e.mjs` updated/added — cascade + fork handoff + curve
      existence + close regression (8b/8d/8e mapped); `make e2e` all green when a
      GUI is available; commit `refactor: close semantics (P39-D)`

---

## Workflow reminders

- Per phase: full tests → commit (`refactor: ... (P39-X)`) → push origin/gitee/org (main).
- Design changes first go into `REFACTOR.md` (decision table) before acting.
- Backend-touching changes must be Rust/Go symmetric + each with its own tests.
