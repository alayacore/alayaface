# AlayaFace Plan Mode — Manual Acceptance Checklist (GUI Environment)

> **Core flow is automated**: `make e2e` (headless Chrome + fakecore fake model)
> already covers the whole chain of Plan Session → Create Plan → Run → node
> success/failure retry → opening a node's session (see TODO.md P15). The items
> left in this checklist are those **not covered by automation**: conversation
> quality with real alayacore + a real model, Tauri native windows, and MCP.
>
> Usage: when a desktop environment + a model API key (or a local .gguf) is
> available, smoke-test each item below and tick it off; write the results back
> to TODO.md.
>
> Prerequisites: `alayacore` executable (`which alayacore` or `ALAYACORE_BIN`),
> model API key configured (Default preset's model.conf), MCP currently
> disabled (`~/.alayaface/presets/Default/mcp.conf` fully commented out;
> re-enable = uncomment).

## Startup

- [ ] Tauri: `make run`; or browser: `make run-go` → http://127.0.0.1:8765/
- [ ] ⚙ menu shows: New Session / **New Plan Session** / Plans / Presets / Settings / Sessions

## 1. Plan Session + Creating a Plan (P2/P6)

- [ ] ⚙ → **New Plan Session** → session window title carries a `[Plan]` prefix
- [ ] Describe the task in natural language (e.g. "write a monthly report: first an outline, then three body sections")
- [ ] A fenced ```json plan block appears in the model reply → **Create Plan** button below the message
- [ ] Click Create Plan → Plan window opens (independent window, not an overlay), showing the DAG (nodes + dependency edges), goal, and metadata
- [ ] `~/.alayaface/plans/<name>-<ts>.json` saved (normalized version)
- [ ] ⚙ → Plans manager: **Saved** tab lists the plan (with fuzzy filter), can Open / Delete
- [ ] ⚙ → Plans manager → **Browse** tab: file browser (directory navigation + fuzzy match); clicking a plan JSON anywhere imports and opens a Plan window

## 2. Run + Node Session Content (P4/P7 fix points)

- [ ] Click **Run** in the Plan window → dependency-free nodes start first (parallel ≤ concurrency), further layers start as dependencies are satisfied
- [ ] Header "concurrency" input: empty = plan default; set 3 → at most 3 nodes in parallel; 0 or out-of-range auto-clamped to 1–8; re-Run after completion applies it too
- [ ] **Every node session must show its prompt and the model reply** (P7 fix: SendPrompt carries the text, no more empty windows)
- [ ] Title carries the `[Plan · planId/nodeId]` binding marker
- [ ] Session windows can be dragged/resized/closed; multiple plan windows don't interfere; ⚙ menu can raise one to front

## 3. Node Click ↔ Session Binding (P8/P9)

- [ ] Click a **live** node → its session window is focused
- [ ] Close a node's session window → click the node → automatically `resume_session` from disk, content complete (full UT/AT/AF/UF/AR history rendered)
- [ ] **Repeated open/close cycles** (close → click node → close → click node…) no longer report "Session directory not found"; after app restart clicking a node still recovers (P18: nodes are always bound to the on-disk dir id; live mapping goes through planResumedFrom)
- [ ] Failed/canceled node → click node → old session recovered via `last_session_id` for review
- [ ] **Connection curve (P19/P27)**: focus a node's session → plan window is raised to the second layer (session z = plan z + 1), a **solid, thicker (stroke-width 3)** bezier curve (two control points) connects the session window edge to the node card; the curve follows live when dragging/resizing/scrolling; closing the session or focusing elsewhere → curve disappears; node scrolled out of the canvas → curve hidden
- [ ] **Plan ↔ session curve (P27)**: focus (activate) the plan window → a second solid curve connects it to the session that created it, anchored on that session's `[Plan: <planId>]` button when visible (scroll it out of view → the curve falls back to the session window edge); focusing a session hides it (the node curve takes over); closing the plan window or its origin session hides it
- [ ] Node detail panel shows a "history sessions (N)" list → click a short id → opens **that** attempt's session (old attempts remain reachable after retry rebinds; opening an old session does **not** change the node's current binding)
- [ ] Reopen the app → open the plan → run.json silently restored → clicking a ran node reopens its session; the node detail "history sessions" list is preserved too
- [ ] **Load run** → restore and continue executing unfinished tasks

## 4. Failure & Retry (P4/P10/P11)

- [ ] Node preset set to a nonexistent name → creation failure no longer hangs (P11: failure shown on the node, can Retry; the whole run doesn't hang)
- [ ] Auto-retry: failure → node becomes Waiting (x2 badge) → auto-retry after 2s
- [ ] Press **Stop** during backoff → stays stopped; the late auto-retry does not revive the node (P10)
- [ ] Manual Retry: failed/canceled node → Retry button in the node detail panel → revived and rerun
- [ ] max_attempts reached → Failed, downstream Blocked (fixpoint propagation), run status FailedRun
- [ ] Creating a normal session (New Session) while a run is active → queued, not mistakenly bound to a runner node (P11 unified create queue)
- [ ] **Task timeout (P16)**: plan sets `default_timeout_seconds: 3` → a hung node fails after 3s ("Timeout after 3s") → auto-retry; plans without the field never time out; node `timeout_seconds` overrides the plan default

## 5. Working Directory Isolation (P16)

- [ ] After Run, `~/.alayaface/plans/<planId>/work/` exists
- [ ] `pwd` inside a node session = that work directory (model running `pwd`/relative-path file writes land inside work, not in the backend's startup dir)
- [ ] Two plans running in parallel cannot see each other's files
- [ ] Normal sessions (non-plan nodes) keep cwd = backend startup dir (backward compatible)

## 5b. Output Injection (P24)

- [ ] Generate a plan with a Plan Session: downstream prompt writes `based on {{t1.output}} ...` (downstream declares t1 as a dependency) → the model accepts the template
- [ ] After Run, click the downstream node to open its session → `{{t1.output}}` in its user message has **been replaced** with t1's actual final answer (no raw template residue)
- [ ] Node detail panel shows the node's Output (final answer for succeeded nodes; "no output recorded" for unsuccessful nodes)
- [ ] Referencing a nonexistent task id (e.g. `{{t9.output}}`) → the downstream prompt contains an English placeholder notice, not the raw template
- [ ] Reopen the app → open the plan → silently restore and re-Run unfinished tasks → downstream nodes still inject (upstream Succeeded nodes don't rerun; output restored from run.json)

## 5c. Session Directory Hierarchy (P27)

- [ ] After a Run, plan node sessions live at `~/.alayaface/sessions/<planId>/<nodeId>/<uuid>/` (config/ + session.alaya inside), NOT at the top level
- [ ] `~/.alayaface/sessions/` top level contains only plain (non-plan) sessions + plan subtrees — no plan child uuid directly
- [ ] Session Manager never lists plan child sessions (only plain sessions)
- [ ] Click a node (resume) after the app restarts → still reopens the session (nested dir found via planId/nodeId)

## 5. Graceful Close (P25 cancel-first)

- [ ] Closing an in-progress node session window → the task is **canceled** (not waited to finish) → process exits quickly (<3s, cancel → save → EOF sequence)
- [ ] After closing, `~/.alayaface/sessions/<id>/session.alaya` exists and **contains the conversation up to the cancel point** (after cancel, alayacore auto-saves via handleTaskDone; the `save` frame is a fallback)
- [ ] **Stop**: a Running node's task is canceled → node Canceled, process exits, window closes (no more "node keeps executing after Stop")
- [ ] Closing an idle session (no task) → session.alaya is saved too (`save` applies; cancel returns NOTHING_TO_CANCEL which is ignored, no side effects)
- [ ] Rapidly closing several sessions in a row → no leftover alayacore processes (`pgrep -f alayacore`)

## 6. Presets / Tool Sets (P4.5)

- [ ] Presets manager shows the 5 seed presets (Default/Fast/Deep/Data/Safe)
- [ ] Nodes running under the Safe preset never see execute_command (settings.conf builtin_tools applies)
- [ ] Node-level `tools` field override works

## Regression (non-Plan features unaffected)

- [ ] Normal New Session conversations work (no [Plan] prefix, no planner system prompt)
- [ ] Session manager / deleting sessions / restoring sessions work
- [ ] File picker, Settings editor (tool_confirm / builtin_tools) work

## Known Limitations (acceptance: confirm "as expected")

- Killing the app mid-task loses the in-flight turn (alayacore only saves at task end; C1 forbids modifying alayacore)
- Long tasks not finished within the 5s grace are still SIGKILLed (the save frame has already flushed first)
- Two plans opened within ~50ms of each other may interfere with the auto-restore chain (planReadTarget is single-slot)
