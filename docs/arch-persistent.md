# C Architecture: Immutable Value Model (Persistent Structure) — persistence semantics for sessions / plans / runs

> **Positioning**: this is the **replacement** for the P39 lineage architecture
> (user decision 2026-08: drop the temporary fix and do the correct
> architecture). Target mental model: functional-language persistent data
> structures — **naturally recursive, naturally shared, naturally isolated**.
> This document is the design blueprint; confirm each "confirmed decision"
> (§9) with the user item by item before implementing.

---

## 0. In one sentence

Turn "session / plan / run" from **mutable physical entities + shared identity**
(current state: one plan directory + a lineage registry + one global run
state) into **immutable values + structural sharing** (updates produce new
values, old values are kept, unchanged parts are shared, plan state is an
append-only immutable run log + a view pointer inside the session version).

---

## 1. Why the current state is unfixable (why redo it instead of patching)

| # | Root cause | Symptom (user-visible) |
|---|---|---|
| R1 | **Plan state is a plan-level global mutable object**: a single `meta.json.last_status` / `run.json`, shared by every session bound to it; `persistRunStatus` writes it | In an old session, plan A (unexecuted) shows "executed" in the status bar after a re-run; opening the plan window shows another session's run |
| R2 | **Fork = physical identity copy + lineage sharing**: new directory + `session.meta.json { conversation_id, parent_instance_id }`, bindings resolved by conversation | Top-level sessions share identity; links point across sessions; needs head/lineage tables, rebuilt on restart, patched everywhere |
| R3 | **Partial copy**: a re-run fork only replays the truncated history (`truncateHistory` to the plan JSON) | Not a "copy of the whole session" — cannot express "the old session is the pre-rerun world" |

The three root causes share one origin: **"mutable sharing" for sharing and
"identity copy" for isolation**. The correct approach is exactly the reverse:
**"immutable values" for isolation and "structural sharing" for sharing**.

---

## 2. Core abstractions (functional mapping)

| Desired property | Mechanism | Meaning |
|---|---|---|
| Natural isolation | **Immutability**: any "update" produces a **new value**, the old value stays untouched | An old session always sees its own version; plan completion/re-run never affects historical versions |
| Natural sharing | **Structural sharing**: the new value references the unchanged parts (message prefix, plan definition, run objects), zero copy | No bloat; the plan has one definition, runs are an append log |
| Natural recursion | **Structural recursion**: plan → node session (references a session value) → child plan (reference), the type definition recurses on itself | Child plans / node sessions are value references, not copied expansions |
| Local links | **Reference = in-structure pointer**: a link = (plan message inside the session value → plan value), state = the view pointer of that session version | A link always points "below itself" (the run its own version sees) |

---

## 3. Data model (conceptual layer, common to Elm/Go/Rust)

### 3.1 Immutable objects (content-addressed, reference = object hash)

```
PlanDef   — plan static definition (immutable): planId / name / tasks DAG / meta
Run       — snapshot of one run (immutable): runId / status / nodes / startedAt / finishedAt / summary
Version   — one version of a session (immutable):
            { messages : Seq MsgRef        -- persisted message sequence (prefix-shared)
            , planViews : Map PlanKey RunRef  -- the run each plan sees in this version
                                               -- (Nothing = not executed under this version)
            , parent : Maybe VersionRef    -- derivation source (version-tree edge)
            }
```

### 3.2 Reference layer (mutable, lightweight)

```
Plan    = { def : PlanDefRef, runs : Vec RunRef }        -- runs append (list of immutable objects)
Session = { id : String                                  -- stable identity (= creation id, never changes)
          , head : VersionRef                            -- current version
          , versions : Vec VersionRef                    -- version history/tree
          }
```

### 3.3 Key invariants

- **I1**: `PlanDef`/`Run`/`Version` are immutable once created (content-addressed, never mutated after write)
- **I2**: `plan.runs` only appends; `Run`s never modify each other (re-run = new Run, old Run kept)
- **I3**: a session's "state" is entirely determined by its `head` version; old versions are history (read-only)
- **I4**: a plan's "displayed state" = `Version.planViews[plan]` (**not** a plan-global field) — the same plan has different states across versions, naturally isolated
- **I5**: `Session.id` is stable, with **no** conversation/instance split (the identity layer eliminates lineage)

