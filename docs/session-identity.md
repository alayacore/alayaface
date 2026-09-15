# Session identity — a name for a session, and how to find it again

**Status: the G-series is LANDED (G0 + G1 2026-09-14, G2 + G3 2026-09-15). A name is
derived, stored, read back, folded into the model, shown in a window's title bar and a
manager row, editable from that row, filterable, and proved end to end by
`e2e/label-e2e.mjs`.** Every checklist box below is ticked; what is left is in
"Later" (proposals, not plans). The ⚑
questions were put to the human on 2026-09-14 and
every one was answered **"as recommended"**, so SD-G12 … SD-G15 below are confirmed
decisions. Do not re-litigate an SD row in code: change the row here first and say so
in the commit message, per the repo's convention.

This is the tracked design for the **G-series**. When a phase ships, its checklist
items get ticked here (this file is tracked — a phase list in a file nobody tracks is
how a finished feature gets re-opened by the next reader).

> Anchored at commit `541461e`. **Line numbers drift — treat function names as the
> anchor and re-`grep` before editing.**

## The problem

The board is persistent now (F3): a restart puts every window back where the user left
it, keyed by session identity. What it does not put back is *what each window was*.

- A plan names itself. `Plan.name` (the JSON the model produces) reaches the title bar
  through `planName` in `App/View.elm`'s plan panel: `"Plan — " ++ planName`. A session
  has no such field.
- A session's title is `"Session " ++ String.fromInt idx`, where `idx` comes from
  `Model.sessionNums` — filled from `nextSessionNum`, and `Main.elm`'s `init` starts
  that at **1**. Numbers are allocated in creation order while a page is alive, and in
  **restore order** after a reload (the `resumeSessionCreated` arm is the same
  allocation site). So "Session 3" today is "Session 1" tomorrow. The number is a
  per-process seat assignment, not a name.
- The Session Manager's row shows `String.left 8 dir.id`: eight hexadecimal characters
  of a UUID that is never reused and never means anything to the user. `createdAt` is
  below it; the preset is fetched and thrown away (see "Rot" below).

So after a month of use the user has: a board of windows whose numbers changed, and a
manager listing hex prefixes. Nothing in the product lets them say "this one is the
refactor of the parser" — and F3 made that *more* visible, because the board now
survives, so the missing names survive too.

## Scope

**In:** a per-session label, derived automatically from the first prompt, editable by
the user; the label reaching every surface that identifies a session (window title bar,
Session Manager rows, the tooltips on both); a filter box on the Session Manager;
sort by name.

**Out (explicitly):** searching message *content* across sessions. The only content
AlayaFace owns is what a freeze put in the object store, and freezes happen at version
boundaries (plan completion / re-run / manual archive — `docs/arch-persistent.md` §6),
so a content search would silently miss every live session and every never-frozen one.
A search whose coverage is undefined is worse than no search. It becomes possible once
a session's messages are indexed on close, which is its own decision; do not smuggle it
in here. Also out: per-plan renames (a plan's name comes from its JSON, and renaming
one would fork its identity from the file on disk), tags, colours, folders, pinning,
and any keyboard entry point (see INV-G4).

## Where a label lives

The file is `sessions/<Session.id>/session.label.json` — one per session identity,
written by the **client**, read by the **backends**.

