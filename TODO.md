# TODO: Plan Mode (AlayaFace)

Tracking file for the **Plan Mode** feature (task planning → DAG → execution/retry).
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
| P8 Node↔session binding: click node opens/resumes its session | [x] |
| P9 Keep failed/canceled sessions reopenable (lastSessionId) | [x] |
| P10 Review pass: runner race fixes + orphan cleanup | [x] |
| P11 Review pass 2: create-queue serialization + create-failure recovery | [x] |
| P12 Graceful close (save+EOF+grace) + dead-code cleanup + acceptance doc | [x] |
| P13 Attempt-session history (attempt_session_ids + detail-panel list) | [x] |
| P14 Concurrency selector in the plan header | [x] |
| P15 Automated headless-browser E2E + 4 real bugs found & fixed | [x] |
| P16 Per-plan work dir isolation + task timeouts | [x] |
| P17 Plans manager Browse tab (file-browser import) | [x] |
| P18 Node-session resume: keep the on-disk dir id as the binding | [x] |
| P19 Node ↔ session connection curve (focus → plan second layer + bezier) | [x] |
| P20 runtime.conf seeding fix (alayacore key:value format, not JSON) | [x] |
| P21 Config files: empty shells only (alayacore auto-creates) | [x] |
| P22 Plan Session role-lock + no builtin tools + **real-model validation (user ran a full plan)** | [x] |
| P23 Plan Stop closes the run's node session windows too | [x] |
| P24 Output injection `{{tX.output}}` (TaskDone records output → run.json persistence → downstream prompt replacement → detail panel) | [x] |
| P25 close_session cancel-first (Stop/window close immediately cancels the task; history saved up to the cancel point) | [x] |
| P26 plan JSON top-level `"type": "alayaface-plan"` marker (the button only recognizes the explicit marker; **required, no compat** — missing/wrong value errors out) | [x] |
| P27 Connection-curve upgrade + session-dir hierarchy: plan↔owning-session curve (anchored to the visible `[Plan: …]` button); both curves solid + thicker with a 2-control-point bezier; `sessions/<planId>/<nodeId>/<uuid>/` nesting (top level = plain sessions only) | [x] |
| P28 Plans live INSIDE the owning session (user decision: import was an early-design leftover — removed): plan document/meta/run/work/node sessions all under `sessions/<origin>/plans/<planId>/`, top-level `plans/` root deleted; Plans manager single view (indexed from planMetas, no Browse/import); meta origin records the on-disk session id, bindings resolve live ids | [x] |
| P29 Remove ALL backward-compat code (user: it is all useless): session-dir legacy fallback chain (only P28 paths), Plan/Meta lenient decode (origin/planIndex required, messageId removed, origin non-Maybe), Legacy config-seed heal (whole block removed), always-true `has_session_file` field | [x] |
| P30 Remove the Plans entry from the system menu (user: the system menu doesn't need plans): Plans manager deleted entirely (overlay/msgs/state/fsDeleteFile port/PlanFileInfo); plans reopen only via the session's `[Plan: …]` status bar; menu keeps the open-plan-window switcher | [x] |
| P31 Fix plan run state lost after restart (user report): planMetas rebuild still scanned the old P27 layout `plans/*.meta.json`, while P28 stores meta at `plans/<planId>/<planId>.meta.json` → scan found zero metas → planMetas empty after restart; build meta paths directly from the plans/ subdir listing + filter `..`; serialize the scan with the file-picker's home listing (untagged fs_list_dir race) | [x] |
| P32 User-driven UI/CI round: S-shaped bezier (two control points on opposite sides); ~~ancestor-chain curves~~ **removed per user clarification** (the DAG already draws node↔node edges — no extra lines; an active plan window connects only to its owning session's `[Plan: …]`); overlay scrollbar (native scrollbar hidden → message column stays exactly as wide as the prompt input); uniform Session Manager list buttons; no auto-created session at startup (welcome screen, user opens on demand); GitHub CI extended — Tauri `cargo build` + full E2E job (Go backend + fakecore + headless Chrome); restart-e2e port-race fix | [x] |
| P33 Fix "Session is already active" after page refresh (user report): refresh orphans the backend's session handles → resume keeps failing until the Go process restarts; new `close_all_sessions` RPC (Go+Rust, graceful cancel-first close, history preserved) fired once on page load; restart-e2e gained a page-refresh phase | [x] |
| P34 Cascade close (user request): closing a session window also closes everything it owns, recursively — its plans (meta origin) are stopped (StopRun → no respawn), their node sessions closed, plan windows closed; sub-plans of node sessions cascade the same way; `DeleteSession` cascades too; pure lookup `Plan.Meta.plansOwnedBySession`; plan-e2e gained a cascade step | [x] |
| P35 Plan-window close cascades down (user report, twice): closing a plan window (✕) closes **every live node session window bound to its nodes under ANY run status** — active runs (InProgress/Paused) are stopped first (no respawn); terminal runs are not re-stopped (status bar keeps Completed/FailedRun/Stopped) but their open node-session windows (e.g. resumed from disk under a Stopped plan) are closed directly via `nodeSessionIdsForPlan`; sub-plans cascade through CloseSession; plan-e2e gained 8e + 8d | [x] |
| P36 Connection CHAIN (user request — supersedes P32's "no ancestor-chain curves"): focusing a deep node session (or activating a plan window) draws the **whole ancestor path** — the focused session's node↔session bezier PLUS every ancestor plan↔owning-session bezier up to the **top-level session window** ("through the lines you can directly find the topmost session"); `App/NodeConnection.elm` builds the chain purely (`chainForSession`/`chainForPlan`, cycle-safe); all chain windows raised top→bottom (`raiseChainWindows`); bridge.js draws one bezier per segment (per-segment SVG overlay, own z); the plan↔session segment now stays visible while a node session is focused (plan-e2e 7b updated) | [x] |
| R series | Plan refactor: model-autonomous sub-flows + recursion (auto-create / feedback auto-continue / re-run cascade / status bar / timeout removal) — **see REFACTOR.md** (R1–R5 all complete, see checklist below) | [x] |

## P24 — Output injection ({{tX.output}})

A real-model run exposed: downstream tasks (e.g. t4) need the outputs of
upstream t1/t2/t3, but v1 prompts are self-contained → the model re-searches
or makes things up. The real-model run also confirmed task outputs land in
the per-plan work dir (the model writes files into `work/`), but file naming
has no fixed convention → injection uses the **final answer text** rather than
guessing file names.

- [x] `Plan/Inject.elm` (new pure module): `injectOutputs : Dict String String
      -> String -> String` replaces `{{<taskId>.output}}` (exact match, no
      spaces; unknown id / no output → Chinese placeholder text, the raw
      template never leaks to the model; `{{` without `.output}}` is kept);
- [x] `NodeRunState.output : Maybe String`: recorded on TaskDone success (the
      last non-empty assistant text of the session; Update layer
      `lastAssistantOutput` extracts from `model.sessions`; frame order: AT
      before SM task-done); failures/retries don't record; StartRun clears;
- [x] runner: `TaskDone sid isError (Maybe String)` three-arg event;
      `bindSession` generates `SendPrompt` with injection via `outputsOf run`
      (nodes only schedule after all deps Succeeded, so injection timing holds);
- [x] run.json codec: `output` field encode + lenient decode (missing →
      Nothing, old files compatible) → resume/silent-restore still injects;
- [x] UI: node detail panel gains an Output area (placeholder when none);
- [x] planner teaching: `planSystemPrompt` rule — "downstream needs upstream
      output → reference it with {{t1.output}} (only for declared deps)";
- [x] tests: `PlanInjectTest` (10 cases) + runner 6 cases (success records /
      failure doesn't / downstream injects / missing placeholder / unknown id
      placeholder / re-Run clears) + codec roundtrip + lenient → **Elm 172**;
- [x] E2E: fixture t2 prompt references `{{t1.output}}`; fakecore `streamReply`
      echoes the received prompt (`Received prompt: ...`, becomes the node's
      final answer) → e2e asserts t2's session contains t1's output text
      (`research the topic and summarize findings`) + injection label + no raw
      template; `make e2e` ALL PASS (incl. new step 7c: injection assertion +
      curve hidden after closing t2);
- [x] docs: plan-mode.md §5 table, new §8.6, §10 persistence, §13 decisions,
      §12 progress.

## P25 — close_session cancel-first (Stop really stops every node)

User report: **Stop cannot stop all nodes**. Investigation: P12's graceful
close semantics were EOF → alayacore `drainUntilTaskDone()` runs the current
task to completion then saves and exits — fine for manual window close, but
Stop means "stop now" and must not wait for the task (task ≤5s grace could
finish fully; the user saw nodes still executing after clicking Stop).

User decision: **no backward compat, always send cancel** (native alayacore
command, C1-safe: `cancelTask` → `activeTask.cancel()` → the task completes
through `taskResultCh` → `handleTaskDone` **auto-saves up to the cancel
point** → history is not lost much).

- [x] Go `closeGracefully`: **cancel → save → EOF → grace → SIGKILL**
      (cancel is fire-and-forget, SendCmd doesn't block for CO; errors
      ignored); `kill_child` keeps the EOF-grace path (no stdin handle,
      cannot send cancel);
- [x] Rust `close_child_gracefully_with_timeout` symmetric: inside the same
      stdin mutex lock — cancel frame, then save frame, then EOF;
- [x] fakecore hang mode: hang-once no longer `sleep(30s)` blocking the main
      loop — during the hang it keeps reading stdin, swallows UE, answers CI
      `cancel` (task-done frame + CO, exits hang) — mimics real alayacore
      "task stuck but command loop alive" (alayacore cancel goes through
      cancelReqCh, not the input pipe);
- [x] tests: Rust updated (asserts cancel frame arrives at child stdin before
      save); Go new `TestIntegrationCloseCancelsHungTask` (hung task exits
      <3s after close — cancel interrupts the hang, not 30s+grace); Go -race
      green;
- [x] E2E: fakecore hang mode + Stop step (t3 hangs → Stop → window closes,
      badge Stopped) ALL PASS;
- [x] docs: plan-mode.md §8.3 (rewritten cancel-first)/§10/§13, README,
      manual-acceptance §5.

## P26 — plan JSON top-level type marker (alayaface-plan)

User proposal: ordinary messages containing ```json code blocks also trigger
the Create Plan button (false positive); a top-level marker is safer.
**Later correction (user instruction): no backward compat — a wrong format is
an error** — the `type` marker is required; missing is also rejected (no more
lenient compat with old files).

- [x] `Plan.Types.planTypeMarker = "alayaface-plan"` + `Plan.planType : Maybe String`:
      lenient decode (missing → Nothing); **validate requires it**: missing →
      `Missing top-level "type": "alayaface-plan" marker`, wrong value →
      `Not an AlayaFace plan: ...`; `encodePlan` always writes
      `"type": "alayaface-plan"` (save/export/re-generate all carry it);
- [x] `Plan.Detect.hasPlanTypeMarker`: decodes the block's top-level `type`;
      Update-layer AT detection requires marker == True after
      `extractPlanJson` before inserting `pendingPlanOffers` — plain ```json
      examples no longer show the button;
- [x] Plan Session `planSystemPrompt`: JSON example gains
      `"type": "alayaface-plan"` + rule "the top level must contain this
      marker, otherwise the framework does not recognize it";
- [x] tests: PlanTypesTest +3 (encode carries the marker / **missing marker
      rejected** / wrong value rejected); all existing test JSON gained the
      marker; PlanDetectTest +5 (exact marker true / no marker false / wrong
      value false / invalid JSON false / non-object false) → **Elm 180**;
- [x] E2E: fakecore fixture carries the marker → Create Plan offer appears
      normally; imported plan (Browse) carries the marker → opens; **new**
      legacy-no-marker.json (no marker) → the manager shows
      `Missing top-level "type"...` and no window opens; ALL PASS;
- [x] docs: plan-mode.md §5 schema/field table (type required), §6.7, §12, §13.

---

## P27 — Connection-curve upgrade + session-dir hierarchy

User's three requests:
1. **Plan window ↔ owning session curve**: when the plan window is active,
   draw a line to the session that created it (meta.json origin); the
   session's visible `[Plan: <planId>]` button is the anchor (falls back to
   the window edge when the button is invisible/scrolled out).
2. **Solid thicker + 2-control-point bezier**: both session↔node and
   plan↔session curves are solid (no dasharray), thicker (stroke-width 3),
   cubic bezier with 2 independent control points, stronger bow + tangent
   alignment → smoother.
3. **session-dir hierarchy**: plan node sessions nested at
   `sessions/<planId>/<nodeId>/<uuid>/`, so `sessions/` top level can only be
   plain (non-plan) sessions.

### 1+2 frontend (bridge.js + Elm)
- [x] `App/NodeConnection.elm`: new `PlanConnection {planId, sessionId}` +
      `liveSessionForOrigin` (origin-session live-id resolution: the original
      id or a resume's fresh id);
- [x] Model gains `planConnection : Maybe PlanConnection`;
      `planConnectionFor planId` resolves from planMetas.origin (Update.elm);
- [x] new port `setPlanConnection` + bridge.js `.plan-connection-overlay`
      (second SVG overlay); shared `curvePath(from,to)`: **2 independent
      control points** cubic + `bow = clamp(20,80, dist*0.18)`; z-index = the
      larger of the two windows' z (above both);
- [x] show timing: plan activation (addPlanWindow/PlanActivate/PlanStatusOpen)
      sets it + port; session focus (activateSessionModel/ActivateSession
      idempotent branch/SessionCreated resume branch) clears it;
      PlanClose/CloseSession/DeleteSession clear by planId/sessionId;
- [x] CSS: `.node-connection-curve`/`.plan-connection-curve` solid + width 3;
- [x] bridge.js anchoring: session side prefers the `[Plan: <planId>]`
      button inside the session (visible + intersecting the session panel's
      content area) → anchor to its center; otherwise window edge;
- [x] tests: NodeConnectionTest +5 (liveSessionForOrigin); Elm 213 green.

### 3 backend session-dir hierarchy (Rust + Go symmetric)
- [x] `dirs.SanitizeDirComponent` / `sanitize_dir_component`: non
      `[A-Za-z0-9_-]` chars (incl. `.`) → `_`, empty → `p`; deterministic
      (create/resume same mapping, `.`→`_` means `..` cannot escape the
      sessions root);
- [x] `CreatePlanSessionDirFrom` / `create_session_dir_nested`:
      `sessions/<planId>/<nodeId>/<uuid>/` (shared
      `createSessionDirIn` copies config);
- [x] `create_session` / `resume_session` / `delete_session_dir` gain optional
      `planId`/`nodeId`: present → nested path, absent → top level (plain
      sessions unchanged);
- [x] `list_session_dirs`: lists only top-level dirs that DIRECTLY contain
      `session.alaya` → the manager never shows plan child sessions;
- [x] frontend: Ports/bridge.js pass planId/nodeId; `nodeSessionArgsIn` fills
      node sessions; plain create/manager resume pass Nothing;
- [x] tests: Go `TestSanitizeDirComponent` + `TestCreatePlanSessionDirFromNests`
      + `TestIntegrationNestedPlanSessionDir` (nested create/manager hidden/
      nested resume ok/flat resume fails/nested delete); Rust same 2 cases;
      all green;
- [x] E2E: 4b asserts plan↔session curve visible + anchored to the button +
      solid width≥3 + node-curve exclusivity; 7b asserts node curve solid +
      thick + plan curve hidden; 5d asserts
      `sessions/<planId>/{t1,t2,t3}/<uuid>` hierarchy; ALL PASS;
- [x] docs: plan-mode.md §7.1 (two curves), new §8.7, TODO this table.

---

## P28 — Plans live under the owning session + import removed (user decision)

User: **"Why isn't a plan stored under its session's directory? A plan must
belong to a session, right? — I think import is an early-design leftover; we
don't need the 'import' feature, nor its UI."**
Decision: everything about a plan goes under its source session's dir; the
Browse/import feature and its UI are deleted.

### New directory layout
```
~/.alayaface/sessions/
  <uuid>/                  ← plain sessions (top level is never a plan child)
    session.alaya / config/
    plans/<planId>/        ← plans created by this session (0..N)
      <planId>.json / .meta.json / .run.json
      work/                ← per-plan working dir
      <nodeId>/<uuid>/     ← node child sessions
```
The top-level `plans/` root is deleted; no import → every plan has a
meta.json origin.

- [x] backend (Rust+Go symmetric): `create_session`/`resume_session`/
      `delete_session_dir` gain optional `originSessionId` (with existing
      planId/nodeId) → nested path
      `sessions/<San(origin)>/plans/<San(planId)>/<San(nodeId)>/<uuid>`;
      resume/delete resolve directly by P28 paths (**no legacy fallback**);
- [x] `dirs.CreatePlanSessionDirFrom`/`create_session_dir_nested` new signature
      (originSessionId, planId, nodeId, uuid, preset) + top-level doc layout
      update;
- [x] frontend paths: `plansDir` → `sessionsDir` + `planDirIn`/`planDirOf`/
      `planFilePathOf`/`planOriginSessionId`/`onDiskSessionId` (Update.elm);
      PlanSaveReady writes into `sessions/<originDiskId>/plans/<planId>/`;
      origin records the **on-disk session id** (resume fresh ids resolved
      back via planResumedFrom);
- [x] planMetas index rebuild is two-level: `fs_list_dir(sessions/)` → each
      session's `plans/` → read each `*.meta.json` (new fields
      planMetaDirQueue/planMetaDirListing); planId extracted from file name;
- [x] binding/feedback resolve by live id: `planMetaForMessage` (View),
      `messageBoundToPlan`, `feedbackCompletedPlan`
      (NC.liveSessionForOrigin) — status bar, anti-duplicate, feedback still
      hit after resume/restart;
- [x] Plans manager single view: list directly from planMetas (no
      fs_list_dir); delete drops planMetas + closes windows (pendingDelete);
      `PlanManagerTab`/`PlanManagerBrowser*`/`PlanManagerSwitchTab`/
      `planBrowserPick`/`initPlanBrowser` all removed;
- [x] `planWinKeyForPath` simplified to the file name; FsResolvePathResult
      drops the Browse branch;
- [x] Ports/bridge.js: createSession/resumeSession/deleteSessionDir pass
      originSessionId;
- [x] tests: Go `TestSanitizeDirComponent`/`TestCreatePlanSessionDirFromNests`
      (new signature) + `TestIntegrationNestedPlanSessionDir` (origin-nested
      create, manager lists only plain sessions, nested resume, **missing
      origin/planId fails to resolve**, nested delete); Rust dirs.rs 2 cases
      updated; Elm 213 green; e2e 5d asserts
      `sessions/<origin>/plans/<planId>/{t1,t2,t3}/<uuid>` + plan document/
      meta/run all inside the session dir + manager has no Browse page + work
      dir new path;
- [x] docs: plan-mode.md §7.2 (single-view manager), §8.7 (P28 rewrite), §12;
      TODO this table; go-backend.md command table + layout note;
      manual-acceptance 5c.

---

## P29 — Remove ALL backward-compat code (user: it is all useless)

User: **"No migration needed. Also audit the project for 'backward-compat'
code — it's all useless."** Four categories audited and removed:

- [x] **Session-dir legacy fallback chain** (Go `resolveSessionDir` / Rust
      `resolve_session_dir` P27/flat paths): now `planSessionDirFor` /
      `plan_session_dir_for` builds the P28 path directly (plan sessions) or
      top level (plain sessions), **no fallback**; integration tests removed
      the LEGACY fallback 1/2 segments;
- [x] **Plan/Meta.elm lenient decode**: origin required (strict), planIndex
      required (removed `-1` default), dead `messageId` field (encoder never
      wrote it) removed from `Origin`; `PlanMeta.origin` tightened from
      `Maybe Origin` to `Origin` (no import = every plan has an origin), all
      consumers simplified (planDirOf/planOriginSessionId/
      messageBoundToPlan/planConnectionFor/feedbackCompletedPlan/node-session
      lookup, View 2 sites); `decodeMeta` fully strict; PlanMetaTest strict
      (missing origin/planIndex/created_at rejected);
- [x] **Legacy config-seed heal** (Go `HealLegacyConfigSeeds` +
      `LegacyRuntimeConfEmpty/Comment` + `LegacyModelConfSeed` / Rust
      `heal_legacy_config_seeds` + `LEGACY_*` + ensure() scans): whole block
      removed, matching tests deleted (Go `TestHealsLegacyConfigSeeds` / Rust
      `heals_legacy_config_seeds`);
- [x] **Always-true `has_session_file` field** (meaningless after P27's
      listing filter): Go `SessionDirInfo` / Rust `SessionDirInfo` / frontend
      `SessionDir` decoder + View 3 usages (canResume, "· no history",
      Resume hint) removed;
- [x] Kept (robustness, not compat): binary-resolution fallback, graceful-close
      SIGKILL fallback, probe fallback, NUL-prefix raw-frame fallback; plan
      schema optional-field defaults (model may omit them — input
      normalization, validate catches); P26's marker tightening direction;
- [x] verification: Elm 213 / Rust 43 (-1 heal test) / Go -race 8 pkgs / e2e
      ALL PASS; docs (plan-mode.md §8.7, go-backend.md command table/notes,
      TODO) synced.

---

## P30 — Remove the Plans entry from the system menu (user: not needed)

User: **"The system menu doesn't need plans."** The Plans manager's only
entry was the menu's Plans item, and plans now belong to sessions (reopened
via the session's `[Plan: …]` status bar, works after restart) → the manager
is deleted entirely:

- [x] menu: viewGlobalMenu drops "🕸 Plans" (OpenPlanManager); keeps the
      "open plan windows" switcher list (viewGlobalMenuPlan);
- [x] View: deletes viewPlanManagerOverlay / viewPlanSavedTab /
      planFileListFromMetas / viewPlanFile (incl. `PlanFileInfo`);
      plan open/parse failures now surface via setPlanErrors (in-window, no
      manager popup);
- [x] Types/Update: removes OpenPlanManager/ClosePlanManager/
      PlanManagerOpen/PlanManagerDelete/PlanManagerSetFilter msgs,
      PlanManagerState + planManager field, FsDeleteResult handler,
      refreshPlanList (already no-op); removes `fsDeleteFile`/`onFsDeleteResult`
      ports + bridge.js handler (only consumer was the manager; the backend
      fs_delete_file command stays as a general fs API);
- [x] e2e: step 9 now asserts the menu has NO Plans item (plan reopen via the
      status bar still covered by step 6); ALL PASS;
- [x] docs: plan-mode.md §7.1/§7.2 (manager removal note)/§12, TODO this table.

---

## P31 — Fix: plan run state lost after restart (user report)

User: **"After restarting, the plan's execution state seems to be lost?"**
Reproduced with `e2e/restart-e2e.mjs` (new: create plan → run to completion →
restart the backend → resume the origin session → status-bar reopen → assert
badge/nodes).

**Root cause**: P28 moved plan files into `plans/<planId>/<planId>.meta.json`
(the plan's own subdir), but the planMetas index rebuild still scanned the
old P27 layout for `plans/*.meta.json` (flat) — `plans/` contains only planId
subdirs (all dirs), so the meta list was always empty and no reads were
issued → **planMetas empty after restart** → the `[Plan: …]` status bar never
renders and the plan cannot be reopened (looks like "state lost"). E2E never
restarted before, so planMetas were always populated live by PlanSaveReady —
the gap never surfaced.

**Fix (Update.elm)**:
- The level-2 scan (`sessions/<uuid>/plans` listing) now treats every
  **subdir** as a plan and builds the meta path directly
  `<plansDir>/<planId>/<planId>.meta.json` (no third-level scan); filters
  `..`/`.` (fs_list_dir prepends `..` for non-`/` dirs — the old code listed
  `sessions/../plans` too; harmless but wasteful);
- Also eliminated a latent race: `FsHomeDirResult` used to batch
  `fs_list_dir(home)` (file picker) with `fs_list_dir(sessions)` (scan) — the
  two results are untagged and indistinguishable; if the home result arrived
  first it was eaten by the scan branch and misrouted. New
  `planMetaScanPending`: the scan starts only after the home listing was
  consumed by the file-picker branch (serialized, no same-batch race).

- [x] verification: `e2e/restart-e2e.mjs` ALL PASS (restart → resume origin →
      `[Plan: …]` appears → reopen → badge Completed + 3 nodes succeeded);
      `make e2e` now runs plan-e2e + restart-e2e; Elm 213 / Rust 43 /
      Go -race 8 pkgs green;
- [x] docs: TODO this table.

---

## P32 — User-driven UI/CI round (curves/scrollbar/buttons/startup/CI)

User's five requests:
1. **Ancestor-chain lines**: with an A-B-C-D dependency chain, when D is
   selected its parent lines (A→B, B→C, C→D) should also show — not just the
   session↔D curve.
2. **S-shaped bezier**: lines should have 2 reverse arcs (two control points
   on opposite sides of the travel line) — prettier.
3. **Scrollbar must not affect width**: the message column should stay exactly
   as wide as the Prompt Input; make the scrollbar overlay (float over the
   content, consume no layout width).
4. **Session Overlay buttons uniform**: Resume used the big default,
   Delete used small inline styles → unify to one size.
5. **No auto-created session at startup**: drop init's `create_session`; the
   user opens one via ⚙ → New Session when needed.

Plus **CI for Tauri + Elm** (user asked "can GitHub CI cover the tauri and
elm parts too?"): ci.yml already had go/elm/rust jobs → enhanced with
`cargo build` (full Tauri compile) in the rust job + a new e2e job (Go
backend + fakecore + headless Chrome running plan-e2e + restart-e2e).

### 1+2 curves (bridge.js + Elm)
- [x] ~~ancestor-chain curves~~ **removed after user clarification**: the P32
      first cut implemented `NodeConnection.ancestors`/`ancestorEdges`
      (transitive parent closure) + a bridge path pool (extra faint
      A→B/B→C/C→D curves between node cards when D's session is focused).
      User corrected: **"when the plan window is active it should connect to
      its owning [Plan: xxxx]xxxx; the nodes inside it already have
      connections — no extra lines needed."** The DAG canvas already draws
      node↔node dependency edges, so the extra curves were duplicates.
      Reverted (NodeConnection.elm fields/functions, Update withAncestors,
      bridge path pool, `.node-connection-curve-ancestor` CSS, 6 unit tests);
      the connection model is back to exactly two curves, no extras:
      P19 session↔node card, P27 plan window↔owning `[Plan: …]` button;
- [x] bridge.js `curvePath`: **S-shape** — c1 offset +bow, c2 offset **-bow**
      (control points on opposite sides → two reverse arcs crossing the
      straight line at the midpoint); the plan↔session curve shares it;
- [x] tests: NodeConnectionTest back to 213 (6 ancestor cases removed);
      **Elm 213** green;

### 3 overlay scrollbar (bridge.js + style.css)
- [x] CSS: `.messages` hides the native scrollbar (`scrollbar-width: none` +
      `::-webkit-scrollbar { display: none }`) → the message column width is
      constant = the input bar's width; new `.overlay-scrollbar` (absolute
      right 4px, top/bottom 12px) + `.overlay-scrollbar-thumb` (6px rounded,
      darker on hover/dragging, light-theme variant);
- [x] bridge.js: `attachOverlayScrollbar` injects one overlay scrollbar per
      `.messages`; driven by scroll / ResizeObserver / MutationObserver →
      `updateOverlayScrollbar` (visible only when scrollable; thumb height ∝
      viewport/content ratio, position ∝ scrollTop); thumb drag + track click
      + native wheel preserved; the existing Elm scroll-state port is
      unchanged;

### 4 Session Manager buttons uniform (View.elm + style.css)
- [x] new `.sel-page-item-btn` (padding 6px 14px, min-width 76px,
      font-size 0.8rem) + allow/deny color classes; Resume and Delete both
      use them; Delete's inline small overrides removed → both buttons in a
      row are the same size;

### 5 no auto-created session at startup (Main/Update/View/Types)
- [x] Main.elm init drops `Ports.createSession …` (previously spawned an
      empty session window); dead `initializing`/`initError` fields removed
      (Types field, Update SessionCreated `initializing = False`, View
      Connecting branch);
- [x] `viewNoSessionPanel` always shows the welcome screen: logo + "No
      session open — use ⚙ New Session to start" (new `.no-sessions` CSS);
- [x] menu New Session / plan auto-create / restart restore unaffected
      (CreateSession still passes planSystemPrompt; e2e always clicked New
      Session explicitly — comment updated);
- [x] e2e: fixed restart-e2e's backend-restart race — after `kill SIGTERM`
      it only slept 800ms; the old server held the port while gracefully
      closing sessions → the new process failed to bind and the page talked
      to the dying server; now `waitExit(server, 15s)` waits for the old
      process to truly exit before starting the new one; plan-e2e +
      restart-e2e ALL PASS (intermittent restart failure fixed);

### CI (.github/workflows/ci.yml)
- [x] rust job gains `cargo build` (full Tauri app compile, not just test);
- [x] new `e2e` job: setup-go + setup-node + global elm → `elm make` builds
      elm.js → `npm install` (e2e/) → `node plan-e2e.mjs` + `node
      restart-e2e.mjs` (ubuntu-latest ships /usr/bin/google-chrome, no
      download);
- [x] verification: Elm 213 / Rust 43 / Go -race 8 pkgs / make e2e (both
      scripts) green;
- [x] docs: plan-mode.md (§4 startup note, §7.1 ancestor removal + S-shape,
      §12 P32 row), TODO this table, manual-acceptance Startup +5 items.

---

## P33 — Fix: "Session is already active" after page refresh (user report)

User: **"After refreshing the page, session resume errors with 'Session is
already active'. Only restarting the Go process helps. That's wrong."**

**Root cause**: session handles (alayacore children) belong to the **backend
process** lifecycle, while session windows belong to the **page** lifecycle.
After a refresh the new page's Elm registry is empty (`model.sessions` is
empty), but the Go backend still holds every old page's session handles
(`session.Manager` non-empty); `resume_session` rejects by "dir already
active" (the double-resume guard) → Session Manager Resume keeps failing
until the Go process dies. WS disconnect only unregisters the client, it does
not close sessions (by design: the server must not kill sessions on a
transient network drop).

**Fix (reclaim orphaned sessions)**:
- new RPC `close_all_sessions` (Go `CloseAllSessions` + Rust
  `close_all_sessions`, registered in handlers.go / lib.rs): gracefully
  closes **every** active session — the same cancel-first sequence as
  close_session (cancel → save → EOF → ≤5s grace → SIGKILL), **history
  preserved to the cancel point** (not the shutdown hard-kill `CloseAll`).
  Go gains `Manager.CloseAllGracefully` (snapshot then `closeGracefully`
  each, log "reclaimed on page load");
- frontend: Ports `closeAllSessions` + bridge.js pass-through
  (fire-and-forget) + Main.elm init first command — **every page load**
  reclaims the previous page's orphaned handles (Tauri startup: no sessions →
  no-op, harmless);
- edge cases: an immediate New Session click does not conflict with
  close_all (it only closes old handles); the Session Manager is opened far
  later than the reclaim (human action), so the race window is negligible;
- tests: Go integration `TestIntegrationCloseAllSessionsReclaimsOnPageLoad`
  (two active sessions → close_all → old ids report not found → resume works
  again = the user's path); restart-e2e gained **Phase 1.5 page refresh**:
  after the plan completes, `page.reload()` (same backend) → Session Manager
  → Resume the origin session (assert clickable, no already-active) →
  `[Plan: …]` status bar appears; Elm 219 / Rust 43 / Go -race green + make
  e2e both scripts ALL PASS;
- docs: go-backend.md command table + TODO this table.

---

## P34 — Cascade close: a session's children (user request)

User: **"When a session window got closed, its children (plans, sessions of
plans) should also be closed."**

**Semantics**: session → plans (meta origin) → node sessions
(planNodeSessions), and a node session can own sub-plans (R-series
recursion) → closing any session window closes its whole subtree:

- each child plan: **StopRun first** (nodes → Canceled → `closeAndClear`
  emits `CloseSessionFor` per bound session → window + process closed;
  **the runner cannot respawn anything**) → then `PlanClose` (window,
  create queue, connection curves);
- node sessions close through the same `CloseSessionFor → update
  (CloseSession sid)` path → **recursive** (sub-plans of sub-plans…); the
  tree is finite (each session closes once, removed on close), no cycles;
- cascade-closed node sessions do NOT emit a spurious SessionDisconnected
  (StopRun cleared their sessionId → `findPlanIdBySession` finds nothing →
  runnerFailCmd empty); **manual** node-session closes keep the old
  fail→retry behavior;
- `DeleteSession` (Session Manager delete; the on-disk dir contains the
  whole `plans/` subtree) cascades too — windows/processes close before the
  dir is removed.

**Implementation**:
- `Plan/Meta.elm` (pure, testable): `plansOwnedBySession : Dict String
  PlanMeta -> String -> List String` (plans whose meta.origin.sessionId
  matches);
- `App/Update.elm`: `closeSessionChildren` (disk-id resolution → child plan
  list → foldl `closeChildPlan`); `closeChildPlan` = `update (PlanClose
  planId)` (P35 moved the stop+close logic into PlanClose); `CloseSession`
  and `DeleteSession` run the cascade first;
- tests: PlanMetaTest +4 (multi-plan ownership / other sessions excluded /
  unknown session empty / empty index empty); **Elm 217** green;
- E2E: plan-e2e gained **8c** — re-Run (t3 hangs, hang marker cleared first)
  → close the ORIGIN session (✕) → assert the plan window and `/t3` node
  window are gone + nothing respawns after 1.5s; plan-e2e + restart-e2e ALL
  PASS; Rust 43 / Go -race 8 pkgs green;
- docs: TODO this table.

---

## P35 — Plan-window close cascades down to node sessions (user report, twice)

User: **"Closing the plan window does not close the session windows below
it."** The first P35 attempt only stopped active runs (InProgress/Paused)
and relied on closeAndClear's CloseSessionFor — but node sessions can also
be open under TERMINAL runs (e.g. a session resumed from disk under a
Stopped/FailedRun plan for review); closing the plan window there closed
nothing. The user confirmed it was still broken.

**Fix (PlanClose, three steps)**:
1. run InProgress/Paused → StopRun first (no respawn; closeAndClear closes
   the sessions it knows);
2. close **every LIVE session window bound to the plan's nodes,
   unconditionally** — `nodeSessionIdsForPlan` collects direct bindings
   (`planNodeSessions` sid → "planId/nodeId") + resumed windows
   (`planResumedFrom` live → orig, orig bound to the plan), filtered to live
   ids only (a closed binding's backend handle was already replaced by
   resume — closing it again would only log "Session not found") →
   `update (CloseSession sid)` each (their sub-plans cascade through
   CloseSession);
3. remove the plan window.
Terminal runs are NOT re-stopped (would overwrite `planRunStatuses` e.g.
Completed → Stopped and break the status bar — R4's auto-close after
completion still works).

**Implementation**:
- `nodeSessionIdsForPlan : String -> Model -> List String` (Update.elm);
- `closeChildPlan` (P34) delegates to `update (PlanClose planId)` — the
  stop+close logic lives in one place;
- E2E: plan-e2e gained **8e** (the exact reported case: Stopped plan → click
  t1 → its session resumes from disk (window opens) → close the plan window
  ✕ → the `/t1` window closes) + **8d** (active run: Run → t3 hangs → plan ✕
  → t3 gone + no respawn); both phases reopen the plan via the `[Plan: …]`
  status bar; ALL PASS;
- verification: Elm 217 / Rust 43 / Go -race 8 pkgs / plan-e2e +
  restart-e2e ALL PASS;
- docs: plan-mode.md §7.1 (P35 paragraph), §12 P35 row, TODO this table,
  manual-acceptance cascade item.

---

## P36 — Connection chain: a deep node session shows its WHOLE ancestor path

User: **"连接session窗口和plan窗口的贝塞尔曲线，显示规则需要改进。当一个很深的
子节点被选中的时候，整条路径都需要显示出来。期待的行为是通过连线直接能找到最顶上
的session窗口"** — the curves connecting session and plan windows need better
display rules: when a deep child node is selected, the WHOLE path must be
shown; through the lines you can directly find the topmost session window.

This **supersedes P32's "no ancestor-chain curves"** rule (which removed the
ancestor curves because the DAG already draws node↔node edges — the P32
clarification was about extra LINES BETWEEN CARDS, not about the path up to
the top session; the user now wants exactly that path when a deep node
session is focused).

**Design**:
- **Chain shape** (pure, `App/NodeConnection.elm`): alternating segments —
  `node` (session window → its node card in the plan) and `plan` (plan
  window → its LIVE owning session, anchored on the `[Plan: …]` button when
  visible). `chainForSession` starts at the focused session's own node
  segment; `chainForPlan` starts at the active plan's own plan segment; both
  then walk UP: plan segment → (origin is a node session?) its node segment
  → parent plan segment → … until a plain session, a closed owning session,
  or a missing meta; `visited` guard makes it cycle-safe. Resumed origins
  resolve to their live windows via `planResumedFrom` / `liveSessionForOrigin`.
- **Z-stacking** (`raiseChainWindows`, Update.elm): every window on the path
  is raised, ordered top→bottom — focused session, its plan (session z =
  plan z + 1), that plan's owning session, then ITS plan, … up to the
  top-level session. With that order every node curve (drawn at its plan's z)
  and every plan curve (drawn at max of its two participants' z) is visible.
- **bridge.js**: one fixed SVG overlay per segment (`.node-connection-overlay`
  / `.plan-connection-overlay` per segment, own z-index), rAF-measured every
  frame; segments whose participants are missing are hidden.
- **Model**: the two single connections (`nodeConnection`/`planConnection`)
  became one `connectionChain : List NC.ChainSegment`; the two ports became
  one `setConnectionChain : List NC.ChainSegment -> Cmd msg`.
- **Behavior changes**: the plan↔owning-session segment is now ALSO visible
  while a node session is focused (it is part of the chain); closing the
  anchor session clears the whole chain; closing a mid-chain window drops
  its segments; PlanActivate/PlanStatusOpen/plan auto-create all draw the
  full chain for sub-plans (top-level plans keep drawing just their single
  plan↔session curve).

**Implementation**:
- `App/NodeConnection.elm`: `ChainCtx`/`ChainSegment` + `chainForSession`,
  `chainForPlan`, `ancestorChain` (cycle-safe);
- `App/Update.elm`: `connectionChainForSession`/`connectionChainForPlan`,
  `chainCtx`, `raiseChainWindows`, `dropChainSession`; all connection call
  sites rewritten (activateSessionModel, ActivateSession, PlanActivate,
  PlanStatusOpen, addPlanWindow/PlanSaveReady/openPlanFile, SessionCreated
  (resumed sessions build the chain immediately), CloseSession, PlanClose,
  DeleteSession);
- `src/Ports.elm`: `setConnectionChain` (replaces setNodeConnection/
  setPlanConnection); `App/Types.elm` + `Main.elm` + `RpcErrorTest.elm`
  updated to the new field;
- tests: NodeConnectionTest +15 (single-level chain, 3-level deep chain,
  plain/unbound session → [], resumed origin, closed mid-chain origin stops,
  missing meta stops, cycle terminates, chainForPlan top-level/sub-plan/
  closed-origin/unknown); **Elm 249** green;
- E2E: plan-e2e 7b updated — while the t1 node session is focused the
  plan↔owning-session segment is now asserted VISIBLE (chain to the top);
  bridge.js passes `node --check`;
- **follow-up fix (user report)**: clicking a sub-PLAN did not switch the
  display back to the plan's own chain — `PlanActivate` early-returned when
  the plan was already `planActiveId` (it stays set from auto-creation
  while focusing a session switches the chain away without clearing it).
  `PlanActivate`, `ActivateSession` (already-focused) and `PlanStatusOpen`
  (already-open) now ALWAYS rebuild + raise + emit the chain, so clicking
  the sub-plan (or its `[Plan: …]` link, or the sub-session again) switches
  the path and brings its windows back on top; Elm 249 + plan-e2e green;
- docs: plan-mode.md §7.1 (P36 paragraph), §12 P36 row, TODO this table,
  manual-acceptance connection item.

---

## R series — Plan refactor: model-autonomous sub-flows + recursion

> **Core document: `REFACTOR.md`** (full design + phase flow + confirmed
> decisions D1–D15).
> Interruption recovery: read REFACTOR.md → this checklist → continue from
> the first `[ ]`.
> Each phase: full tests → commit → push three remotes (origin/gitee/org).

### R1 foundation: schema + pure logic (Plan/Types + Runner)
- [x] Plan/Types.elm: removed `defaultTimeoutSeconds`/`timeoutSeconds` fields
      and validate checks (decode ignores unknown fields → old plan files
      with timeout open normally); NodeStatus gains `WaitingForPlan`
      (nodeStatusToString/FromString `"waiting_for_plan"`);
- [x] Plan/Runner.elm: removed `Tick`/`checkTimeouts`/`timeoutNode`; TaskDone
      event gains `delegated : Bool` (the Update layer decides from "last
      message contains plan JSON"); WaitingForPlan transitions: TaskDone+
      delegated → WaitingForPlan; `ResumeDelegatedNode` (feedback continue) →
      Running; Stop while waiting → Canceled; manual TaskDone (non-delegated)
      while waiting → Succeeded; TaskDone error while waiting → ignored,
      stays waiting;
- [x] tests: removed 5 timeout cases (runner) + 3 (schema timeout); added 7
      WaitingForPlan transition cases + 1 codec roundtrip; Elm 180 green;
      Rust 42 / Go -race 8 pkgs unaffected

### R2 detection + auto-create
- [x] App/Update.elm: pendingPlanOffers reworked into **auto-create**
      (detect → create immediately, no button); parse-failure errors inline
      into the original message (injectPlanErrorIntoSession);
- [x] planSystemPrompt rewritten (no role lock, advisory) + injected into ALL
      session creates (plain sessions + node sessions = recursion entry);
- [x] deleted Plan Session: menu entry, CreatePlanSession Msg,
      planSessionPending, planSessionIds, [Plan] title, Plan Session's
      builtinTools="";
- [x] fakecore: planMode trigger changed to prompt containing "plan"
      keyword; E2E: New Session flow + auto-create assertion + t3 hang marker
      pre-seeded (first run must not hang after timeout removal) + deleted t3
      timeout assertion; E2E ALL PASS;
- [x] replay-suppression (prevent duplicate create) → implemented in R3 with
      meta.json binding (see R3 first item)

### R3 feedback + status bar + persistence
- [x] **replay-suppression** (R2 leftover): messageBoundToPlan (meta origin
      binding dedup);
- [x] meta.json codec (Plan/Meta.elm: origin/feedbacks/created_at) +
      auto-create writes origin;
- [x] status-bar component (View + CSS + PlanStatusOpen): plan binding under
      the message (name/status/open);
- [x] feedback: feedbackCompletedPlan (Completed → node-output summary +
      [Plan: xxx] → send to the origin session to auto-continue; node session
      → ResumeDelegatedNode; Failed/Stopped zero feedback; writes feedbacks);
- [x] [Plan: xxx] link rendering (viewTextWithPlanLinks → PlanStatusOpen);
- [x] restart restore: fsHomeDir scans meta.json queue reads → planMetas;
      fs_list_dir returns empty for missing dirs (Rust+Go); fakecore msgSeq
      increments echo ids;
- [x] tests: PlanMetaTest +3; E2E feedback/status-bar assertions; Elm 183 /
      Rust 42 / Go -race / E2E ALL PASS

### R4 close rules + re-run cascade
- [x] closeAndClear: Succeeded also closes the node window (lastSessionId
      binding kept, click resumes for review); WaitingForPlan not closed
      (waits for the sub-plan);
- [x] Plan Completed → feedback first → plan window auto-closes
      (Task.perform PlanClose); Failed/Stopped kept; planRunStatuses (memory
      cache — status bar shows the real status after the window closes);
- [x] re-run (RestartRun event + PlanRunRestart Msg + restartPlanCascade):
      skips Succeeded; unfinished nodes reset (Blocked → Pending so it
      re-schedules); WaitingForPlan nodes NOT reset → subPlansOfPlan (meta
      origin reverse lookup) cascades to sub-plans (planId unchanged, unbounded
      descent); status bar [re-run] (shown for Failed/Stopped/Paused);
- [x] fixed a latent bug along the way: run.json-restored nodes had
      nodeId="" (encode never wrote node_id) → allDepsSucceeded broke →
      restored runs could not schedule (Load run affected too) — decode now
      fills nodeId from the dict key;
- [x] fakecore: the `[Plan result]` prefix always replies normally (feedback
      containing node-output keywords must not trip the marker scenario);
- [x] E2E rewrite: run completion judged via the status bar (plan window
      auto-closes); run.json asserts retry evidence; node click → resume
      (succeeded windows already closed); 8b Stop kept (t3 hangs → Stop →
      window closed); ALL PASS; Elm 183 / Rust 42 / Go -race green

### R5 cleanup + docs + real-core bug fix
- [x] **Real-core bug fix (boot-frame gate, commit b0a58b8)**: alayacore
      emits `SM task in_progress:false` at session start (before any prompt)
      → `planEventFromFrame` mistook it for TaskDone → node marked Succeeded
      (empty output) → closeAndClear immediately CloseSessionFor (cancel-first)
      → "Canceled right after the first prompt", run completed in milliseconds.
      Fix: `Model.planTaskStarted : Set String` gate (TaskDone only dispatched
      for sessions that saw in_progress:true); cleaned up in CloseSession;
      fakecore mirrors the frame sequence (boot with in_progress:false +
      in_progress:true before replying) so E2E covers it; real-core verification
      (LLaMA.CPP gemma-4-12B): before — nodes 12ms/7ms + AT "Canceled"; after —
      all three nodes produce real output, strict chain order, no Canceled;
- [x] E2E full rewrite (done in R4, commit 4bc7456): fixture t3 keeps hang-once
      (for Stop); E2E pre-seeds the t3 hang marker (first run succeeds
      instantly); recursion/feedback/status-bar/re-run-cascade steps;
- [x] dead-code cleanup (P22 leftovers, plan-offer-btn CSS); Time.every
      subscription removed — commit `20d10a5` (Main.elm has no Time.every, no
      Create-Plan offer button remains; `.plan-offer`/`.plan-offer-btn` are
      live status-bar code);
- [x] docs: docs/plan-mode.md (§5/§6.7/§7/§8.5 timeout removal/§13, §6.4 boot
      frame gate), README, docs/manual-acceptance.md — commit `b7c9b6a`
      (English new sections);
- [x] full verification: Elm / Rust / Go -race / make e2e green → committed →
      pushed to three remotes (R1–R5 commits e934235/7672815/51077ea/
      4bc7456/b0a58b8 all in history and pushed)

## P11 — Review pass 2: create-queue serialization + create-failure recovery

- [x] **create_session failure deadlock**: failures only logged to
      bridge console.error, Elm never got SessionCreated → `planCreating`
      never released → every later create (runner + user) queued forever
      (e.g. an invalid node preset hung the whole run). Added
      `onSessionCreateError` port (Ports+bridge+Main) + `SessionCreateError`
      Msg + Runner `SessionCreateFailed` event (Starting nodes fail → auto
      retry / eventually Failed, no hanging);
- [x] **user-create vs runner-create race (root fix)**: session creation is
      a **single serialized queue** `planCreateQueue : List CreateTask`
      (`RunnerCreate planId nodeId` / `UserCreate "normal"`), `planCreating :
      Maybe CreateTask`; a user's New Session click queues behind in-flight
      runner creates; SessionCreated dispatches by tag: RunnerCreate → bind
      the node, UserCreate → activate only and drain the queue → a user
      session can never be misbound to a runner node;
- [x] **runner sessions don't steal focus**: SessionCreated for runner
      creates does not activate/focus (the user is watching the DAG and
      clicks nodes to open); `pendingSwitchOnCreate` consumed only by
      non-runner creates (resume/user creates are not stolen by runner
      sessions);
- [x] **planResumeNode consumption guarded**: only non-runner sessions
      consume it; runner sessions never re-bind by mistake;
- [x] **fs listing pollution**: run.json is rewritten every step →
      FsWriteResult triggered refreshPlanList (plans dir listing) → when the
      manager was closed the result fell into the file-picker branch and
      polluted its list → refresh only when the manager is open;
- [x] tests: Elm 128 (new SessionCreateFailed 3 cases: Starting fail →
      Waiting retry, non-Starting ignored, exhausted → Failed); Rust 35;
      Go green.

## P12 — Graceful close + dead-code cleanup + acceptance doc (no GUI round)

- [x] **close_session graceful close (v2 backlog → implemented)**: alayacore
      verified read-only (save CI with empty args → session.alaya; EOF +
      active task → drainUntilTaskDone finishes it and handleTaskDone
      auto-saves then exits; EOF + no task → exits immediately; rawio has no
      SIGINT handling — EOF is the only graceful-exit signal). Implemented:
      save CI → close stdin (EOF) → wait ≤5s natural exit → SIGKILL fallback
      (dual backend symmetric):
  - [x] Rust `alayacore.rs`: `close_child_gracefully` (try_lock writes save
        frame → slot to None closes the pipe → grace wait → SIGKILL) +
        `kill_child` changed to "EOF grace 3s then kill"; `SessionHandle.stdin`
        → `Arc<tokio::sync::Mutex<Option<ChildStdin>>>` (close really EOFs,
        not Arc-count dependent); io.rs/mod.rs writers return "Session is
        disconnected" for None;
  - [x] Go `session.go`: `closeGracefully` (SendCmd save → Stdin.Close →
        poll Connected() for natural exit → timeout kill) — **does not call
        cmd.Wait() itself** (os/exec forbids concurrent Wait, -race warned;
        reaping owned by the reader's killOnce); `core.go` KillChild changed
        to the grace style;
  - [x] fakecore gains a `save` command (writes a session.alaya marker) →
        integration test `TestIntegrationGracefulCloseSavesSession` (file
        contains the saved marker after close; second close reports
        "Session not found");
  - [x] Rust unit tests +4 (save frame reaches child stdin / stubborn child
        killed on timeout / kill_child lets it exit naturally first / dead
        child doesn't panic) → Rust 39;
  - [x] known limitation: a long task not finished within the grace window is
        still SIGKILLed (save already hit disk first);
- [x] **dead-code cleanup**: `PlanWindow.creating`/`createQueue` leftover
      fields removed (globalized in P7; declared+initialized only, no
      references); Elm 128 stays green;
- [x] **acceptance doc**: new `docs/manual-acceptance.md` (complete smoke
      checklist for GUI use: Plan Session → Create Plan → Run → node bind →
      retry → graceful close → presets → regression; known limitations
      included);
- [x] docs sync: docs/plan-mode.md (§8.3 graceful close, §10 persistence,
      §13 defaults, §14 references), docs/go-backend.md (close_session row +
      killChild note), README (graceful-close paragraph);
- [x] tests: Elm 128 / Rust 39 / Go all green (-race).
- [ ] MANUAL smoke (GUI env, per docs/manual-acceptance.md)

## P13 — Attempt-session history list (attempt_session_ids)

P9 leftover: after a retry, `lastSessionId` was replaced by the new session;
the failed attempt's session dir exists on disk but is unreachable (only the
latest via last_session_id).

- [x] `NodeRunState` gains `attemptSessions : List String`: **all** session
      ids ever bound to the node (dedup, order kept); `bindSession` appends;
      retry/Stop/re-Run do NOT clear (kept across runs — old session dirs
      still exist, resumable anytime); only a fresh RunState is empty;
- [x] run.json codec: `attempt_session_ids` encoded + lenient decode (elm/json
      has no map9 → nested map2 stacking; old files missing the field → [],
      compatible with pre-P12 files);
- [x] UI: node detail panel gains "History sessions (N)" list (short-id
      buttons, monospace); click → `PlanOpenAttemptSession planId nodeId sid`:
      - session alive → ActivateSession focus;
      - closed → `resume_session` + pendingSwitchOnCreate focus +
        planResumeOwner error routing; **planResumeNode = Nothing** — unlike
        PlanOpenNodeSession, the history view does NOT re-bind the node, the
        current active binding is untouched;
- [x] tests: runner (accumulates [s1,s2] across retries, no duplicate rebinds,
      re-Run keeps history) + codec roundtrip (attempt_session_ids two-node
      assertion) + lenient (missing → []); Elm 131 green;
- [x] docs sync: plan-mode.md §10 (three persisted fields); TODO progress
      table; docs/manual-acceptance.md history-session item.

## P14 — Concurrency selector in the plan header

- [x] `PlanViewState.concurrencyInput` (empty = use the plan JSON's
      concurrency); the header controls row gains a number input (1–8,
      title hints the default);
- [x] pure function `Plan.Types.parseConcurrency : String -> Maybe Int`:
      trim, invalid/empty → Nothing (falls back to the plan default), valid
      integer clamped 1–8 (0→1, 99→8); exported + 6 unit cases;
- [x] both `PlanRunStartAt` paths (first Run / re-Run after completion) apply
      the override: `{ baseRun | concurrency = c }` (re-Run keeps the old run
      state, node statuses reset by StartRun, only concurrency replaced);
      `PlanSetConcurrency` Msg written back via updateActivePlanWin;
- [x] docs sync: TODO progress table (P5 leftover closed); docs/manual-
      acceptance.md concurrency item;
- [x] tests: Elm 137 (+6 parseConcurrency) green.

## P15 — Headless-browser E2E automation + real bug fixes (no GUI/real model)

Answering "does a human have to test?": **No.** Unit tests are fully
automatic; the core GUI flow in manual-acceptance can also be fully
automated — with **fakecore as the fake model** (our scriptable alayacore
stand-in) + **system Chrome headless** + the Go backend, driving the real DOM.

- [x] `e2e/plan-e2e.mjs` (node + puppeteer-core, zero model dependency):
      ⚙ → New Plan Session → prompt → fakecore replies with fenced plan JSON →
      Create Plan offer → Plan window DAG → concurrency override → Run →
      t1/t2/t3 Succeeded (t2 fails once via marker, auto-retry) → runLog
      asserts the retry → click t1 node → session activates and shows the
      reply → 5 screenshots → cleanup; `make e2e`;
- [x] fakecore extensions (protocol-compliant + scenario scripting):
      - accepts `--system`/`--builtin-tools` (previously unknown flags made
        it fail to start);
      - `--system` non-empty (= Plan Session) → first UE replies a full AT
        frame with fenced plan JSON;
      - `streamReply` now appends the `SM task in_progress=false` end frame
        (previously the runner never got TaskDone — a gap outside unit
        tests);
      - `fail-once` scenario: prompt contains "fail-once" → shared marker
        keyed by prompt hash (tmp); first process replies task_error, the
        retry process succeeds — cross-process simulation of "fails once,
        auto-retry succeeds";
      - Ar/At use different history_ids (previously both "hist-1", violating
        the real protocol);
- [x] **4 real bugs caught by E2E (unit tests can't reach)**:
  1. **fs_home_dir was never fetched in init**: first Create Plan had
     homeDir="" → saved to `/.alayaface/...` 500 → fix: `Main.elm` init adds
     `Ports.fsHomeDir {}` (Tauri benefits too);
  2. **WriteActivePreset fixed tmp name**: init seeding + create_session's
     Ensure ran concurrently → rename race 500 → fix: unique tmp name
     (pid+nanos), Rust+Go symmetric;
  3. **Elm `historyContents` keyed by history_id, not distinguishing At/Ar**:
     same id across roles lost At deltas → empty assistant messages (fakecore
     sharing "hist-1" exposed it; real alayacore ids are unique so unit tests
     couldn't construct it) → fix: tag-prefixed keys (defensive) + fakecore
     protocol compliance;
  4. fakecore lacked the SM task end frame (see above);
- [x] docs: README "Automated E2E" section, TODO, Makefile `make e2e`;
- [x] tests: Elm 137 / Rust 39 / Go 8 pkgs (-race) green; `make e2e` all
      passed (6 PASS + 5 screenshots).
- [ ] optional: real-model E2E (OpenAI-compatible API key or local .gguf) —
      needs the user to provide one; not blocking (fakecore covers the
      protocol + UI end to end).

## P16 — Per-plan work-dir isolation + task timeouts (user-confirmed pair)

### Directory isolation (§8.4)
- [x] `create_session` / `resume_session` gain optional `workDir` (Rust+Go):
      non-empty → backend MkdirAll + spawn sets the child cwd
      (`Command::current_dir` / `cmd.Dir`, AlayaFace-side only, C1-safe);
      fork/probe/plain sessions don't pass it (backward compatible);
- [x] Elm: `planWorkDir planId model` = `plans/<planId>/work`;
      `nodeSessionArgsIn` passes workDir; plan-node resume
      (PlanOpenNodeSession / PlanOpenAttemptSession) passes workDir; plain
      resume doesn't; Ports+bridge carry the workDir field;
- [x] fakecore boot SM frame reports `cwd` (assertable in tests);
- [x] tests: Go `TestSpawnWorkDir` (spawn cwd) + `TestIntegrationSessionWorkDir`
      (create/resume with workDir → cwd matches; without → backend cwd) +
      Rust mechanism-level `spawn_current_dir_mechanism` + E2E asserts
      `plans/<planId>/work` exists;
- [x] docs: plan-mode §8.4/§13, go-backend command table, README,
      manual-acceptance.

### Task timeouts (§8.5)
- [x] schema: `default_timeout_seconds` (plan level) + `timeout_seconds`
      (node override), default no timeout; validate ≥1; `effectiveTimeoutSeconds`
      exported; codec roundtrip;
- [x] Runner: `Tick Int` event (app-level `Time.every 1000ms` single
      subscription feeds all InProgress plans); schedule sets `startedAt`
      when a node enters Starting (timeout counts from launch, covers
      create_session hangs); `checkTimeouts` → `failNode "Timeout after Ns"`
      (reuses the close+retry/terminal path);
- [x] tests: Elm runner 5 cases (timeout → Waiting+close+retry / not reached
      no-op / no timeout never / node overrides default / timeout → retry →
      success loop) + schema 3 cases (decode/roundtrip/invalid) → Elm 145;
- [x] E2E: fakecore `hang-once` (hangs 30s, marker across processes) → t3
      hangs first → 5s timeout → auto-retry succeeds (runLog asserts t3
      waiting + attempts [1]); E2E all passed;
- [x] docs: plan-mode §5 schema/§8.5/§13, TODO, README, manual-acceptance.
- [x] tests: Elm 145 / Rust 40 / Go 8 pkgs (-race) green; `make e2e` all
      passed.

## P10 — Comprehensive review fixes (review round)

- [x] **Stop + backoff-timer bug**: a late auto-retry after Stop revived a
      Canceled node and re-activated a Stopped run → new `RetryTick` (auto
      tick only Waiting→Pending, never revives/activates) separated from
      `RetryNode` (manual retry, may revive);
- [x] **ScheduleRetry duplicate timers**: previously emitted per step for
      every Waiting node → now only when a node NEWLY enters Waiting
      (compared with the step's input state; fixed finishStep seeing the
      post-event state which broke dedup);
- [x] **orphan session leak**: Stop/closing a plan window racing an in-flight
      create left a session nobody binds — window/process leaked →
      `PlanBindSession` detects a failed bind (node not Running) and closes
      that session (window+process);
- [x] **Stop/PlanClose didn't clear the create queue** → now filtered by
      planId (`planCreateQueue`);
- [x] **resume failure didn't clear planResumeNode** → any later SessionCreated
      could misbind an unrelated session to the node → `planResumeOwner`/
      `planResumeNode` cleared on both success and failure paths;
- [x] **silent auto-restore overriding a new run race**: clicking Run right
      after opening a plan, a late run.json restore would overwrite the new
      run → silent restore only when the window has no run yet;
- [x] **open/import failure UX**: errors shown in the Plans manager (instead
      of creating an error window);
- [x] dead code cleaned (Runner.isTerminal unused); `toolConfirm="allow"`
      semantics commented (alayacore's --tool-confirm is a "tools requiring
      confirmation" list; "allow" matches nothing = everything auto-approved;
      security note);
- [x] verified non-issues: session id (UUID) vs plan key no collision; fs
      commands dual-backend parity; run.json two-field roundtrip; replay
      rendering completeness (HandlersTest);
- [x] tests: Elm 125 (new stop+tick no-revive, manual Retry revives,
      single retry timer, Canceled bind doesn't send prompt); Rust 35; Go
      green.

## P9 — Failed/stopped node sessions no longer lost (lastSessionId)

Review feedback: clicking a node opened an incomplete session / some sessions
were lost.

Investigation:
- completeness: alayacore writes the **full session** to `session.alaya` at
  every task end (handleTaskDone: save first, then the task-done frame);
  resume replays UT/AT/AF/UF/AR in order (with history ids). New HandlersTest
  verifies the UI renders the full replayed history (user prompt/assistant
  text/tool call/tool result/final answer); only "app killed mid-task" loses
  the in-flight round (alayacore save timing; C1: don't change alayacore).
- session-loss root cause: `closeAndClear` **cleared sessionId** for
  Failed/Waiting/Canceled nodes → run.json had no binding → after restart a
  node click showed only the detail panel; the session dir existed but was
  unreachable.

Fix:
- [x] `NodeRunState` gains `lastSessionId`: kept when the session closes
      (`session_id` cleared to avoid double-close, `last_session_id`
      persisted to run.json, codec lenient with old files); `bindSession`
      writes both; re-run clears both;
- [x] `PlanOpenNodeSession` priority: sessionId (alive) → sessionId (dead,
      resume) → lastSessionId (resume, failed/stopped sessions reviewable) →
      detail panel;
- [x] after a successful resume (resume_session hands out a new UUID each
      time) the node is **re-bound** to the new id via `planResumeNode` in
      SessionCreated (`rebindNodeSession`) — clicking again focuses directly,
      no more "Session is already active";
- [x] tests: runner (failure keeps lastSessionId, re-run clears), codec
      roundtrip (last_session_id), HandlersTest replay rendering; Elm 121
      green.

## P8 — Node ↔ session binding (click a node to open its session)

- [x] node click → `PlanOpenNodeSession planId nodeId`: sessionId alive →
      `ActivateSession` focus; closed/after-restart → automatic
      `resume_session` from disk (`pendingSwitchOnCreate` focuses; restore
      errors shown at the top of the plan window via `planResumeOwner`);
      no session (Failed/Blocked/Canceled) → node detail panel;
- [x] opening/importing a plan window **silently auto-restores**
      `<plan>.run.json` (`PlanReadTarget.continueRun=False`, best-effort: no
      file/corrupt ignored), restoring node states + `session_id` bindings —
      clicking any already-run node reopens its session; `Load run`
      (continueRun=True) keeps its semantics (restore then continue);
- [x] session window title shows the binding marker `[Plan · planId/nodeId]`
      (`planNodeSessions : Dict String String`, bound at PlanBindSession /
      PlanOpenNodeSession restore, removed at CloseSession/DeleteSession);
- [x] docs sync (docs/plan-mode.md §7.1/§10); Elm 118 green (run-state codec
      asserts sessionId roundtrip).

## P7 — Plan windows + runner prompt dispatch fix (review feedback)

- [x] **Plan UI is an independent window** (no longer an overlay):
      `planWindows : Dict String PlanWindow` + `planOrder` + `planActiveId`,
      each window owns `view`/`run`/`runPath`/`runLog`/`selectedNode`/
      `creating`/`createQueue`/`resumePath`; draggable/resizable/closable
      (reuses `windowPositions` + drag/resize machinery; new
      `PlanWindowDragStart`/`PlanResizeStart`/`PlanActivate`/`PlanClose`);
      multiple plans open at once, running independently;
- [x] **system menu (⚙) lists all open plans** (name + run status), click
      raises/activates (`viewGlobalMenuPlan`); the Plans manager stays as the
      launcher (open/delete/import);
- [x] **empty node session after Run fixed**: `Plan/Runner.elm` never
      generated the `SendPrompt` effect (only defined the type/handler), so
      after create+bind=Running the prompt was never sent. Now `bindSession`
      (Starting→Running) emits exactly one `SendPrompt`; tests cover (bind
      sends, duplicate bind doesn't, full lifecycle create→bind→prompt→done);
- [x] **second fix (still empty windows)**: after the first fix SendPrompt
      was generated but `runStepIn` applied effects against the PRE-step run
      state → `nodePromptIn` looked the prompt up by sessionId and got "" and
      dropped it. Fix: ① effects applied on the POST-step state (runStepIn
      updates the window run first, then dispatches); ② `SendPrompt` carries
      the prompt text (resolved by the runner at bind time from the plan) —
      the Update layer no longer re-looks-up, eliminating this loss; new test
      "SendPrompt carries the exact plan prompt"; Elm 118;
- [x] manually closing a node session window → injects `SessionDisconnected`
      (prevents runner hanging);
- [x] `planCreating`/`planCreateQueue` upgraded to global `(planId, nodeId)`
      serialization; `SessionCreated` → `PlanBindSession ts planId nodeId sid`
      unambiguous binding; runner events (TaskDone/Error/Disconnect) routed to
      the owning window by session id (`findPlanIdBySession`);
- [x] FsReadResult → `planReadTarget` (planId/path/isResume) routing:
      open/import → new-or-focus window; Load run → restore that window's run
      and ContinueRun;
- [x] docs sync (docs/plan-mode.md §7.1/deviations, README);
- [x] tests: Elm 117 (new prompt dispatch 3 cases).

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
      fs_list_dir, filters out *.run.json), Open / Delete (added fs_delete_file
      command Rust+Go+ports+tests); Import moved to Browse tab in P17
- [x] Global menu: "Plans" entry (🕸)
- [x] Plan view (P2 list form; P3 upgrades to SVG DAG): name/goal/meta/path +
      task list with id/title/preset/deps
- [ ] MANUAL smoke (Go backend browser / Tauri) — GUI env; checklist in docs/manual-acceptance.md
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
- [ ] Manual visual acceptance — GUI env; checklist in docs/manual-acceptance.md
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
- [x] fakecore/E2E: task_error → retry → success, parallel windows, node
      click opens window — automated by plan-e2e since P15 (GUI-env item obsolete)
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
- [x] Concurrency selector in the Plan header (edit before run) — P14;
      empty = plan JSON concurrency
- [ ] Manual GUI acceptance (Tauri + Go browser) — GUI env; checklist in
      docs/manual-acceptance.md; E2E via fakecore covers backend, runner
      covered by 128 elm tests

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
- [ ] Manual GUI smoke — GUI env; checklist in docs/manual-acceptance.md

---

## P17 — Plans manager Browse tab (file-browser import)

Replace the raw "Path to plan JSON…" input with a real file browser,
reusing the multimodal picker machinery (file list + fuzzy matching).

- [x] `PlanManagerState`: `importPath` removed; added `filter` (Saved-tab fuzzy
      filter), `tab : PlanManagerTab (Saved|Browse)`, `browser : Maybe
      T.FilePickerState` (Browse-tab browser state)
- [x] Msgs: `PlanManagerSetImport`/`PlanManagerImport` removed; added
      `PlanManagerSetFilter`, `PlanManagerSwitchTab`, `PlanManagerBrowserInput/
      Navigate/Select/Confirm/Pick`
- [x] `Overlay.FilePicker.view` gains `title` + `placeholder` config fields
      (was hardcoded "Attach Media"); session caller passes originals
- [x] View: Plans overlay = Saved tab (list + fuzzy filter via
      `Fuzzy.fuzzyMatch`) | Browse tab (`Overlay.FilePicker.view` rooted at
      home dir, sessionId "plan"); Export row untouched
- [x] Update: browser handlers mirror the session file picker (parsePathInput /
      appendDirToInput / filterEntries / fsResolvePath / fsListDir);
      confirm/pick on a file → shared `openPlanFile` (PlanReadTarget +
      fs_read_file_text), on a dir → navigate
- [x] Routing: `FsListDirResult`/`FsResolvePathResult`/`FsHomeDirResult`
      dispatch by `planManager.tab`; `refreshPlanList` no-ops while Browse is
      active (fs_list_dir owned by the browser); tab switch re-requests
- [x] Tests: elm-test 145 green; cargo/go unchanged (frontend-only change)
- [x] Manual GUI smoke: ⚙ → Plans → Browse → navigate/filter → click a plan
      JSON → opens Plan window —— **Browse/import removed in P28 (user
      decision), item obsolete**

---

## P18 — Node-session resume: keep the on-disk dir id as the binding

Bug report: click node → open session → close session window → click node
again → "Session directory not found".

Root cause (two bugs):
1. **Rust parity**: `session::create` generated its OWN uuid, ignoring the
   caller — create_session returned an id whose dir (`sessions/<other>`)
   never existed, so the FIRST close→click resume failed on Rust. Go used
   `cfg.ID` (id == dir name).
2. **Frontend rebind**: `resume_session` hands out a FRESH id (Y) while
   keeping the ORIGINAL dir (X). The frontend rebound the node to Y → after
   closing Y, resume Y looked up `sessions/Y` (doesn't exist). run.json also
   persisted Y → broken across restarts.

Fix:
- [x] Rust `SessionConfig` gains `id`; `create()` uses it (matches Go);
      create_session/resume_session/fork_session pass id == dir name
      (resume keeps the fresh-UUID semantics: new id, old dir)
- [x] Elm: remove `planResumeNode` + `rebindNodeSession`; add
      `planResumeFrom` (in-flight resume origin) + `planResumedFrom`
      (live id → original dir id)
- [x] Node click: live sid → focus; live resumed-from-sid → focus
      (`findResumedLive`); else resume the ORIGINAL id (dir exists)
- [x] `SessionCreated` records `planResumedFrom` + preserves the
      `[Plan · planId/nodeId]` badge on resumed windows; no rebind
- [x] `CloseSession`/`DeleteSession` drop the mapping; `findPlanIdBySession`
      resolves resumed ids back to the node (disconnect → fail/retry intact)
- [x] run.json keeps the original id → works after app restart
- [x] E2E step 8: close t1 session → click t1 → reopens (no error) ×2
- [x] Tests: elm-test 145 / cargo test 40 / go test -race / make e2e ALL PASS

---

## P19 — Node ↔ session connection curve (focus → plan second layer + bezier)

When the user focuses a session that belongs to a plan node, raise the
node's plan window to the SECOND layer and draw a bezier curve from the
session window edge to the node card.

- [x] `App/NodeConnection.elm` (pure): `nodeLabelFor` (resolves resumed
      fresh ids via planResumedFrom), `parseNodeConnection` (node id may
      contain "/"), `nodeConnectionFor`
- [x] Model: `nodeConnection : Maybe NodeConnection`; `setNodeConnection`
      port (Maybe → bridge.js shows/hides)
- [x] `activateSessionModel`: focus session → session z = nextZIndex+1,
      plan z = nextZIndex (second layer), port sends the pair; non-node
      sessions clear; `ActivateSession` already-focused branch re-asserts
- [x] `SwitchSession` shares the same helper; `SessionCreated` resume
      branch sets the connection + z-pairing when the resumed session
      becomes active (node click → resume → curve immediately)
- [x] Clear sites: CloseSession / DeleteSession / PlanClose / PlanActivate
      (plan window raised → node curve hides, plan curve takes over);
      JS hides it when the node is scrolled out of the plan window;
      z-index matches the plan window (above plan via DOM order, below
      session = planZ+1)
- [x] Tests: NodeConnectionTest (11) — labels, resumed resolution, slash
      node ids, unbound/unknown; elm-test 156 green
- [x] E2E: connection overlay visible + session z = plan z + 1 after
      focusing t1; curve hidden after close; curve back after both
      resumes; ALL PASS
- [ ] Manual GUI smoke: drag/resize windows while connected → curve
      follows (docs/manual-acceptance.md)

---

## P20 — runtime.conf seeding fix (alayacore key:value format, not JSON)

> Superseded in part by P21: instead of seeding a comment, presets are
> now EMPTY shells (no runtime.conf at all) and the heal REMOVES legacy
> seeds. P20's detection/verification work still applies.
> **P29: the legacy-seed heal was removed entirely** (user: backward-compat
> code is useless; no migration) — `HealLegacyConfigSeeds` /
> `heal_legacy_config_seeds` and their constants/tests are gone.

Bug report: EVERY session window shows
`runtime.conf: key "{}": cannot parse value "": line without ':' separator (missing colon?)`
(plus `API key is required` when the unconfigured Placeholder model is used).

Root cause: alayacore parses runtime.conf as `key: value` lines (see
alayacore docs/configuration.md + internal/config/parser.go — comment
lines are skipped); AlayaFace seeded a JSON empty object `{}` into it,
so every spawned alayacore emitted an SM error frame on startup, which
the UI renders as an Error message in every session window.

Verified against the real binary: `{}` → 1 error frame; empty or `#`
comment → 0 error frames.

- [x] Seed `runtime.conf` with a `#` comment (empty semantics) instead
      of `{}` — Rust dirs.rs `DEFAULT_RUNTIME_CONF` + Go dirs.go
      `DefaultRuntimeConf`
- [x] Heal existing installs: `dirs::ensure` / `Ensure()` scans
      `presets/*/runtime.conf` AND `sessions/*/config/runtime.conf`
      (session config copies) and rewrites any file whose content is
      exactly `{}` (alayacore never writes `{}` itself, so this is a
      unique sentinel)
- [x] Tests: Rust `heals_broken_runtime_conf` + seed assertion (41);
      Go `TestHealsBrokenRuntimeConf` + seed assertion; full suites green
- [ ] Note: `API key is required` is alayacore's response when a prompt
      is sent with the active model's api_key empty (seeded Placeholder
      model). Expected until a real model is configured; optional UX
      improvement: fail plan runs fast with a clear message when the
      active model has no api_key (v2, not implemented)

---

## P21 — Config files: empty shells only (alayacore auto-creates)

Follow-up to P20, per the principle "empty config files shouldn't be
created at all — alayacore creates them; copying an EXISTING preset is
the only meaningful file source".

Verified against the real binary: an EMPTY config dir starts with ZERO
error frames, and alayacore auto-creates model.conf (a working local
Ollama default: `api_key: "no-key-by-default"` — no "API key is
required" noise) + runtime.conf (proper key:value, no "{}" parse error).

- [x] `create_preset_defaults` / `CreatePresetDefaults`: presets seed as
      EMPTY shells (dir only); Safe still gets AlayaFace-owned
      settings.conf (meaningful — disables execute_command)
- [x] Removed DEFAULT_MODEL_CONF (fake "Placeholder" model) and
      DEFAULT_RUNTIME_CONF seeds entirely
- [x] Heal upgraded: legacy seeds are now REMOVED, not rewritten —
      runtime.conf "{}" / P20 comment seed, and an EXACT Placeholder
      model.conf (anything the user/alayacore wrote since is kept)
      — presets AND old session config copies
      (**removed in P29**)
- [x] Session config copies: copyDirExcluding of an existing preset is
      the file-producing path (tests updated to write a source file
      first, then assert the copy + settings.conf exclusion)
- [x] list_default_models / sync_default_models unaffected (probe-based;
      alayacore auto-creates model.conf → ModelSelector shows the
      working Ollama default instead of Placeholder)
- [x] Tests: Rust 41 / Go -race all pkgs / elm 156 / make e2e ALL PASS
- [ ] Optional follow-up: ModelSelector hint when the active model has
      no api_key (fail plan runs fast with a clear message) — v2

---

## P22 — Plan Session: role-lock prompt + no builtin tools (planner can't execute)

Bug report: the Plan Session "keeps forgetting its role", executing the
task directly instead of emitting the plan JSON.

Root cause: alayacore sends TWO system messages — its default ("execute
the user's task with tools") FIRST, then our `--system` planner
instruction — and Plan Sessions spawned with ALL builtin tools, so the
model both heard "do the work" and physically could.

Fix (two layers):
- [x] Rewrite `planSystemPrompt` (App/Update.elm): role-locked
      ("the planner is not the executor"), explicit prohibitions (never
      execute, never use tools, only ONE ```json block), handles "just do
      it" requests by still planning, follow-ups answer plan questions only
- [x] Plan Sessions spawn with `builtinTools=""` → NO builtin tools:
      the planner physically cannot search/read/write/execute
- [x] Backend tri-state `builtin_tools` (P6-documented v2 semantics,
      now implemented): Rust `Option<&str>` (Some("") → `--builtin-tools=`,
      None → no flag) + Go `*string`; effective-setting "" still means
      "don't pass = all tools"; bridge.js preserves explicit "" (was
      `|| null`-ed to null)
- [x] fakecore echoes `builtin_tools` + `builtin_tools_set` in the boot
      frame; Go test asserts the three states; Rust spawn test asserts
      the flag for Some("")/Some(list)/None
- [x] Tests: elm 156 / Rust 42 / Go -race all pkgs / make e2e ALL PASS
      (e2e server log shows `with --builtin-tools=<none>` for the Plan
      Session, runner sessions unaffected)
- [x] Real-model validation: the user ran a full plan with real models
      (Qwen + DeepSeek combo): t1/t2/t3 Succeeded, real output produced,
      real files landed in the work dir; Plan Session emitting only JSON
      verified by the user; leftover: real-model plan JSON quality not
      automated (needs a real API key; e2e covers the protocol layer with
      fakecore)

---

## P23 — Plan Stop closes the run's node session windows too

Question: "Does clicking Stop stop every session?" — design answer:
Stop stops every in-flight node session OWNED BY THIS plan's run (kill
the alayacore process AND close its window); it does NOT stop succeeded
nodes' sessions (keep them viewable), other plans' sessions, plain chat
sessions, or the Plan planner session.

Current state before P23: StopRun already marked nodes Canceled and
closeAndClear emitted CloseSessionFor (process kill, verified by the
existing runner test 'close:s1'), BUT the effect only sent
Ports.closeSession — the session WINDOWS stayed open as stale dead
windows, making Stop look like it didn't stop anything.

- [x] `applyEffectIn` `CloseSessionFor` now delegates to the full
      `update (CloseSession sid)` — kills the process AND removes the
      window (equivalent to the user closing it; history stays on disk
      and is restored on node click). Applies uniformly to runner-closed
      sessions (Stop / failure / cancel).
- [x] E2E step 8b: re-run (t3 hangs again after clearing the hang
      marker) → wait for t3's window → Stop → badge Stopped + t3 window
      gone; DOM clicks for Run/Stop (overlapping windows would
      intercept coordinate clicks)
- [x] Tests: elm 156 / Rust 42 / Go -race all pkgs / make e2e ALL PASS
- [x] Manual GUI: Stop mid-run → all running node windows close, plan
      badge Stopped — covered by e2e 8b (t3 hangs → Stop → window closed +
      badge Stopped)

---

## P24 — Replay suppression: move planReplaySessions old→new on resume

Bug report: opening a session whose history contains a plan message in
the MIDDLE (long completed; the last message is not a plan) still
auto-opened a plan window with ALL tasks Pending; opening the plan via
the manager showed the real (Completed) one — i.e. a duplicate.

Root cause: `resume_session` hands out a FRESH id (Y) while keeping the
ORIGINAL dir (X). `planReplaySessions` is keyed by X at resume-click
time, but the replayed history frames carry Y → `Set.member Y …` is
False → a mid-history plan message is treated as LIVE → R2 auto-create
fires → duplicate plan window (Pending) + duplicate plan file. The
suppression only worked for frames that arrived before SessionCreated
(those are buffered and applied without detection).

Fix:
- [x] `SessionCreated` (resume branch) MOVES the replay marker old→new:
      `Set.insert id (Set.remove origId planReplaySessions)`
- [x] Session Manager `ResumeSession` sets `planResumeFrom = Just id` so
      the same move happens for manager-initiated resumes
- [x] fakecore: on resume (session file exists) replay a canned
      plan-message history, with a 400ms delay (mirrors real alayacore:
      replay takes time → frames arrive after SessionCreated; without
      the delay they'd be buffered and the path never exercised)
- [x] E2E step 8 asserts: after close→click, exactly ONE plan window
      and ONE plan file (no duplicates). Verified the assertion FAILS
      with the fix reverted (3 plan windows) and PASSES with it
- [x] Tests: elm 208 / Rust 42 / Go -race all pkgs / make e2e ALL PASS

---

## P25 — Replay marker must NOT be removed on the first SM

Follow-up bug report: "opening session f36895fd still auto-opens its
plan" — P24 (id move) was NOT sufficient. Verified against the REAL
binary with a throwaway driver (`src-go/cmd/alayadump`, deleted after):
alayacore emits SIX boot SM frames first (`version`, `task`
in_progress:false, `model_list`, `model`, `reasoning`, `video_config`)
and ONLY THEN replays history content. The original assumption ("history
content frames BEFORE any SM") was wrong, so removing the marker on the
first SM dropped it before the replayed plan message arrived →
duplicate auto-created window (the user's exact symptom).

Superseded by P26 (the core now emits an explicit readiness signal).

---

## P26 — Replay marker removed on the core's `session/ready` SM

alayacore v0.62.4 adds `SM {"type":"session","data":{"state":"ready"}}`,
emitted AFTER all replayed history content (verified against the binary:
resume order = boot SMs → replay → ready; fresh boot = boot SMs →
ready). This is the authoritative "replay ended, interactive" signal —
replaces the P25 heuristic (remove on user SendPrompt).

- [x] `isSessionReady` (App/Update.elm): `ev.tag == "SM"` + systemMsg
      `type == "session"` + `data.state == "ready"` (reuses
      P.systemMsgDecoder)
- [x] `FrameEvent` removes `planReplaySessions` ONLY on the ready SM
- [x] `SendPrompt` no longer removes the marker — **NO fallback**: cores
      without the ready SM are unsupported (a resumed session's later
      live plan messages would never auto-create)
- [x] fakecore emits the ready SM after the replayed content (mirrors
      v0.62.4)
- [x] Tests: elm 208 / Rust 42 / Go -race all pkgs / make e2e ALL PASS
- [x] Manual GUI: open an old session with a plan message → no duplicate
      window; after ready, a live plan message still auto-creates —
      covered by e2e (resume replay does not duplicate the window + live
      plan auto-opens immediately)

---

## Known pitfalls

- Never edit `../alayacore` — tool set = spawn params only.
- JSON contract: snake_case returns, camelCase args, null keys must exist,
  error messages capitalized & identical across Rust/Go.
- `--builtin-tools` tri-state (P22): `null`/unspecified = preset default;
  "" as the EFFECTIVE setting = don't pass the flag = alayacore all-on;
  **explicit empty string = no builtin tools** (Plan Session used this so
  the planner cannot execute). create_session's `builtinTools` arg has three
  distinct meanings (`null` | `"a,b"` | `""`) — bridge.js must pass the
  empty string faithfully (never `|| null`).
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