---

## 4. Update semantics (each operation = one immutable update)

### 4.1 Plan runs (workspace → freeze)

- While running it is a **workspace** (mutable, UI-interactive: node states, output streams)
- On completion/stop/failure, freeze an immutable `Run` snapshot → append to `plan.runs`
- Freeze points: completion, failure, stop, re-run start (old runs are never deleted)

### 4.2 Plan completion write-back (core: result inserted back into parent)

```
Old version V₀: messages = P ++ [PlanMsg A] ++ R      (P=prefix, R=content after plan)
New version V₁: messages = P ++ [PlanMsg A] ++ [Feedback A]   (prefix P structurally shared)
           planViews = V₀.planViews ⊕ { A → newRun }
           parent    = V₀
head := V₁
```

- Prefix P is **shared** with V₀ (one immutable message block, no copy)
- R (the replaced part) exists only in V₀ → the old version naturally keeps the truncated content (undo/history for free)
- **No fork, no new session directory needed**: the same `Session`'s head switches from V₀ to V₁

### 4.3 Re-run plan A (branch semantics, old session preserved)

The user re-runs A from some version → derive a **new branch**:

```
V₁  = derived from current head V₀: messages = anchor prefix ++ [new result], planViews ⊕ { A → newRun }
head := V₁    (the current session's head updates)
V₀  kept      (= the "old session": A unexecuted, status bar NotStarted)
```

- **Key difference from the current state**: a re-run **is** updating the current session's head to a new version; the old version V₀ is history of the **same** `Session` (viewable/revertible from the session manager)
- If the user wants "after a re-run, open a new window and leave the old window untouched": a `Session` twin = **another head pointer to V₀** (zero copy, two references), not a data copy — a window is just "a view of some version"

### 4.4 Recursion (child plans / node sessions)

```
Plan's Run.nodes[nodeId].session = the node session's VersionRef (reference)
A child plan created in a node session → the child plan is a value reference (PlanRef)
Child plan completes → the parent plan node's run freezes a new snapshot → the parent session version updates (same recursive mechanism)
```

- Recursion is at the **value level**, not the physical-directory level — no "recursive copy" problem (the fundamental flaw of the copy approach the user rejected)

### 4.5 Cascade re-run

- A cascade = **a chain of version updates** propagating up the version tree (parent plan node re-answers → new Run → parent session new version → grandparent…)
- Semantics match the P39 state machine, but the carrier changes from "fork handoff" to "version derivation" — no physical handoff, no ordering assumptions

### 4.6 Undo / history

- `Session.versions` IS the version tree: any version can be viewed (read-only); restore = point head back at an old version (pointer operation, zero data operation)
- "Continue editing based on an old version" (checkout semantics) → materialization capability (§6.3, open item)

---

## 5. UI model

| Component | Current state | C |
|---|---|---|
| Session window | bound to a physical instance (lineage head resolution) | bound to `(Session.id, versionRef)`; current head editable, old versions read-only views |
| Status bar (plan) | `planMetaForMessage → planId → global run state` | `Version.planViews[plan]` → run state (**version-isolated — the core fix**) |
| Plan link | (conversation, planIndex) → planId | (plan message inside the session value) → PlanDef ref; opening the window shows the run that version saw |
| Plan window | one global window (by planId) | window = (plan, versionRef) view; can show the full run history + highlight the current version pointer |
| Re-run result | fork opens a new window + lineage | current session head updates (or twin view); no window jump |
| Session manager | lists physical instances | lists `Session`s (stable id) + version count / current-version mark |

---

## 6. Storage and backend boundary

### 6.1 Object store (content-addressed, git-style loose objects)