| SD | Decision | |
|---|---|---|
| **SD-G1** | The label is keyed by the **session identity**, and its home is the identity's **root directory** (`sessions/<Session.id>/`), not the work copy. | That is exactly where `session.refs.json` lives (`App/Arch.elm` builds the path as `sessionsDir homeDir ++ "/" ++ sessionId ++ "/session.refs.json"`). A fork changes `refs.workCopy`, not `Session.id` (C2b: a plain fork keeps the window key and the identity), so **a name survives a fork for free** — no copy, no inherit rule, no second editor. It also matches what the user believes: a fork is the same conversation continued differently. |
| **SD-G2** | The home is **not** `ui.conf`. | `ui.conf` is the *layout* document and its entries are **evicted**: `UiConfig.evict` drops closed entries oldest-touched first past `maxStoredWindows` (200), and both backends refuse an oversized document. A name that vanishes because the LRU needed room is invisible data loss. It is also the wrong subject — SD17's rule is that the layout document holds geometry only. |
| **SD-G3** | The home is **not** `session.refs.json`. | `Arch.Values.decodeSessionRefs` is a strict `D.map4` — a missing field means the shape changed, by design. refs is Arch's head pointer + version list, written by `App/Arch.elm` at the end of a **serial** freeze queue. A rename must never contend with a freeze, and a user-visible string does not belong in an append-only history pointer. |
| **SD-G4** | The home is **not** `session.spawn.json`. | Tempting — it is already per-session, already read by `list_session_dirs` (`dirs::read_spawn_args(&path).preset`), already has a shared fixture. But the **backend owns that file**: it writes it at create and at fork, and `resume_session` re-applies it as the capability envelope. A file the user edits must not be a file the spawn path overwrites. |
| **SD-G5** | The file is named for its **document**, not for one field of it, and the schema is owned by one client module (`src-elm/src/Session/Labels.elm`) in the *schema owner* shape (like `App/UiConfig.elm`, `App/AsrConfig.elm`, `Session/ModelConfig.elm`). | The name is `session.label.json` because the document *is* the label: `{ v, label, auto }`. A future note/tags/pinned field is a **different document** (different write trigger, different lifetime), not a new key here — which is the test that keeps a per-session file from becoming a second `settings.conf`. `v` lets a newer reader tell an older shape from a corrupt one; a newer file through an older backend still reads (extra keys ignored on read, and the client's whole-document write is its own). |
| **SD-G5b** | The feature has **two** client modules: `Session/Labels.elm` owns the document (types, decode/encode, `normalise`, `autoFromPrompt`, `usableText` — pure, no `App.Types`), and `App/Labels.elm` is the model-aware policy (fold the listing, decide when to write, `withLabelSave`). The Model's map value is the **name string**, not the document. | The shape is F3's (`App/UiConfig` + `App/UiLayout`) and the reason is ordinary: the policy needs `Model` (`sessionLabels`, `planNodeSessions`) and the document codec must be testable without one. **A correction, stated because this document's first draft got it wrong:** it claimed the split was FORCED by the cycle rule "once `Model` has a `Label` field". G1 found no reader for the flag in the model — the listing answers with a name, and SD-G8's guard is "an entry exists", not "the entry is user-chosen" — so `sessionLabels : Dict String String` and the cycle rule does not bite. Keeping `auto` in the map would have been a field nothing reads (the zombie state F4.1 deleted). The split survives because it is the right one, not because a compiler demanded it. |
| **SD-G6** | Labels reach the client through the **typed `list_session_dirs` RPC**, which grows a `label` field — not through `fs_read_file_text`, and not through `Plan/MetaScan`'s startup walk. | The fs ports are shared traffic routed by reqId (AGENTS.md "Routing: tagged fs ports"), and the scan reads **one file at a time**, so N labels = N more serialised round trips and a second queue in a machine that already has four. The RPC already iterates every top-level session dir and already parses a JSON file per dir. One call, one payload, no new routing hazard. |
| **SD-G7** | `OpenSessionManager` is currently the only caller of `listSessionDirs`. A **startup fetch** is added. | Without it the title bar knows no label for a session restored from disk, and the feature would name sessions only in the screen the user is least likely to be looking at. The fetch is untagged and fire-once per request, which the AGENTS.md routing note already classifies as safe (`sessionDirsResult` is in that list). |
| **SD-G8** ⚑1 | The label is **auto-derived from the first prompt** and persisted then, unless a label already exists. `auto: true` marks it as machine-derived; any user edit sets `auto: false` and nothing in the client ever writes over `auto: false`. | Without this the feature ships empty: nobody renames 30 existing sessions by hand. The first user message is already in the client's hands at send time, so the derivation costs one small write per session, once. Old sessions keep the hex/id fallback until they are named — stated plainly so nobody is surprised, and see "Later" for the backfill idea. |
| **SD-G9** | Reader is **lenient and drops**, never clamps: a `session.label.json` that is absent, unparseable, missing `label`, empty-after-trim, or longer than `maxLabelChars` yields *no label*, and the fallback chain decides what to show. It returns `label` **verbatim** — trimming decides *presence* only, never the bytes shown. | The same rule `App/UiConfig.elm` states for a bad rect ("not clamped into range: inventing a value would put something on screen that nobody ever had") and the same one `dirs.ReadSpawnArgs` already applies ("a missing or corrupt file is best-effort → defaults"). For a name there is no salvage worth guessing at, and a guessed name is a lie about the user's conversation. The verbatim half follows from INV-G2: normalisation is the writer's job, and a reader that repairs values is a second writer with a different idea of the name. |
| **SD-G10** ⚑2 | `maxLabelChars = 120` **characters**, and it is the **one duplicated number** — it joins `scripts/check-backend-parity.sh`'s `check_scalar` list across Rust (`MAX_LABEL_CHARS`) / Go (`MaxLabelChars`) and, in G1, Elm. | The backends need it to enforce SD-G9 while reading. That makes it the fourth triplicated constant in the repo (with `DEFAULT_UI_CONF_VERSION`, `MAX_STORED_WINDOWS`, `DEFAULT_RECURSION_LIMIT`) and the parity script already has the exact mechanism. Nothing about *display* shares this number (SD-G13): it is a storage rule only, so no presentation constant can drift into it. **The unit is characters, not bytes** — `chars().count()` / `utf8.RuneCountInString` — because a 120-hanzi label is 360 bytes, and a backend that measured bytes would drop names the other keeps. `label_cases.json` has that case precisely so the divergence cannot hide. |
| **SD-G11** | Last-writer-wins, no merge, no compare-and-swap. | `ui.conf` already accepted this trade (README: two clients each write the whole file) and the hazard here is strictly smaller: the document is one session's name, so a stale write can only clobber that one name, and the auto-derived text is a deterministic function of the first prompt. A conditional write would need a new backend capability to protect a cosmetic field. |

| **SD-G12** ⚑1 | **Auto-naming is on**, with no setting. The first prompt of a session that has no label writes the derived one. | The alternative (UI-only, never persisted) leaves the closed-session list exactly as broken as today, which is the half this feature exists for; the third option (a toggle) is a fifth config file for a field that is one keystroke to overwrite. What the user typed is the least controversial possible source for the name, and `auto: false` means their own words always win. |
| **SD-G13** ⚑2 | **No fixed display cap.** Storage caps at `maxLabelChars` (SD-G10); a title bar truncates by *width* (CSS ellipsis) because the window is resizable and "a window's content spans the window" is already this app's rule. Full text in the tooltip. | A 60-character cap would be a reading column inside a frame the user just dragged wide — the exact thing `cb52073` ("a window's content spans the window") removed from the message body. Width-aware ellipsis needs no constant, so nothing is duplicated across the three files, so the parity scalar stays a *storage* rule. |
| **SD-G14** ⚑2 | The title bar keeps the **model name**: `<label> — <model>`, falling back to `Session <n> — <model>` when there is no label. Only the `Session <n>` part is replaced by a label; the em-dash separator is what the title uses today, so it stays. | Which model a window is talking to is the one piece of the old title that is load-bearing while debugging (a wrong `preset`/`model.conf` choice shows up here first). Dropping it would trade a name for a name. Truncation (SD-G13) eats the label, never the model. |
| **SD-G15** ⚑3 ⚑4 | **Node sessions are not named** — no label document under `plans/<planId>/<nodeId>/`; their identity is meaningful only inside its plan, and they already carry `[Plan · planId/nodeId]`. **An unnamed session keeps the 8-char id** in the manager, not `Untitled`. | `Untitled` × 30 is a list where every row says nothing; a differing hex prefix at least discriminates, and matches what the window's own fallback (`Session <n>`) points at. Node sessions: naming them would put a second, narrower identity space next to the one `list_session_dirs` already refuses to list (it skips dirs with no top-level `session.alaya`). |



| **SD-G16** | The write goes through **`sync_session_label`**, its own command, and its reply is its own message (`SessionLabelSyncResult`). Not `fs_write_file_text`. | `onFsWriteResult` carries `{ ok, error }` only — no path, no reqId — so a second writer on that port cannot be told apart from the first. The arm today would take a failed rename, clear the ACTIVE PLAN WINDOW's `saving` flag and file the error under `setPlanErrors`: a wrong attribution found while writing G1, before G2 needed it. A dedicated reply also lets the backend enforce the cap and write atomically (tmp + rename, `dirs.WriteFileAtomic`) — `fs_write_file_text` neither validates shape nor writes atomically, and a torn label file is an invisible lost name (SD-G9 would then *drop* it). Precedent: every other client-owned document has its own pair (`get/sync_ui_config`, `_asr_config`, `_global_config`); only `session.refs.json` rides the fs port, and it is content-addressed, so its reply never needed attributing. |

### The document

```json
{ "v": 1, "label": "refactor the parser", "auto": false }
```

`label` — 1..120 chars after the writer's normalisation (trim, inner newlines → single
space). `auto` — `true` means the client derived it; a user rename always writes `false`.

