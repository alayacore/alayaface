# Plan Mode Refactor (R series): model-autonomous sub-flows + recursion

> **Master refactor document.** Interruption recovery:
> 1. Read this file (design + phase flow) → read `TODO.md` (R-series task
>    checklist) → continue from the first unchecked checkbox;
> 2. Each phase done → run the full test suite (`src-elm/elm-test` /
>    `src-tauri/cargo test` / `src-go go test -race ./...` / `make e2e`) →
>    commit → push **three remotes** (origin / gitee / org, branch main,
>    verify consistency with `git ls-remote`);
> 3. Constraints unchanged: **NEVER modify AlayaCore**; dual-backend parity
>    (this refactor is almost purely frontend Elm — zero new Rust/Go
>    commands); pure Elm logic lives in `Plan/*`; all new params
>    optional/backward-compatible.

## 0. Goal

Upgrade Plan Mode from a "user-triggered standalone tool" to a
"**model-autonomous sub-flow / async tool**":

- detect plan JSON → **auto-create** the Plan window (no button), wait for
  the user to click Run;
- any session (plain / node) whose model outputs a plan → **recursion**
  (a node delegates to a sub-plan);
- plan completes → **feed the results back** to the originating session →
  **auto-continue**;
- node/plan windows close by rules; plans persist; messages are clickable
  for review.

## 1. Confirmed decisions (user approved each; do not change)

| # | Decision |
|---|---|
| D1 | Detecting ```` ```json + type: alayaface-plan ```` → **auto-create** the Plan window (no button), **wait for the user to click Run** |
| D2 | Prompt **without a role lock** (P22's "planner is not the executor / tools disabled" is void); **fixed plan mode** (global switch ignored): every session create injects the advisory plan prompt |
| D3 | When a node's model reply completes (SM task done), check the **last assistant message**: contains plan JSON → the node does NOT complete, it enters "waiting for sub-plan"; otherwise → Succeeded |
| D4 | **Judgment reliability**: success always goes through feedback → after feedback the last message is no longer plan JSON. So "last message is plan JSON" ⇔ still waiting |
| D5 | Node waiting for a sub-plan: **window stays open** (shows waiting); **parent run stays InProgress**; user manually closes the window → auto-resume on feedback |
| D6 | Plan/sub-plan **Completed → feedback** to the originating session: node-result summary + `[Plan: <planId>]` marker as the new prompt → **auto-continue** (no user action) |
| D7 | Feedback target session closed → **auto-resume** (popup) + continue |
| D8 | **Failed / Stopped → zero feedback** (the user sees the failed status bar + [re-run]) |
| D9 | **Re-run = skip succeeded nodes** (not the full-reset StartRun); only unfinished nodes are handled: plain Failed/Canceled/Blocked → re-run the node (new session); **waiting-for-sub-plan → re-run its sub-plan** (planId unchanged, node not re-run, no origin rebind); cascading recursion (unbounded descent) |
| D10 | **Window close rules**: only the plan-opened **node sessions** close on **Succeeded** (binding kept, clickable for review); plain sessions never auto-close; a node session waiting for a sub-plan stays open |
| D11 | **Plan window**: when all nodes finish (Completed) → feedback first, then auto-close; Failed/Stopped keep the window (review/retry); reopening from the Plans manager / status bar / `[Plan: xxx]` link |
| D12 | **Status bar** (replaces the Create Plan button): plan binding component under the message (name + status + [open] + [re-run]); persisted + restored after restart |
| D13 | **Timeout mechanism removed entirely** (P16's timeout): schema fields, validate, runner Tick, app heartbeat all deleted; redesigned later once recursion stabilizes. `startedAt` kept (record only), work-dir isolation kept |
| D14 | **Recursion unbounded** (trial period); auto-create without confirmation (trial period); multi-plan feedback executed sequentially (trial period) |
| D15 | **Plan Session entry deleted** (P6/P22's menu, planSessionPending/planSessionIds, [Plan] title, builtinTools="") |

## 2. Runtime metadata storage (new decision)

- `plans/<planId>.json`: **pure plan document** (type/schema/tasks, user
  exportable/editable, no runtime noise);
- `plans/<planId>.run.json`: run state (node status incl. `WaitingForPlan`,
  output, startedAt, session bindings);
- **`plans/<planId>.meta.json` (new)**: runtime metadata
  ```json
  {
    "origin": { "sessionId": "...", "messageId": "hist-..." },
    "feedbacks": [ { "at": 172..., "status": "completed|failed|stopped", "text": "...", "planId": "..." } ],
    "created_at": 172...
  }
  ```
- node ↔ sub-plan linkage: reverse lookup through the **sub-plan's
  meta.json origin** (origin.sessionId = parent node session id);
- restart restore: scanning the plans dir builds a `messageId → planId`
  index when a session opens (reuses fs_list_dir); **replayed history
  messages skip plan detection** (prevents duplicate auto-create).

## 3. Core mechanisms

### 3.1 Node lifecycle (recursion foundation)

```
Running → model reply completes (SM task done)
   └─ last assistant message contains plan JSON?
        ├─ no → Succeeded → close the node window (binding kept, click resumes)
        └─ yes → WaitingForPlan (new status)
                · the sub-plan was auto-created at detection (origin = this node session)
                · window stays open ("waiting for sub-plan <id>")
                · parent run stays InProgress
                · timeout: removed (D13)
  sub-plan Completed → feedback to this node session → auto-continue (send prompt)
        → model replies again → re-judge the last message (may delegate again / finish)
  sub-plan Failed/Stopped → zero feedback → node stays WaitingForPlan
        → user [re-run] on the sub-plan's status bar → sub-plan completes → feedback → node continues