```
~/.alayaface/objects/<sha>/          # hash → immutable object (version / run / plandef / msgblock)
~/.alayaface/sessions/<id>/          # session directory (kept as alayacore's work copy)
    session.alaya                    # held by alayacore = the current head's work copy
    session.refs.json                # frontend: id / head pointer / versions list (references objects/)
    plans/<planId>/                  # plan directory
        plan.json                    # PlanDef (immutable, never touched after write)
        runs/run-<runId>.json        # Run snapshot (immutable, append-only)
        index.json                   # runs list + meta (reference)
```

- hash = content hash (sha256), computed by the **backend** (Go/Rust symmetric, see C2)
- The frontend only holds references (hashes); object reads/writes go through fs RPC (`object_put` / `object_get`, implemented by both backends symmetrically)

### 6.2 Boundary with alayacore (NEVER modify AlayaCore)

- `session.alaya` stays alayacore's **work copy** (the current head's mutable materialization)
- Version boundary (plan completion / re-run / manual archive): the frontend freezes the current work copy's **message content** into an immutable `Version` (object store) — the frontend already has the full message list (in memory), it only needs the backend to persist it
- Viewing an old version: **render the object-store snapshot** (read-only), never touch alayacore
- Continue editing on the current head: the alayacore work copy works as usual (message updates reuse the existing sendPrompt/truncate channel; but **truncation** changes to: after materializing a new version, the alayacore side still needs the messages actually deleted → keep the fork command as the "work-copy materialization channel" (current state, D2), but the **identity layer no longer needs lineage** — the forked files are just a work copy of the head version, not a new identity)

### 6.3 Materialization (open item)

"Continue editing based on an old version" (checkout) requires materializing the old version's immutable messages into session.alaya:
- Our backend can generate the alayacore format (fakecore has proven the format is readable/writable; the real format needs verification)
- Plan: backend `materialize_session { versionRef → sessionFile }` command (Go/Rust symmetric)
- **C first release can skip it** (read-only old versions already satisfy the isolation/sharing/recursion goals); materialization becomes an independent C4 component

---

## 7. Migration (existing data)

1. For each existing session: freeze the current session.alaya + every plan's meta/run into a **first Version** (planViews taking the state at that time) → initialize `session.refs.json`
2. Existing lineage (session.meta.json): **deprecated** (no longer read/written; old files may be kept as archives)
3. fork/head/resolveConversation/lineage-related code: **deleted**
4. After migration, all updates go through the new model (version derivation)
5. Verify: existing e2e (plan/restart/fork/two-plans) rewritten as version-semantics assertions

---

## 8. Implementation phases (each independently verifiable and committable)

> Phases depend on each other in order; run the full verification suite per phase (elm-test / go / cargo / parity / e2e).

- **C1 — value types + object store** ✅ done
  - `PlanDef`/`Run`/`Version` types (Elm) + backend `object_put/get` (Go/Rust symmetric + tests)
  - `session.refs.json` codec; version freeze (on plan completion, freeze the work copy into a Version)
- **C2 — versioned plan state (the core fix for this bug)** ✅ done (C2a)
  - `Version.planViews` + status bar/window resolution by version
  - Re-run = version derivation (old version kept, old session shows old state)
  - **Verify**: user bug-scenario e2e (old session A stays unexecuted)
- **C2b — session ownership (window = Session view + work-copy mapping)** ✅ done (§8.1)
- **C3 — recursion and cascade under the value model** ✅ done (§8.2)
  - node sessions / child plans reference version values; cascade = version-chain propagation
  - cascade fork handoff removed (state-machine semantics kept, carrier changed to versions)
- **C4 — UI and history** ✅ done (§8.2)
  - version browsing (session manager shows versions/history/revert)
  - materialization capability (optional, open item §6.3)
- **C5 — cleanup** ✅ done (§8.2)
  - delete lineage registry / headInstanceFor / resolveConversation / fork adoption
  - delete P39-era compatibility patches; REFACTOR.md archived to docs/archive/

---

## 8.1 C2b design: session ownership (thought through; user confirmed "think first, then act" 2026-08)

### Goals (D3/D9 landing)