## Read and write paths

**Read (both backends).** `list_session_dirs` grows one field on its item struct. It
already does per-dir work of this exact shape (Go: `dirs.ReadSpawnArgs(path).Preset`;
Rust: `dirs::read_spawn_args(&path).preset`), and both already skip a dir without a
`session.alaya`, so node sessions stay out of the list (unchanged). Per SD-G9: a read
failure of any kind yields `""`, never an error — a session that cannot be named is
still a session. The client's `sessionDirDecoder` grows from `D.map2` to carry `label`
(and `preset`, see Rot).

**Read (client).** One fetch at startup (SD-G7) plus the existing fetch on
`OpenSessionManager`. Both land in the same model field, `sessionLabels : Dict String
Label`, keyed by identity. Nothing else may keep a copy of a label (INV-G1).

**Write (client).** `Session/Labels.elm` is the only producer of a payload (it owns the
encoding), and every trigger that sends one is spelled `withLabelSave` in
`App/Labels.elm`, so the whole write set is one grep — mirroring how
`App/UiLayout.elm`'s `withUiSave` makes the layout writes greppable (SD16's lesson):

1. `withLabelSave` on **commit of the rename editor** (Save button or Enter);
2. the auto-label at the **end of the first prompt send** of a session that has no
   label and is not `auto: false`.

**A correction G2 made while implementing row 1.** This list said "Save button /
Enter / blur". Blur cannot be a commit trigger here: the editor has a Cancel button,
and a blur fires *before* the click that caused it, so "Cancel" would save what the
user typed and then report success. (`App.Presets` has the same editor shape and made
the same call for the same reason.) The two remaining triggers are Save and Enter, and
`e2e/label-e2e.mjs` §3 asserts that Cancel changes nothing on disk — the assertion that
keeps a later reader from restoring the blur.

Both go out through **`sync_session_label`, a command of its own** (SD-G16).
**No new port for reading, one for writing**, and `transport.js` gains one
dumb-pipe handler like the `get/sync` pairs `ui.conf`, `asr.conf` and
`global.conf` already have.

> **SD-G16 corrects what this document claimed when G0 was designed.** The first
> plan said the write would ride the existing `fs_write_file_text`, so "no new
> command, no new port, nothing in `transport.js`" and the parity script's
> command counts would not move. Writing that into code showed it was wrong: the
> reply of that port is `{ ok, error }` and **nothing else** — no path, no reqId
> (`transport.js`'s `fsWriteFileText` handler, and `Ports.elm`'s port record is
> `{path, content, createParents}`). So a failed name write would be attributed to
> whatever else had last used the port — today its `FsWriteResult` arm clears the
> ACTIVE PLAN WINDOW's `saving` flag and pushes the error into `setPlanErrors`.
> That is the class of defect AGENTS.md's "Routing: tagged fs ports" section and
> `docs/arch-persistent.md`'s "an `object_get` reply cannot be routed to its
> asker" note exist to prevent, and G2 (which must show a rename failure in the
> manager) would have shipped straight into it.

A failed rename write surfaces in `sessionManagerError` (the manager's existing error
row). A failed auto-label write is logged and **not** shown: a name is not worth
interrupting a send, and the user has already seen their own prompt. One boolean tells
the two apart — a rename can only be started from the manager, and the manager covers
the board, so no send is in flight while it is open.