```

### 3.2 Feedback (auto-continue)

- trigger: plan status → **Completed** (incl. sub-plans);
- content: all Succeeded nodes' output summary (P24 already) + `[Plan:
  <planId>]` marker;
- role: user message (alayacore only replies to user streams), prefixed
  **`[Plan result]`**, rendered in system style (distinct from real user
  messages);
- send: Ports.sendPrompt (existing); target session closed →
  resume_session then send;
- result written to feedbacks (meta.json) → restored after restart;
- reply contains plan JSON again → delegate again (recursion, D14).

### 3.3 Re-run (re-execute / cascade)

```
[re-run] (status bar or Plan window):
  ① Succeeded nodes (incl. sub-plans already fed back) → skipped, untouched
  ② unfinished nodes:
     - plain Failed/Canceled/Blocked → re-run the node (new session, clean)
       (Blocked resets to Pending, auto-schedules once deps succeed)
     - WaitingForPlan → do NOT re-run the node! re-run its sub-plan
       (planId unchanged) → sub-plan completes → feedback to the node →
       node continues → completes
  ③ cascading recursion: the sub-plan's unfinished nodes follow ②
     (unbounded descent)
```

### 3.4 Status bar (plan binding under the message)

```
[Plan: e2e-demo-1234]  name  ● Running  [open]
  Created  → [open]
  Running  → ● + [open]
  Completed→ ✅ + [open] (feedback already auto-continued)
  Failed   → ⛔ failure reason + [open] [re-run]