1. **Window = Session view**: the window key is ALWAYS `Session.id` (= the session id at plan creation, stable). Fork/resume only swap the **work copy**, never the window identity.
2. **Work-copy mapping**: `sessionWorkCopies : Dict SessionId CoreId` (Session.id → current alayacore session id).
3. **Delete lineage**: no more conversation/instance split; `resolveConversation`/`headInstanceFor`/`sessionLineage` all removed.

### Core invariants

- **I-A**: `Session.id` = the session's first alayacore session id (root). **Never changes.**
- **I-B**: windows (sessionOrder / sessionNums / windowPositions / activeId / sessions Dict keys) = **Session.id** (**final architecture, plan A**: UI state organized by UI identity, not compromised by "change surface" — the work copy is just a boundary detail).
- **I-C**: `sessionWorkCopies[Session.id]` = the current work-copy coreId. Without fork/resume = Session.id itself (**the mapping may be absent**: lookup miss → itself).
- **I-D**: frame routing: coreId → Session.id (reverse-lookup workCopies; miss → itself) → update `sessions[Session.id]`.
- **I-E**: commands (sendPrompt / cancel / setModel / closeSession / scroll): `Session.id` → `workCopyId` (forward lookup in workCopies; miss → itself) → coreId.
- **I-F**: bindings (`planMetaForMessage` / `messageBoundToPlan`): **match planMetas origin directly by Session.id** (resolveConversation step removed) — plan origin is ALWAYS Session.id.
- **I-G**: `sessions` **never** contains "multiple coreIds belonging to one Session" — each Session has exactly one entry (the entry content is replaced/frame-taken-over on work-copy switch; the old coreId's entry is removed).
- **I-H** (robust): **explicit work-copy lifecycle** — creation (fork/resume) → close (delete the old directory when a fork replaces it; closed with the ownership graph when the Session closes); failure (process dead/directory lost) → detected and reverted.

### Per-path design

**1. Plain creation (New Session / node session)**
- `SessionCreated(coreId)`: Session.id = coreId (first work copy = itself; workCopies unset or set coreId→coreId); sessions[coreId] = initial; window key = coreId. **Unchanged from the current state.**
- At creation, initialize `session.refs.json` (empty version, head="") → **having refs = Session root** (the manager's listing basis; the restart-recovery basis).

**2. Re-run fork (core)**
- On confirm, freeze V₀ (C2a already does this).
- `PlanCascadeForkResult` → nested `SessionCreated(S')`: **fork branch**:
  - `sessionId = plan origin (meta.origin.sessionId = Session.id)` — **NOT `target.forkSource` (that is the live work copy, which may have resume differences)** ← this is the concrete bug C2b exploration hit (using forkSource as Session.id misaligns after resume → binding fails "Open plan").
  - `sessionWorkCopies[Session.id] = S'` (new work copy).
  - **sessions[Session.id] = S'`s initial content** (sessionsAfterBuffer, including the buffer's fork-replayed frames; empty if none).
  - Window key stays Session.id (sessionOrder/sessionNums/windowPositions untouched; **forkInheritPos deleted** — the window did not change keys, so position is naturally preserved).
  - `planReplaySessions` marks **Session.id** (replayed frames route to Session.id consistently).
  - No lineage written (session.meta.json write removed).
- `RegisterFork` effect (`registerForkInstance`) rework:
  - **Only close the old work-copy process**: `Ports.closeSession { sessionId = the old value of workCopyId(Session.id) }` (bare port, no frontend session entry cleanup — the old coreId entry is kept until overwritten by new frames? **or**: after closing the process, the old coreId entry is cleaned up by the CloseSession event — **design**: the fork branch already overwrote sessions[Session.id] with S' content; the old coreId entry (sessions[old coreId]? — **under plan A sessions keys = Session.id, the old entry IS sessions[Session.id]** — **already overwritten** — **so the old coreId (= original Session.id or original workCopy)** — **just close the process, no frontend cleanup**) ✓.
  - Clear `planCascadeFork`; close child plan windows (already queued at confirm time).
- Cascade-completion freeze (skipped in C2a, added in C2b): `freezeSessionVersion Session.id (messages = sessions[workCopyId(Session.id)])` — freeze V₁ (A executed) → head = V₁. Old V₀ kept.

**3. Resume (session manager / node)**
- `ResumeSession(Session.id)` → `resume_session` (backend restores from the disk file; **from the Session root's session.alaya? or the work-copy directory?** — see "restart").
- `SessionCreated(liveId)` resume branch:
  - `sessionWorkCopies[Session.id] = liveId` (new work copy).
  - sessions[Session.id] = liveId's initial content (buffer).
  - Window key = Session.id (the current resume branch keeps the window key as origId? — **confirm**: the current resume branch does `Dict.insert id` with liveId as a new entry — **C2b changes it to**: window key = Session.id (origId), no new entry).
  - `planReplaySessions` marks Session.id.
- **Node session resume** (PlanOpenNodeSession): node sessions are not top-level Sessions — **handled in C3** (C2b focuses on top-level).

**4. Frame routing** (Delta/Frame/Status/RpcError)
- `sid = sessionIdOfWorkCopy model ev.sessionId` (reverse-lookup workCopies; miss → itself) → `Dict.get sid model.sessions` → update sessions[sid], planMessageCounts[sid], planReplaySessions by sid.

**5. Commands** (SendPrompt / CancelTask / SetModel / ConfirmTool / McpCancel / scrollToBottom / Dom.focus)
- All `Ports.sendPrompt { sessionId = ... }` etc.: `sessionId = workCopyId model Session.id` (forward lookup in workCopies).
- `CloseSession(Session.id)`: close the **work copy** process (`workCopyId`) + frontend cleanup (remove Session.id from sessions, windows, workCopies; close the plan ownership graph).

**6. Bindings** (planMetaForMessage / messageBoundToPlan / findPlanIdBySession)
- Remove the `resolveConversation` step: `convId = sid` (Session.id) → planMetas[(Session.id, planIndex)].
- **Node session** bindings (findPlanIdBySession): C2b keeps the current logic first (node session's lastSessionId/conversationId matching); C3 unifies.

**7. Session manager**
- Lists disk directories: **having `session.refs.json` = Session root** (shown); no refs = work copy / uninitialized (not shown).
- Resume: `ResumeSession(Session.id)` → restore the work copy (see "restart").

**8. Restart recovery**
- Scan: read each directory's `session.refs.json` → Session root + head version (C2a already). **Also read the workCopy record.**
- **Work-copy record**: on fork/resume, write the current work-copy directory id into `session.refs.json` (new field `"workCopy": "<coreId>"`) → after restart: resume Session **restores the work-copy directory's session.alaya** (it is the head's materialization) → `workCopies[Session.id] = resume liveId`.
- **Old versions read-only** (D8): user revert/view of old versions = rendering object-store snapshots (C4).

**9. Close / delete**
- `CloseSession(Session.id)`: close the work-copy process (workCopyId) + clear the Session entry + ownership graph (plans/nodes/child plans).
- `DeleteSession(Session.id)`: delete the Session root directory + the work-copy directory (object-store objects can remain for GC — open item).

### Exploration findings (located pitfalls)

- **Pit 1 (fixed)**: the C2b first version treated `target.forkSource` (the live work copy) as Session.id — after the session is resumed, live ≠ creation id → window key misaligned → `planMetaForMessage` matched by the wrong key → status bar "Open plan". **Fix**: Session.id = plan origin (`meta.origin.sessionId`); forkSource is only the work copy.
- **Pit 2 (to check)**: in the fork-e2e flow, S may be resumed (producing an extra live id) — source not located (possibly the run-restore path of `openPlanFile`). Once C2b is correctly implemented (window = Session.id) it **does not affect correctness** (the resume live is just a work copy), but needs unit tests to lock down.

### Robust design (failure paths handled explicitly)

| Scenario | Handling |
|---|---|
| **Work-copy process dies / directory lost** | backend close/process-death event → if that coreId is a Session's work copy (a workCopies value) → mark `workCopyLost` (UI hint "work copy invalidated, can be restored"); the Session entry stays (refs/versions still there); restore = resume (rebuild the work copy) |
| **Orphan work-copy directory** | after a successful fork, delete the **previous work-copy directory** (except the Session root): `delete_session_dir` (already in the backend) → disk always has only the Session root (identity + refs) + the current work copy; a failed delete is only archived (GC as backstop) |
| **Stale workCopy record** (the directory refs.workCopy points to was deleted) | on resume, try the workCopy directory first; if missing → fall back to the Session root directory (possibly old content; UI hint "restoring the old work copy"); if that fails → error (user can delete the session and recreate) |
| **Fork idempotency** | each fork produces exactly one SessionCreated (driven by PlanCascadeForkResult, backend does not broadcast — confirmed); unit tests lock "one creation, window key assigned exactly once" |
| **refs write failure** | version-freeze failure → status-bar fallback (C2a already); does not block running |
| **Resume race** | a resume liveId's frames arriving before workCopies is set up → bufferPendingEvent (by coreId); after SessionCreated (resume branch) sets up workCopies, flush → sessions[Session.id] |

### Implementation steps (each verifiable and committable)

1. **C2b-1 infrastructure** ✅: `workCopyId`/`sessionIdOfWorkCopy` (exported from Plan/Update.elm) + Model.sessionWorkCopies; unit tests (forward/reverse mapping, missing-mapping fallback, multi-fork reverse lookup). Commit `cb19499` (three remotes).
2. **C2b-2 binding simplification** ✅: `messageBoundToPlan`/`planMetaForMessage`/`versionPlanStatus` drop `resolveConversation` + `planResumedFrom` resolution, matching directly by Session.id — unit tests (plain/resume/fork binding scenarios: the work copy only goes through sessionWorkCopies, bindings never look at it). Commit `84f6da5`.
3. **C2b-4 frame routing + command mapping** ✅ (implemented before C2b-3 — empty mapping is identity, independently committable): Delta/Frame/Status/RpcError route via `sessionIdOfWorkCopy` (scrollToBottom uses Session.id — the DOM window key); SendPrompt/CancelTask/SetModel/ConfirmTool/MCP*/modelSync/closeSession go via `workCopyId`; `applyPendingEvent` takes a sid routing parameter; `sessionIdOfWorkCopyDict` extracted. Commit `f7ace5b`.
4. **C2b-3 fork branch fix** ✅ (depends on C2b-4 routing, hence implemented after it): SessionCreated dispatches by `isPlainCascadeFork` — top-level forks go through `forkSessionCreated` (window key stays Session.id = plan origin; workCopies[Session.id] = forkId; sessions[Session.id] overwritten with the fork content; planReplaySessions marks Session.id; no window entries / no lineage); `registerForkInstance`'s top-level branch only closes the old work copy (= Session root → closeSession only; earlier fork → deleteSessionDir close+delete) + clears planCascadeFork + closes child plan windows; cascade-completion freezes V₁ (on PlanCascadeForkResult takeover, freezeSessionVersion Session.id, parent = V₀); event guard `isCurrentWorkCopy` (late frames/disconnects from the old work copy don't pollute the new entry). `forkInheritPos` kept for node forks (deleted in C3). The original SessionCreated body is extracted into `createSessionWindow` (line-for-line identical, pure reindent). Commit `ed1ce70`.
5. **C2b-5 resume ownership** ✅: `SessionCreated` dispatches by `isTopLevelResume` (planResumeFrom set and planResumeOwner empty) — `resumeSessionCreated` (window key = Session.id = the on-disk directory id; workCopies[Session.id] = liveId; sessions replayed by routing; if the window is closed, create entries as usual); `AV.SessionRefs` gains `workCopy : Maybe String` (lenient encode/decode + unit tests); the freeze writes refs.workCopy via `persistableWorkCopy` (fork directory = forkId / resume live = keep the old value / root = Nothing), FreezeState carries workCopy through to the refs write. Commit `a2b93f4`.
6. **C2b-6 manager + restart** ✅: plain top-level creation initializes empty refs (sessionRefs in memory + refs.json on disk, head=""); the session manager only lists Session roots (filtered by sessionRefs membership; work-copy directories not shown); `ResumeSession` restores the `refs.workCopy` directory (fallback to the Session root — the backend live session's SessionDir = the on-disk directory, reading/writing the same session.alaya, so refs.workCopy is always valid); `DeleteSession` deletes the work-copy directory too + clears sessionRefs/workCopies. Commit `a3354a3`.
7. **C2b-7 delete lineage** ✅: `Session/Meta.elm` + `SessionMetaTest` deleted; `Model.sessionLineage`/`planMetaNodeMetaQueue` fields removed; the scan only reads refs.json (no longer reads/writes session.meta.json); `resolveEventSessionId` simplified to planResumedFrom only (no registry); `headInstanceFor`/`resolveConversation`/`headOf`/`forkMetaPath` all deleted (nodes/top-level resolve directly by origin = Session.id); Cascade closePlans/impactScope/walkLevels match by origin; registerForkInstance's node branch no longer writes lineage; `planRunningForSession`/`findPlanIdBySession`/`PlanBindSession`/`connectionChainForPlan` bind directly by session id; tests rewritten (418 green). Commit `7a1b955`.
8. **e2e rewrite** ✅ (`fork-e2e`/`two-plans-e2e` rewritten; restart/plan compatible): fork-e2e asserts C2b semantics — same window (window key = Session.id, position unchanged, no new entries), disk ownership (root + refs.workCopy = fork directory, work copy has no refs, no session.meta.json), after restart the manager lists only roots + resume restores the work copy, chained forks advance the work copy + old directories deleted; two-plans becomes a disk-level version-isolation assertion (V0: A unexecuted/B completed vs V1: A completed). **Found and fixed during implementation**: ① the re-run fork's source session id used the window key (Session.id), causing backend `Session not found` after resume — changed to `workCopyId` (same for feedbackCompletedPlan/forkOrInsertInPlace/InsertInPlace delivery targets); ② a resume live was mistakenly written into refs.workCopy as a fork directory — added `sessionResumedLives` to explicitly track temporary lives; ③ deleting the old work-copy directory raced the old process's graceful close (save writing back to SessionDir) recreating the directory — deferred 2s via the `DeleteWorkCopyDir` message; ④ the old work-copy directory = refs.workCopy's old value (no longer decided by planResumedFrom).

---

## 8.2 C3/C4/C5 completion record (wrapping up the value-model landing)

### C3 — recursion and cascade under the value model ✅
- **C3-1 node cascade forks unified as work-copy replacement** (commit `123c33b`): every cascade fork (top-level + node) goes through `forkSessionCreated` — window key = Session.id (= plan origin), workCopies[sid] = forkId; `registerForkInstance` unified to only closing the old work copy (`DeleteWorkCopyDir` carries the nested locating params); **"cascade fork handoff" deleted** (node forks no longer open a new window / no CloseSession dispatch); `planEventFromFrame`/StatusEvent runner injection route via `sessionIdOfWorkCopy` (node bindings = Session.id still hit after fork/resume); `forkInheritPos` deleted.
- **C3-2 node work-copy persistence + restart recovery** (commit `123c33b`): node cascade forks write a nested `session.refs.json` (workCopy = forkId); the scan reads nested node refs; `PlanOpenNodeSession`/`ResumeSession` restore via `resumeDirFor` (refs.workCopy, fallback to the original directory).
- **C3-3 full versioning of node sessions (skipped)**: a node session's "world isolation" is already covered by the top-level V0/V1 versions + the work copy; a full version tree is low value, and C4 version browsing focuses on top-level.

### C4 — UI and history (version browsing) ✅ (commit `d496f6d`)
- `blockCache` (hash → messages) + version-browsing state; `ObjectGetResult` decodes a Version or Block (reqId = hash); viewing a version auto-fetches the missing blocks.
- The session manager entry gains a **Versions (n)** button → version list (v0/v1/… + head mark) → read-only version view (messages + plan status rows, from planViews/runSummaries). D8: old versions read-only, no materialization.

### C5 — cleanup ✅ (commit `f809469`)
- **C5-1 node resume unified**: every resume (top-level + node) goes through `resumeSessionCreated` (window key = Session.id + chain building); the createSessionWindow resumedModel branch removed; the **`planResumedFrom` field deleted** (39 sites) + `resolveEventSessionId`/`findResumedLive`/`onDiskSessionId`/`NC.liveSessionForOrigin`'s resume parameters all removed (identity).
- **C5-2 docs archived**: root `REFACTOR.md` (P39) → `docs/archive/REFACTOR-p39.md`; `TODO.md` → `docs/archive/TODO-p39.md`.
- C2b-7 already deleted lineage; the P39 compatibility patches were removed item by item across C2b/C3/C5.
3. **C2b-3 fork branch fix**: SessionCreated's fork branch uses `meta.origin.sessionId` (Session.id) as the window key + workCopies; `registerForkInstance` only closes the old work copy (bare closeSession) + clears planCascadeFork; forkInheritPos deleted; cascade completion freezes V₁; **delete the old work-copy directory after the fork**.
4. **C2b-4 frame routing + command mapping**: coreId → Session.id; commands Session.id → coreId.
5. **C2b-5 resume ownership**: resume branch workCopies[Session.id] = liveId (window key stays Session.id); `session.refs.json` gains the workCopy field.
6. **C2b-6 manager + restart**: manager filters by refs; restart restores the workCopy (with fallback).
7. **C2b-7 delete lineage**: sessionLineage / headInstanceFor / resolveConversation / SM.decode / session.meta.json reads+writes all deleted.
8. **e2e rewrite**: fork-e2e assertions (no new session entries, stable window key, bindings work, v2 display); two-plans (old-session isolation kept); restart (workCopy restored).

---

## 9. Confirmed decisions (to be approved item by item by the user; do not change after approval)

| # | Decision | Status |
|---|---|---|
| D1 | **Stable identity**: `Session.id` is stable (= creation id), eliminating the conversation/instance split and the lineage registry | ✅ confirmed |
| D2 | **Version = history**: plan completion/re-run = the current session's head updates to a new version; old versions stay in `Session.versions` (viewable/revertible from the session manager) | ✅ confirmed |
| D3 | **Re-run = branch derivation + another view of the same session**: derive a new version from the current head (structural sharing); "new window" = **another head view of the SAME Session** (zero copy), no physical new session | ✅ confirmed |
| D4 | **Plan state = in-version view**: `Version.planViews[plan]`; the same plan has different states across versions (an old session naturally shows the old state) | ✅ confirmed |
| D5 | **Run immutable append**: `plan.runs` only appends; re-runs never delete old runs | ✅ confirmed |
| D6 | **Object store**: content-addressed (backend hash), objects/ + refs.json | ✅ confirmed |
| D7 | **alayacore boundary**: the work copy stays an alayacore session; truncation still materializes the work copy through the fork command, but with **no identity semantics** (the new files are just a work copy of the head, no lineage registration) | ✅ confirmed |
| D8 | **Old versions read-only**: C first release does no materialization (checkout); old versions are view-only | ✅ confirmed |
| D9 | **Delete**: lineage registry / headInstanceFor / resolveConversation / fork adoption / planCascadeFork / replay markers / P39 compatibility patches | ✅ confirmed |

---

## 10. Open questions (need user decision or later research)

1. **Window model**: after a re-run, how do the "old window" and "new window" present — two head views of the same Session? Or does the re-run update in place in the original window (old versions reachable only from the session manager)? (Affects the D3 UX detail)
2. **Version granularity**: freeze versions only on plan completion, or also at key points while running (more history/undo capability, more storage)?
3. **Object-store compaction**: git-style pack/GC (long term); loose objects are fine for the first release
4. **Materialization format verification**: can the backend generate the real alayacore session.alaya format (pre-C4 research, verify with a real binary)