**Which session failed is stated, not guessed.** `sync_session_label`'s reply is
`{ok, error}` from both backends, and neither knows anything about the UI, so
`transport.js` echoes the request's `sessionId` into the reply it synthesises: the
bridge is the one place that has seen the request and the outcome together. Without it
the message can only say "a name failed to save" while the manager lists thirty
sessions — SD-G16's mis-attribution, surviving in a narrower form. It is read
optionally in `App.Labels.onSyncResult`, so an older bridge degrades to a vaguer
message rather than a lost one.

**Delete.** Nothing to prune: `delete_session_dir` removes the directory and the label
goes with it. That is the same property `ui.conf` had to build a prune path to obtain,
and it is the main reason the label is per-session rather than global (README: "a
deleted session's memory goes with its directory").

## UI surfaces

| Surface | Change |
|---|---|
| Window title bar (`session-bar-title`) | `<label> — <model>`, or today's `Session <n> — <model>` with no label (SD-G14). Ellipsis by *width* — a CSS rule on the title span, no character count in Elm (SD-G13) — with the full label and the session id in the `title` tooltip, so a truncated name is never a lost name. The `[Plan · …]` badge prefix stays in front of either. |
| Session Manager row (`.sel-page-item-name`) | The label, or the 8-char id prefix when there is none — an unnamed session still needs *some* handle the user can compare against a window. The id goes onto the row as `data-session-id` either way (INV-G3). |
| Session Manager controls | A `✎ Rename` button per row in the existing actions cell, next to Resume / Versions / Delete. A filter box at the top (`Fuzzy.fuzzyMatch` + the trimming/selection-clamping discipline `Session/Selector.elm` already implements — reuse it, do not re-derive it). Rows sort by label when filtering, by modification time otherwise (the backends' current order). |
| Rename editor | A **global** overlay, the same shape as the Preset/config editors: an `App/Types.elm` record `{ show, targetId, input, error }` and one module owning its transitions. |

## Invariants, and what enforces each

A rule with no check is prose. Each of these names the thing that will fail when it is
broken.

| # | Invariant | Enforcement |
|---|---|---|
| **INV-G1** | A label reaches any renderer through exactly one module: `App/Labels.elm`. It has FOUR accessors now — `titleFor` / `titleTooltip` for a window's bar, `rowName` / `rowTooltip` for a manager row, plus `filteredRows` (which rows a term keeps) and `openRename`'s prefill — and `titleFor`'s `Session <n>` fallback lives *inside* it, because the fallback needs `sessionNums`, which is model state. No module outside `App/Labels.elm` reads `sessionLabels`. **Two of the accessors disagree about the fallback on purpose** (`titleFor` → seat number, `rowName` → 8-char id, SD-G15), which is the strongest argument for the rule: the disagreement is a decision, and a decision duplicated across screens is a decision someone will "fix" by accident. | A new section in `scripts/check-layout-invariants.sh` — same elm_code-comment-stripping trick, ratchet at 0 raw reads outside `App/Labels.elm`, and the `"Session " ++` construction legal in exactly one file (plus `App/Labels.elm`). That script's premise is already "a second read path means two models of what is on screen"; window titles are that model too. The `WIN_READS=0` case in it shows why the check must also assert the accessor still exists: a renamed field makes a grep pass vacuously — the anti-vacuity list names all seven functions now, and both directions are mutation-verified below. |
| **INV-G2** | Only `Session/Labels.elm` builds a label payload, and every write trigger is spelled `withLabelSave` (in `App/Labels.elm`, which is the only module allowed to name it). | `grep -c 'withLabelSave'` ratchet in the same script, mirroring how `withUiSave`'s write set is kept greppable (documented in `docs/solo-view.md`). |
| **INV-G3** | A Session Manager row carries `data-session-id`, and it is the row's stable identity for tests. Tests do not select session rows by displayed text. | Three scripts match session rows by text today: `fork-e2e` (`includes(rootSid.slice(0, 8))`, `name === fid.slice(0, 8)`), `restart-e2e` and `solo-e2e`. The moment a label replaces that text they fail — which is the F-series' lesson about Phase 7's restyle, except that `e2e/scripts.txt` now runs them, so this fails loudly in G2 instead of quietly later. **`.sel-page-item-name` is shared by three renderers** (`Overlay/Selector.elm`'s generic list, the Session Manager, and the version list's `v0`/`v1`), so `model-fields-e2e` and `two-plans-e2e` match the *other* two and must NOT be migrated. G2 adds the attribute and moves those three lookups before any row's text can change. Same direction as `f5129fe` (chain lookups by data attributes, not text scanning). |
| **INV-G4** | No keyboard entry point is added. `Enter` inside the rename field commits (it is typing in a focused field, not a chord); `Escape` closes the editor through the existing topmost-overlay stack in the `KeyDown` arm, above the per-session overlays; no new `Ctrl+*` is introduced anywhere. | `tests/EscapeOverlayTest.elm` gains the editor's slot in the precedence chain — that test is the existing pin for "which overlay Esc closes first", and a new global overlay silently missing from it is exactly how an Esc press would start closing the wrong thing. Justified by the README's own argument: "the keyboard is where typing and reflexes live". |
| **INV-G5** | The rename editor is a **global** overlay, so it does **not** join `App.Windows.sessionIsWaiting`. | Stated so nobody "helpfully" adds it: that list's definition is the seven per-session renderers (`viewCloseConfirmOverlay` … `viewMediaPreviewOverlay`), and `tests/SoloViewTest.elm` walks one case per field. Adding a global editor there would inflate `waiting` with a prompt that is on screen right now, which is the opposite of what the counter means. What SD11 does require of a new global overlay is reachability + an Esc path, and INV-G4 covers that. |
| **INV-G6** | The label never affects behaviour: not resume, not the spawn envelope, not the object store, not plan execution. It is display metadata with its own file. | `Session/Labels.elm` must not be imported by `Plan/*`, `App/Arch.elm`, or any backend spawn path. Enforced by the module's own import list + a Go/Rust test that a session with a label file resumes with identical spawn args to one without. |

## Side findings (worth knowing before G0, cheap to fix inside it)

- **`preset` was computed by both backends and dropped by the client — fixed in G2.**
  `SessionDirInfo` / `list_session_dirs` carried it; `sessionDirDecoder` was a `D.map2`
  over `id` + `created_at`, so the manager could not show what preset a session had, at
  the cost of a byte per row. It is now a `D.map3` and the value rides the row's
  sub-line (`2026-09-15 08:58 · Simple`). Read **leniently**: `decodeSessionDir`
  returns Nothing when the decoder fails and the manager drops that row, so a
  required-but-absent key would make a whole session vanish — a different trade from
  `asr.conf`'s deliberately strict decode, and the reason the two look inconsistent.
- The `e2e/*.mjs` row-lookup-by-text (INV-G3) is the same defect class `f5129fe` fixed
  in `chain.js`. **Done in G2's first commit**, before any row's text could change.

## Phases

Mirror F3's split, which worked: **storage first, client second, each green on its
own.** G0 touches no Elm; if you find yourself editing `src-elm/src` during G0, stop.

### G0 — the storage half (backends only) ✅ landed 2026-09-14

> A phase's commit hash lives in `git log --oneline`, not in this file: the
> F-series wrote hashes here and they were only true after the fact. The date is
> the part this file can state honestly at the moment it is written.

- [x] `dirs.rs` / `internal/dirs/label.go`: `label_file` / `LabelFile`,
      `read_session_label` / `ReadSessionLabel` (lenient per SD-G9, verbatim per
      its second half), `MAX_LABEL_CHARS` / `MaxLabelChars`. Both carry the "do
      NOT write this from the backend" warning, because the file's value comes
      from having exactly one writer.
- [x] `list_session_dirs`: `label` on `SessionDirInfo` in both backends
      (`commands/mod.rs`, `handlers/sessions.go`), `""` on any read failure,
      dir-skipping rules untouched (a dir with no `session.alaya` stays out —
      a name must not resurrect a plan node dir into the manager).
- [x] Shared fixture `testdata/serialization/label_cases.json` — **21 cases**, a
      read/accept table (`input` = the exact file bytes, `null` = no file), run
      by `src-go/internal/dirs/label_read_test.go` and
      `dirs.rs::session_label_read_matches_shared_fixture`. The cases that exist
      because a per-language suite would have excused them: `hanzi-at-cap` (120
      chars = 360 bytes), `hanzi-over-cap`, `label-null` vs `label-missing` (Go
      leaves the zero value, serde errors — both must yield `""`),
      `unmodelled-field-wrong-type` (`auto` mistyped must not lose the name),
      `bom`, `trailing-garbage`, `padded-label-verbatim` (the reader must not
      repair), `no-file`.
- [x] `check-backend-parity.sh`: `check_scalar "session label char cap (Rust vs
      Go)"`, plus the fixture-existence assertion. The Elm side joins in G1,
      which is why the label says "(Rust vs Go)" rather than claiming three.
- [x] Behaviour tests both sides: `handlers.TestListSessionDirsCarriesLabel` /
      `dirs.rs::list_session_dirs_carries_label` (named, corrupt, absent — and
      `len(list) == 3`, because an unreadable name must never hide a session),
      plus `TestSessionDirInfoLabelKey` pinning the reply's key spelling (the
      parity script compares command NAMES, never payload KEYS, and a drifted
      key reads as "no name" forever on one deployment only).
- [x] **Mutation-verified**, because a test that cannot fail is not a check:
      dropping the Go wiring → red; dropping the Rust wiring → red; making Go
      measure the cap in BYTES → `hanzi-at-cap` red; setting Go's cap to 121 →
      the parity script red. One attempt produced a *false* green first: the
      byte-mutation didn't compile (unused `utf8` import), and a build failure
      is not a passing test — it was red for the wrong reason, so it was redone
      in a form that compiles.
- [x] Gate: full verification, all green — `go vet` + `go test -race` (10 pkgs),
      `cargo test --lib` (139), `cargo clippy --lib` (2 pre-existing
      too-many-arguments warnings in `alayacore.rs:56` / `sessions.rs:189`, no
      errors), `elm make` (untouched) + `elm-test` (931),
      `check-backend-parity.sh`, `check-layout-invariants.sh`, `check-schema`,
      `check-css`, `make e2e` (all 14 suites in `e2e/scripts.txt`).

### G1 — the client's half of the document ✅ landed 2026-09-14

- [x] **The write command, both backends** (SD-G16): `sync_session_label
      {sessionId, document}` — id validated by `SafePathComponent` /
      `safe_path_component` (a traversal here would write outside the store), the
      document validated for shape + `maxLabelChars`, then
      `dirs.WriteSessionLabel` (atomic tmp+rename) or `dirs.RemoveSessionLabel`
      when the label is empty-after-trim (no tombstone). Stored **verbatim**: a
      re-marshal would have the two backends write different bytes for one name
      (Go sorts map keys, serde_json keeps insertion order). Registry
      `handlers.go` + `lib.rs`, one `transport.js` pipe handler,
      `Ports.syncSessionLabel` / `onSessionLabelSync`, `Msg.SessionLabelSyncResult`.
      Parity counts moved **47 → 48** and the bridge **44 → 45** — the check
      noticed, which was the point.
- [x] `label_cases.json` grew `write_cases` (13): the accept/refuse table for that
      validation, run by both backends
      (`TestLabelWriteTableMatchesSharedFixture` /
      `write_table_matches_shared_fixture`) with the refusal compared as a
      **literal message** — those strings are shown to the user, and a
      command-name check can never see one drift.
- [x] `src-elm/src/Session/Labels.elm` — **the document, pure**: `Label`,
      `decode`, `encode`, `keys`, `usableText` (the ONE usability rule, shared by
      the document reader and the listing projection), `normalise`
      (`String.words` + join: idempotent, and the writer's job alone),
      `autoFromPrompt` (cut at a word boundary past the midpoint, else hard cut,
      then `…`), `storedPath`. No `App.Types` import.
- [x] `src-elm/src/App/Labels.elm` — **the policy**: `foldListing` (a listing
      fills gaps, never overwrites), `forget` / `forgetAll` (the delete cascade
      hands it its whole ownership set, one call like `UiLayout.prune`),
      `autoNameOnFirstPrompt` (SD-G8/G12/G15's guards, all in this one function),
      `withLabelSave` (the only producer of `syncSessionLabel`), `onSyncResult`
      (ok → nothing; failure → `Ports.logWarn`: never interrupt a send for a
      name). **No `titleFor`** — G2 adds it together with its enforcement, so
      there is no accessor without a caller (F4.1's zombie state, avoided rather
      than deleted later).
- [x] `App.Types.Model.sessionLabels : Dict String String`, `Main.elm` init,
      `tests/TestHelpers.elm` init. The value is the NAME, not the document —
      see the corrected SD-G5b for why, and for what this document first claimed.
- [x] `SessionDirsResult` folds names into the model (SD-G6/G7), and the startup
      `Ports.listSessionDirs {}` joined `Main.elm`'s init batch: without it a
      restored session has no source for its name until the manager opens.
- [x] The auto-label hooked at `doSendPrompt` (the single typed-send path). The
      rename-commit trigger arrives with G2's editor.
- [x] `tests/LabelsTest.elm` — 5 groups: the serialised document pinned as BYTES
      with the key list spelled twice; the round trip; the client's twin of the
      18 deciding `label_cases.json` names (Elm cannot read a file in a test, so
      the shared case NAMES are the sync); `normalise` idempotence; the cap in
      characters plus the emoji case that asserts the CLIENT is the strictest of
      the three (a deliberate direction, stated in `maxLabelChars`'s comment);
      the listing precedence both ways; the auto-derivation guards from both
      origins (named-from-disk, named-by-save); and two message-level tests
      through `App.Update.update SendPrompt`, so the hook is attached to the send
      rather than merely adjacent to it.
- [x] Gate: `make test-go` (10 pkgs, -race), `cargo test --lib` (145),
      `cargo clippy --lib` (0 errors), `elm make` (0 warnings) + `elm-test`
      (977), `check-backend-parity.sh` (48/48/45), `check-layout-invariants.sh`
      (53 modules), `check-schema`, `check-css`, `make e2e` (all 14 suites).

#### What G1 taught

1. **The shared fixture caught a live divergence on its first run.** `label:
   null`: Go unmarshals JSON `null` into a `string` field *without an error*, so
   it accepted the document, read the blank as "clear the name" and would have
   **deleted a user's name**; Rust's `as_str()` yields None and refuses. Fixed by
   decoding into `*string` and refusing nil. Two per-language suites would each
   have asserted their own language's default and both would have been green.
2. **`Dict.keys` sorts, so it cannot assert an order.** The first key-list test
   decoded into a `Dict` and compared `Dict.keys` against `Labels.keys` — it
   passed while proving nothing, because both sides were alphabetised. The pin is
   now on the encoded string, which is also what the file actually contains.
3. **`{ f x | field = y }` is a parse error** — the rule
   `docs/update-slices.md` records, walked into anyway while writing tests. The
   doc was right; reading is not the same as believing.
4. **A reply that cannot be attributed is a bug already filed** (SD-G16).
   `onFsWriteResult` carries `{ok, error}` and nothing else, so a name write
   riding that port would have had its failure blamed on the plan that saved
   last. AGENTS.md's "an `object_get` reply cannot be routed to its asker" is the
   same defect from the other end; the design was re-read at implementation time
   and the sentence in it was wrong.
5. **Proved on disk, not in a model.** `ALAYAFACE_KEEP_ARTIFACTS=1 node
   chain-diag.mjs`, then a filesystem look: the top-level session directory holds
   `session.label.json` = `{"v":1,"label":"Create a demo plan for
   diag","auto":true}`, and the three node-session dirs under `plans/…/t1|t2|t3/`
   hold `session.alaya` with **no label file** — SD-G15 observed rather than
   assumed (guard in the client, plus the backend's top-level requirement).
6. **What no elm-test here can see: that the port fired.** `withLabelSave`
   returns a `Cmd` (the `App/UiLayout` shape) and a test cannot name the port
   inside one — the same limit `UiLayoutTest` lives with. The model half is
   asserted; reading the file back through the RPC is `e2e/label-e2e.mjs`'s job
   in G3. Naming the gap is cheaper than discovering it later.
7. **Four mutations run against the new suite**, each red for exactly the reason
   the rule exists: disk-wins in `foldListing` → 1 red; the SD-G8 guard removed →
   3 red; `usableText`'s cap check removed → 3 red. A first attempt at the second
   mutation did not compile (a multi-line substitution that silently did not
   match), so it was redone as a one-line lookup swap — a mutation that never
   ran is not a check, which is the same lesson `docs/update-slices.md` records
   about a kill counted as a pass.


### G2 — the surfaces ✅ landed 2026-09-15

- [x] **e2e contract first** (INV-G3): `data-session-id` on the session row, and migrate
      `solo-e2e` / `restart-e2e` / `fork-e2e`'s three text lookups to the attribute.
      Commit this before any row's text can change, so a red run means a real defect —
      and leave `model-fields-e2e` / `two-plans-e2e` alone: they match the version and
      model lists, which share `.sel-page-item-name`.
- [x] Title bar text through `App/Labels.titleFor` (INV-G1) + tooltip (`titleTooltip`
      carries the whole name plus the id, since width-truncation SD-G13 makes the bar
      unreadable on its own). **The manager row is deliberately untouched here**: it
      still shows the 8-char id, and changes with the rename editor below, because
      SD-G15's fallback only makes sense once there is something to fall back from.
- [x] Manager: label column content, filter box (reuse `Session/Selector.elm`), sort by
      name while filtering, `✎ Rename`, the editor overlay, with its
      `open / close / input / commit` transitions as pure `Session/Labels.elm`
      functions returning `Label` + effects-as-data (the F-series' rule: ports stay in
      `App/Update.elm`). **Landed as designed**, with three notes a later reader needs:
      the transitions return a `Commit` (`Reject String` / `Named Label` / `Blank`)
      rather than a `Label`, because "the field is empty" is a request to REMOVE the
      name and is not itself a name; `commit` hands back a CLOSED editor, so
      `App.Labels.commitRename` captures the identity before calling it (pinned by a
      test, since that ordering is otherwise invisible); and clearing must `forget` the
      entry rather than store `""` — a `Just ""` renders an empty title bar, which is
      worse than a seat number. The filter calls `Session.Selector.filterItems`
      unchanged, and the id is part of the match key so an unnamed session stays
      findable. `preset` arrived with this commit too (the side finding above), and the
      row's editor is reached by `data-rename-session` / `#session-rename-input`, never
      by row text (INV-G3).
- [x] `KeyDown` stack slot + `EscapeOverlayTest` case (INV-G4). The slot is ABOVE the
      session manager: the editor is opened from a row, so whenever both are up the
      editor is the topmost thing on screen. Two tests, and the second is the one that
      matters — it asserts the PAIR `(editor closed, manager still open)`, because with
      the slot deleted the manager's own handler also closes the editor, so "closes the
      rename editor" alone stays green while Escape silently discards the list
      underneath the box the user is typing in. Verified by mutation (`else if False` on
      the slot → exactly that one test red, and only it). No new chord anywhere; Enter
      commits inside the focused field, which is what INV-G4 permits.
- [x] `make check-invariants` extended with INV-G1/G2 sections, including the
      "accessor still exists" anti-vacuity assertion. **Mutation-verified**, both
      directions: a raw `Dict.get id model.sessionLabels` added to a renderer in
      `App/View.elm` → red naming the file, line and site; renaming `titleFor` in
      `App/Labels.elm` → red with "fix this script, do not delete the check", which is
      the case that turns a vacuous grep pass into a failure (the `WIN_READS=0` lesson
      above applied to this feature). G2's second half grew the accessor list to seven
      names (proved by renaming `rowName` and `filteredRows` → both red), and added the
      INV-G5 guard: a `labelEditor` field appearing in `Session/Types.elm` is red, which
      is the only way "this overlay stays global" survives someone meeting
      `sessionIsWaiting` and wanting to help.
- [x] Gate: full verification. Commit + push ×3.

#### What G2 taught

1. **The invariant caught the commit that added the invariant.** The view grew a
   caption, `("Session " ++ String.left 8 id)`, and `check-invariants` went red on the
   spot — a second place building a session's display string, introduced by the change
   whose whole subject was display strings. The fix was a `targetCaption` accessor in
   `App/Labels`, and it is worth noting WHY that caption is not `rowName`: while you are
   renaming a session, showing it its own name is circular, and showing it the fallback
   you are about to replace is worse. So the editor is the one surface that prints the
   raw identity, on purpose.
2. **An Escape test that cannot fail.** "Escape closes the rename editor" passes even
   with the editor's slot deleted, because the manager's own handler below it also
   closes the editor. Only asserting the PAIR — editor gone, manager still open — can
   see the difference, and the difference is the bug (Escape would discard the list
   underneath the box the user is typing in). Mutation confirmed it: disabling the slot
   reddens exactly one of the two tests.
3. **A corrupt-file assertion needs a reader that has never seen the good value.** The
   first draft wrote garbage over a label and checked the row fell back to the id
   prefix — in the same page that had already read the real name. `foldListing` keeps
   what this process believes (that precedence is the point of it), so the test would
   have been green forever. It reloads the page now.
4. **A pre-filled field is not a cleared field.** Driving the editor by setting
   `.value = ''` in the DOM and then typing appended to the old name, because Elm only
   hears about the field through its `input` event. The symptom looked like an encoder
   bug two hops away. Clear through an event, or select-all.
5. **Run the suite through `make e2e`, or rebuild first.** `make e2e` depends on `elm`;
   `node e2e/label-e2e.mjs` alone serves whatever `src-elm/elm.js` was left from last
   time, which produced a confident false reading ("the row is not named, there is no
   Rename button") about code that was fine.
6. **A list-page container makes a three-line form look broken.** `.sel-page-status`
   carries `flex: 1` — right for centring "No saved sessions." in an empty card, wrong
   for a hint line, which then swallowed the card and pushed Save/Cancel to its bottom
   edge. The fix is one class (`.label-editor`) that pins the lines and centres the
   group; the symptom was only visible in a screenshot, and no assertion would have
   caught it.
7. **SD-G16's attribution fix was incomplete, and only the second half showed it.** A
   dedicated reply message says *what kind* of write failed; it does not say *which
   session*. Over thirty rows, "could not save the session name" is a shrug. The
   backends cannot answer that question (neither knows the UI), so `transport.js` now
   echoes the request's `sessionId` into the reply it synthesises — the one place that
   has seen request and outcome together. Read optionally, so an older bridge degrades
   to a vaguer message rather than a lost one.
8. **The filter rule was already duplicated, and adding a third caller was the
   moment to notice.** `Session.Selector.filterItems` and a private
   `Overlay.Selector.filterItems` were byte-identical, so the design's instruction to
   "reuse it, do not re-derive it" could be satisfied while the codebase kept two
   implementations of the thing being reused. `Overlay/Selector.elm` already imported
   that module, so the merge was one import and a deletion (plus the `Fuzzy` import
   that went unused with it — the residue that tells you a removal was real). Now
   there is one rule with three callers, which is what that sentence in the design
   meant.



### G3 — prove it end to end, then distil ✅ landed 2026-09-15

- [x] `e2e/label-e2e.mjs` (add the basename to `e2e/scripts.txt` — a script in no list
      is not a test): name a session → the title bar shows it → a **real backend
      restart** → the manager shows it → Resume → the title bar shows it again → rename
      → the file on disk is the new one → delete the session → the label file is gone
      with the directory. Plus the auto-label case: send a prompt, never name it, and
      the row says something readable.
      **Landed: 30 assertions, all reading the FILE back from disk**, because what no
      elm-test here can see is that the port fired (G1's lesson 6) — the auto-label
      assertion is literally "the file appeared after the send". Two additions the list
      above did not ask for and both turned out to matter: **Cancel discards** (§3, the
      only thing standing between a later reader and re-adding the blur-commit), and
      **the corrupt-file case needs a fresh process** (§7) — this one's model already
      believes the good name and `foldListing` keeps what it knows, so asserting the
      fallback without reloading would have passed forever while proving nothing.
      Restart means `SIGKILL` + a new server on a new port, not `page.reload`.
- [x] `docs/manual-acceptance.md` §10 (Session identity): the human's checklist,
      including one deliberate corrupt-label-file case (SD-G9) and the unnamed-old-
      session case (SD-G8's known gap).
- [x] README + README.zh-CN: the "Windows and solo view" section gains the naming
      paragraph, in sync, and the Known Limitations row about old unnamed sessions
      (there is no such section in the READMEs — the row went into
      `manual-acceptance.md`'s Known Limitations, which is where that list lives).
- [x] `AGENTS.md`: this document joins the tracked-design table; the config-file
      paragraph gains `session.label.json` (it is **client-owned, whole-file replaced**
      — the fourth member of the replace group, and the one with no `extras` carry for
      per-document keys, like `asr.conf`).
- [ ] Fold the phase record into `docs/archive/TODO-g-series.md` only if this file
      becomes pure history; otherwise the checklists stay ticked here.

## Verification (every phase, from AGENTS.md)

```bash
make test-go
cd src-elm && elm make src/Main.elm --output=/tmp/m.js && elm-test
cd src-tauri && cargo test && cargo clippy --lib
./scripts/check-backend-parity.sh
make check-invariants && make check-schema && make check-css
make e2e
```

Then commit, push to `origin` / `gitee` / `org` (`main`), and confirm with
`git ls-remote` — and re-run the **whole** list after the last file you created, not
after the last one you remember. `cd3d042` exists because of exactly that mistake.

## Later (proposals, not plans)

- **Backfill** auto-labels for pre-G sessions by reading each root's frozen `V0`
  version object (the client already has `object_get` and `Arch.Values.Version`) — the
  same "coverage is defined only at freeze boundaries" caveat as content search, so it
  ships as its own feature with its own honesty statement, or not at all.
- A `✎` in the window title bar (naming in context, without the manager round trip).
  It has to answer the solo question first: SD19 removed `✕` from the solo bar because
  closing under solo is an accident waiting to happen; a rename is not that kind of
  accident, but the bar is narrow and `Attr.title` already carries the name.
- Sorting/grouping the manager by preset (the field G0 could stop dropping).
- Content search — needs a defined index (see Scope).

## Open questions ⚑ — all four answered 2026-09-14 ("as recommended")

Kept here, answered, because the reasoning is the part a later reader re-asks.

1. **Auto-label on by default?** → **Yes, no setting** (SD-G12). Some users will read a
   derived name as the app putting words in their file; `auto: false` and one keystroke
   are the answer, and a UI-only auto name would leave the closed-session list exactly
   as broken as today.
2. **Cap at 120, display at 60?** → **120 in storage, no display cap** (SD-G13, SD-G14):
   a window is resizable and its content spans it, so truncation is by width, and the
   model name stays in the title because it is the load-bearing half while debugging.
3. **Node sessions?** → **Not named** (SD-G15). No label document under
   `plans/<planId>/<nodeId>/`; their identity is only meaningful inside its plan.
4. **Old unnamed sessions** → **keep the 8-char id** (SD-G15). `Untitled` × 30 is a
   list where every row says the same nothing.