```

- binding: meta.json origin (messageId ↔ planId);
- status: read from run.json; after restart the index is rebuilt by
  scanning the plans dir;
- `[Plan: xxx]` inside feedback messages renders as a link (second entry,
  click → openPlanFile).

## 4. Edge cases (reviewed)

1. **Replay dedup**: replayed history does not trigger auto-create (the
   replay path skips detection; already-bound messages only restore the
   status bar);
2. **user sends a message while waiting** → the node is treated as normally
   completed (gives up waiting);
3. **window manually closed while waiting** → auto-resume on feedback (D7);
4. **multi-level recursion unbounded** (D14); a parent run can stay
   InProgress forever because a sub-plan failed → user Stops the parent run
   (WaitingForPlan node → Canceled);
5. **concurrent feedback**: multiple plans completing to the same session →
   one prompt each, executed sequentially;
6. **P24 output injection independent**: sub-plan nodes can still use
   `{{tX.output}}`;
7. **parse failure** (marker detected but invalid JSON) → error inlined
   under the original message, no window created;
8. **old plan files** (with timeout fields): decode ignores unknown fields,
   opens normally (D13 compat).

## 5. Removed / kept / added

**Removed**: Plan Session menu + planSessionPending/planSessionIds +
`[Plan]` title + builtinTools="" (P22 role lock); the Create Plan button UI;
the full-reset StartRun semantics; P16 timeouts (schema fields / validate /
runner Tick / app heartbeat / fakecore fixture timeout); P23's "keep
succeeded node windows" semantics (reversed).

**Kept**: P26 type marker; P9/P13 history sessions
(lastSessionId/attemptSessions); P19 connection curves; P25 cancel-first;
P16 work-dir isolation (startedAt kept); P24 output injection; the Plans
manager; Load run; Export; pendingPlanOffers (reworked into the auto-create
buffer); planCreateQueue (serialized session creation).

**Added**: `WaitingForPlan` node status; `meta.json`
(origin/feedbacks); the status-bar component; feedback auto-continue;
re-run cascade; replay dedup; feedback messages in system style + `[Plan:
xxx]` links; plan auto-close on completion (feedback first).

## 6. Refactor phases (each: implement → full tests → commit → push 3 remotes)

### R1 foundation: schema + pure logic
- [x] `Plan/Types.elm`: removed `defaultTimeoutSeconds`/`timeoutSeconds`
      fields + validate checks (decode ignores unknown fields → old files
      compatible); `NodeStatus` gains `WaitingForPlan`
      (nodeStatusToString/FromString "waiting_for_plan"); codec compatible
- [x] `Plan/Runner.elm`: removed `Tick`/`checkTimeouts`/`timeoutNode`;
      TaskDone delegation (event carries `delegated : Bool` — the Update
      layer decides from the last message); WaitingForPlan transitions
      (TaskDone+delegated → WaitingForPlan; feedback-continue event
      `ResumeDelegatedNode` → Running; Stop while waiting → Canceled; manual
      TaskDone (non-delegated) while waiting → Succeeded; TaskDone error
      while waiting → ignored, stays waiting)
- [x] tests: removed 5 timeout cases + 3 schema cases; added 7
      WaitingForPlan transitions + 1 codec roundtrip; Elm 180 green; Rust 42
      / Go -race 8 pkgs unaffected

### R2 detection + auto-create
- [x] `App/Update.elm`: pendingPlanOffers reworked into **auto-create**
      (detection → PlanSaveReady flow, no button: FrameEvent detect →
      autoOfferCmd → PlanCreateOffer consumed); parse-failure errors inlined
      into the original session message (injectPlanErrorIntoSession)
- [x] `planSystemPrompt` rewritten (no role lock, advisory: "complex tasks
      → output a plan JSON first, then stop and wait") + injected into ALL
      session creates (plain UserCreate + node sessions nodeSessionArgsIn =
      recursion entry)
- [x] deleted Plan Session: menu entry, `CreatePlanSession` Msg,
      `planSessionPending`, `planSessionIds`, `[Plan]` title, Plan Session's
      builtinTools="", the Create Plan button
- [x] fakecore: planMode trigger changed to prompt containing "plan"
      (otherwise node sessions would also reply with plans); E2E: New
      Session flow + auto-create assertion + t3 hang marker pre-seeded (the
      first run must not hang after R1 removed timeouts) + deleted t3
      timeout-retry assertion; E2E ALL PASS
- [x] **replay-suppression** (prevent duplicate auto-create) — depends on
      meta.json binding (done in R3)

### R3 feedback + status bar + persistence
- [x] **replay-suppression** (R2 leftover): `messageBoundToPlan` (detection
      checks meta origin binding; already-bound only restores the status
      bar, no duplicate create)
- [x] `meta.json` codec (`Plan/Meta.elm`: origin/feedbacks/created_at) +
      auto-create writes origin (PlanSaveReady); lenient decode
- [x] status-bar component (View + CSS + `PlanStatusOpen`): plan binding
      under the message (planId + name + status color + [open]);
      planMetaForMessage looks up the binding
- [x] feedback: `feedbackCompletedPlan` (run just became Completed →
      node-output summary + `[Plan: xxx]` prefixed `[Plan result]` → send to
      the origin session to auto-continue; origin is a node session →
      `ResumeDelegatedNode`; Failed/Stopped zero feedback; writes feedbacks
      to meta.json)
- [x] `[Plan: xxx]` link rendering (viewTextWithPlanLinks: scans message
      text → button → PlanStatusOpen)
- [x] restart restore: after fsHomeDir, scan the plans dir *.meta.json →
      queue reads → planMetas index; **fs_list_dir returns an empty list for
      a missing dir** (Rust+Go symmetric — the plans dir may not exist on
      first run); fakecore msgSeq: UT echo history ids increment per message
      (the feedback's second user message must not be dropped by the
      frontend's processedEchoIds)
- [x] tests: PlanMetaTest +3 (roundtrip/lenient/path); E2E new assertions
      (feedback `[Plan result]` + link + status bar Completed); Elm 183 /
      Rust 42 / Go -race / E2E ALL PASS

### R4 close rules + re-run cascade
- [x] `closeAndClear`: Succeeded also closes the node window (lastSessionId
      binding kept, click resumes for review); WaitingForPlan not closed
      (waits for the sub-plan)
- [x] Plan Completed → feedback first → plan window auto-closes
      (Task.perform PlanClose); Failed/Stopped kept; `planRunStatuses`
      (memory cache — the status bar shows the real status after the window
      closes)
- [x] re-run (`RestartRun` event + `PlanRunRestart` Msg +
      `restartPlanCascade`): skips Succeeded; unfinished nodes reset
      (Blocked → Pending so it re-schedules); WaitingForPlan nodes NOT reset
      → `subPlansOfPlan` (meta origin reverse lookup) cascades to sub-plans
      (planId unchanged, unbounded descent); status bar [re-run] (shown for
      Failed/Stopped/Paused)
- [x] **fixed a latent bug along the way**: run.json-restored nodes had
      `nodeId=""` (encode never wrote node_id) → allDepsSucceeded broke →
      restored runs could not schedule (Load run affected too) — decode now
      fills nodeId from the dict key
- [x] fakecore: the `[Plan result]` prefix always replies normally
      (feedback containing node-output keywords must not trip the marker
      scenario)
- [x] E2E rewrite: run completion judged via the status bar (plan window
      auto-closes); run.json asserts retry evidence; node click → resume
      (succeeded windows already closed); 8b Stop kept (t3 hangs → Stop →
      window closed); ALL PASS; Elm 183 / Rust 42 / Go -race green

### R5 cleanup + docs + real-core bug fix
- [x] E2E full rewrite (done in R4, commit 4bc7456): fixture (t3 keeps
      hang-once for Stop; E2E **pre-seeds the t3 hang marker** so the first
      run succeeds instantly); recursion, status bar, re-run cascade steps
- [x] **Real-core bug fix (this session, commit b0a58b8)**: alayacore's
      **boot task frame** (`SM task in_progress:false`, emitted at session
      start, before any prompt) was mistaken by `planEventFromFrame` for a
      TaskDone → the Runner marked the just-bound node Succeeded (empty
      output) → `closeAndClear` immediately issued `CloseSessionFor` →
      cancel-first close → node "Canceled right after the first prompt",
      run "completed" in milliseconds. Fix:
      1) Model gained `planTaskStarted : Set String` — TaskDone is only
      dispatched for sessions that have seen `in_progress:true` (a real task
      start, always after the prompt); the boot frame is ignored;
      2) fakecore mirrors the real alayacore frame sequence (boot carries
      `in_progress:false` + emits `in_progress:true` before replying), so E2E
      actually covers the gate (previously fakecore's boot lacked
      `in_progress` → frontend defaulted to true → never triggered).
      Real-core verification (LLaMA.CPP gemma-4-12B): before — t1/t3 finished
      in 12ms/7ms + AT "Canceled"; after — all three nodes produce real
      output, strict chain order, no Canceled.
- [x] dead-code cleanup (P22 leftovers, offer-button CSS); `Time.every`
      subscription removed — commit `20d10a5`
- [x] docs: docs/plan-mode.md (§5/§6.7/§7/§8.5 timeout removal/§13),
      README, docs/manual-acceptance.md; TODO.md checkboxes — commit
      `b7c9b6a` + this pass
- [x] full verification: Elm / Rust / Go -race / make e2e green → committed
      → pushed to three remotes

## 7. Verification commands

```bash
cd src-elm && elm-test && elm make src/Main.elm --output=/tmp/r.js
cd src-tauri && cargo test
cd src-go && go vet ./... && go test -race ./...
cd /home/wallace/playground/alayaface && make e2e
git push origin HEAD:main && git push gitee HEAD:main && git push org HEAD:main
```

## 8. Trial-period acceptances (user-confirmed)

- recursion unbounded (chained model plans may not converge — observe);
- auto-create without confirmation (the model outputting a plan creates the
  window even if the user doesn't want it);
- a parent run may stay InProgress long-term because a sub-plan failed
  (user Stop / re-run the sub-plan);
- after timeout removal a hung node stays Running forever (only Stop /
  cancel-first close works).
