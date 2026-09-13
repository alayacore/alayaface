# Session identity — a name for a session, and how to find it again

**Status: proposed, no code yet.** The ⚑ section at the end is what this document asks
the human to confirm before G0 starts. **SD** rows are decisions the cited code
evidence settles — once the ⚑ answers are in, do not re-litigate an SD row in code:
change the row here first and say so in the commit message, per the repo's convention.

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
| **SD-G5b** | The feature needs **two** client modules, not one: `Session/Labels.elm` owns the document (types, decode/encode, `normalise`, `autoFromPrompt`, the editor's transitions — pure, no `App.Types`), and `App/Labels.elm` is the model-aware policy (`titleFor : Model -> String -> String`, `withLabelSave`). | This is F3's split repeated, and for the same reason (`AGENTS.md` records the rule): once `Model.sessionLabels` has a field whose type is `Labels.Label`, `App.Types` imports `Session/Labels.elm`, so that module can never import `App.Types` back. `titleFor` needs `sessionNums` (for the `Session <n>` fallback) and the save needs the board, so both belong above the line — exactly why F3 ended up with `App/UiConfig.elm` *and* `App/UiLayout.elm`. One module cannot be both shapes; try it and the compiler says so. |
| **SD-G6** | Labels reach the client through the **typed `list_session_dirs` RPC**, which grows a `label` field — not through `fs_read_file_text`, and not through `Plan/MetaScan`'s startup walk. | The fs ports are shared traffic routed by reqId (AGENTS.md "Routing: tagged fs ports"), and the scan reads **one file at a time**, so N labels = N more serialised round trips and a second queue in a machine that already has four. The RPC already iterates every top-level session dir and already parses a JSON file per dir. One call, one payload, no new routing hazard. |
| **SD-G7** | `OpenSessionManager` is currently the only caller of `listSessionDirs`. A **startup fetch** is added. | Without it the title bar knows no label for a session restored from disk, and the feature would name sessions only in the screen the user is least likely to be looking at. The fetch is untagged and fire-once per request, which the AGENTS.md routing note already classifies as safe (`sessionDirsResult` is in that list). |
| **SD-G8** ⚑1 | The label is **auto-derived from the first prompt** and persisted then, unless a label already exists. `auto: true` marks it as machine-derived; any user edit sets `auto: false` and nothing in the client ever writes over `auto: false`. | Without this the feature ships empty: nobody renames 30 existing sessions by hand. The first user message is already in the client's hands at send time, so the derivation costs one small write per session, once. Old sessions keep the hex/id fallback until they are named — stated plainly so nobody is surprised, and see "Later" for the backfill idea. |
| **SD-G9** | Reader is **lenient and drops**, never clamps: a `session.label.json` that is absent, unparseable, missing `label`, or longer than `maxLabelChars` yields *no label*, and the fallback chain decides what to show. | The same rule `App/UiConfig.elm` states for a bad rect ("not clamped into range: inventing a value would put something on screen that nobody ever had") and the same one `dirs.ReadSpawnArgs` already applies ("a missing or corrupt file is best-effort → defaults"). For a name there is no salvage worth guessing at, and a guessed name is a lie about the user's conversation. |
| **SD-G10** | `maxLabelChars = 120` is the **one duplicated number**, and it joins `scripts/check-backend-parity.sh`'s `check_scalar` list across Elm / Rust (`MAX_LABEL_CHARS`) / Go (`MaxLabelChars`). | The backends need it to enforce SD-G9 while reading. That makes it the fourth triplicated constant in the repo (with `DEFAULT_UI_CONF_VERSION`, `MAX_STORED_WINDOWS`, `DEFAULT_RECURSION_LIMIT`) and the parity script already has the exact mechanism. The *display* truncation (60 chars in a title bar, full text in the tooltip) is a client presentation rule and is deliberately **not** shared — it must not become a storage rule. |
| **SD-G11** | Last-writer-wins, no merge, no compare-and-swap. | `ui.conf` already accepted this trade (README: two clients each write the whole file) and the hazard here is strictly smaller: the document is one session's name, so a stale write can only clobber that one name, and the auto-derived text is a deterministic function of the first prompt. A conditional write would need a new backend capability to protect a cosmetic field. |

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

1. `withLabelSave` on **commit of the rename editor** (Save button / Enter / blur) —
   never per keystroke;
2. the auto-label at the **end of the first prompt send** of a session that has no
   label and is not `auto: false`.

Both go out through the existing `Ports.fsWriteFileText { path, content,
createParents = True }` — the same port `App/Arch.elm` uses for `session.refs.json`.
**No new command, no new port, nothing new for `transport.js`,** which is why
`check-backend-parity.sh`'s command counts do not move in this series (say so in the
commit message, per the "which twin did you check" rule).

A failed rename write surfaces in `sessionManagerError` (the manager's existing error
row). A failed auto-label write is logged and **not** shown: a name is not worth
interrupting a send, and the user has already seen their own prompt.

**Delete.** Nothing to prune: `delete_session_dir` removes the directory and the label
goes with it. That is the same property `ui.conf` had to build a prune path to obtain,
and it is the main reason the label is per-session rather than global (README: "a
deleted session's memory goes with its directory").

## UI surfaces

| Surface | Change |
|---|---|
| Window title bar (`session-bar-title`) | `label` if present, else today's `Session <n> — <model>`. The plan badge prefix stays in front of either. The full label + the session id go in the `title` tooltip so a truncated name is never a lost name. |
| Session Manager row (`.sel-page-item-name`) | The label, or the 8-char id prefix when there is none — an unnamed session still needs *some* handle the user can compare against a window. The id goes onto the row as `data-session-id` either way (INV-G3). |
| Session Manager controls | A `✎ Rename` button per row in the existing actions cell, next to Resume / Versions / Delete. A filter box at the top (`Fuzzy.fuzzyMatch` + the trimming/selection-clamping discipline `Session/Selector.elm` already implements — reuse it, do not re-derive it). Rows sort by label when filtering, by modification time otherwise (the backends' current order). |
| Rename editor | A **global** overlay, the same shape as the Preset/config editors: an `App/Types.elm` record `{ show, targetId, input, error }` and one module owning its transitions. |

## Invariants, and what enforces each

A rule with no check is prose. Each of these names the thing that will fail when it is
broken.

| # | Invariant | Enforcement |
|---|---|---|
| **INV-G1** | A label reaches any renderer through exactly one read path: `App/Labels.elm`'s `titleFor : Model -> String -> String` (label → `Session <n>` fallback lives *inside* it, because the fallback needs `sessionNums`, which is model state). No module outside `App/Labels.elm` reads `sessionLabels`. | A new section in `scripts/check-layout-invariants.sh` — same elm_code-comment-stripping trick, ratchet at 0 raw reads outside `App/Labels.elm`, and the `"Session " ++` construction legal in exactly one file (plus `App/Labels.elm`). That script's premise is already "a second read path means two models of what is on screen"; window titles are that model too. The `WIN_READS=0` case in it shows why the check must also assert the accessor still exists: a renamed field makes a grep pass vacuously. |
| **INV-G2** | Only `Session/Labels.elm` builds a label payload, and every write trigger is spelled `withLabelSave` (in `App/Labels.elm`, which is the only module allowed to name it). | `grep -c 'withLabelSave'` ratchet in the same script, mirroring how `withUiSave`'s write set is kept greppable (documented in `docs/solo-view.md`). |
| **INV-G3** | A Session Manager row carries `data-session-id`, and it is the row's stable identity for tests. Tests do not select session rows by displayed text. | Three scripts match session rows by text today: `fork-e2e` (`includes(rootSid.slice(0, 8))`, `name === fid.slice(0, 8)`), `restart-e2e` and `solo-e2e`. The moment a label replaces that text they fail — which is the F-series' lesson about Phase 7's restyle, except that `e2e/scripts.txt` now runs them, so this fails loudly in G2 instead of quietly later. **`.sel-page-item-name` is shared by three renderers** (`Overlay/Selector.elm`'s generic list, the Session Manager, and the version list's `v0`/`v1`), so `model-fields-e2e` and `two-plans-e2e` match the *other* two and must NOT be migrated. G2 adds the attribute and moves those three lookups before any row's text can change. Same direction as `f5129fe` (chain lookups by data attributes, not text scanning). |
| **INV-G4** | No keyboard entry point is added. `Enter` inside the rename field commits (it is typing in a focused field, not a chord); `Escape` closes the editor through the existing topmost-overlay stack in the `KeyDown` arm, above the per-session overlays; no new `Ctrl+*` is introduced anywhere. | `tests/EscapeOverlayTest.elm` gains the editor's slot in the precedence chain — that test is the existing pin for "which overlay Esc closes first", and a new global overlay silently missing from it is exactly how an Esc press would start closing the wrong thing. Justified by the README's own argument: "the keyboard is where typing and reflexes live". |
| **INV-G5** | The rename editor is a **global** overlay, so it does **not** join `App.Windows.sessionIsWaiting`. | Stated so nobody "helpfully" adds it: that list's definition is the seven per-session renderers (`viewCloseConfirmOverlay` … `viewMediaPreviewOverlay`), and `tests/SoloViewTest.elm` walks one case per field. Adding a global editor there would inflate `waiting` with a prompt that is on screen right now, which is the opposite of what the counter means. What SD11 does require of a new global overlay is reachability + an Esc path, and INV-G4 covers that. |
| **INV-G6** | The label never affects behaviour: not resume, not the spawn envelope, not the object store, not plan execution. It is display metadata with its own file. | `Session/Labels.elm` must not be imported by `Plan/*`, `App/Arch.elm`, or any backend spawn path. Enforced by the module's own import list + a Go/Rust test that a session with a label file resumes with identical spawn args to one without. |

## Side findings (worth knowing before G0, cheap to fix inside it)

- **`preset` is computed by both backends and dropped by the client.** `SessionDirInfo`
  / `list_session_dirs` carry it; `sessionDirDecoder` is a `D.map2` over `id` +
  `created_at`, and `App.Update.SessionDir` has no slot for it. So the manager cannot
  show what preset a session had, at the cost of a byte per row. Either carry it and
  show it, or stop computing it — carrying it and showing it on the row's sub-line is
  two lines of Elm and answers a question users ask.
- The `e2e/*.mjs` row-lookup-by-text (INV-G3) is the same defect class `f5129fe` fixed
  in `chain.js`.

## Phases

Mirror F3's split, which worked: **storage first, client second, each green on its
own.** G0 touches no Elm; if you find yourself editing `src-elm/src` during G0, stop.

### G0 — the storage half (backends only)

- [ ] `dirs.rs` / `internal/dirs`: `label_file(session_dir)`, `read_session_label(dir)
      -> Option<String>` (lenient per SD-G9), `MAX_LABEL_CHARS` / `MaxLabelChars`.
- [ ] `list_session_dirs`: one more field on the item struct in both backends, `""` on
      any read failure, same dir-skipping rules as today.
- [ ] Shared fixture `testdata/serialization/label_cases.json` — a **read/accept table**
      (bytes → expected label), run by both `src-go/internal/dirs/*_test.go` and the
      Rust `dirs.rs` tests, like `spawn_cases.json`. Cases: valid, unknown `v`, missing
      `label`, non-object body, empty/whitespace-only, over `maxLabelChars`, **a Chinese
      label** (the sanctioned fixture exception to the no-Chinese rule: it proves the
      byte range survives both readers), and a file with a UTF-8 BOM.
- [ ] `check-backend-parity.sh`: `check_scalar "label char cap"` comparing **Rust and
      Go** here, with the Elm side (`maxLabelChars` in `Session/Labels.elm`) appended to
      the same line in G1. Decided rather than left open, because a scalar check that
      silently covers two of three files is the half-wired gate this repo has already
      been bitten by (`b34891b`: INV1's file list named two files by hand and every
      module added since escaped the check). G0 therefore touches no Elm at all.
- [ ] Go + Rust tests: a dir with a label is listed with it; a corrupt one is listed
      without it; the two backends agree on every fixture case.
- [ ] Gate: full verification. Commit + push ×3.

### G1 — the client's half of the document

- [ ] `src-elm/src/Session/Labels.elm` — **schema owner, pure**: `Label`, `decode`,
      `encode`, `maxLabelChars`, `normalise` (trim, collapse newlines — **the writer's
      job, and only the writer's**), `autoFromPrompt`, and the rename editor's
      transitions. No `App.Types` import (SD-G5b: once `Model` has a `Label` field this
      is forced by the cycle rule, not chosen).
- [ ] `src-elm/src/App/Labels.elm` — **model-aware policy**: `titleFor` (label →
      `Session <n>` → id fallback chain, the only reader of `sessionLabels`) and
      `withLabelSave` (the only producer of a save `Cmd`). Two modules because one
      cannot be both shapes — see SD-G5b.
- [ ] `App.Types.Model.sessionLabels`, `Main.elm` init, `tests/TestHelpers.elm` init
      (both initialise the whole record; `App/Types.elm` gains the `Label` import).
- [ ] `SessionDirsResult` carries labels into the model (SD-G6/G7); the startup fetch
      added where the startup sequence is built.
- [ ] The two write triggers wired (rename commit, auto-label after the first prompt
      send), gated on "no label and not `auto: false`".
- [ ] `tests/LabelsTest.elm`: round trip; the serialised **key list pinned** (the
      `AsrConfigTest.elm` discipline — a dropped field must fail a test, not silently
      shrink the user's file); normalisation idempotence; over-cap refused; `auto` never
      overwritten; `titleFor`'s full fallback chain; one case per Chinese/emoji label.
- [ ] Gate: full verification. Commit + push ×3.

### G2 — the surfaces

- [ ] **e2e contract first** (INV-G3): `data-session-id` on the session row, and migrate
      `solo-e2e` / `restart-e2e` / `fork-e2e`'s three text lookups to the attribute.
      Commit this before any row's text can change, so a red run means a real defect —
      and leave `model-fields-e2e` / `two-plans-e2e` alone: they match the version and
      model lists, which share `.sel-page-item-name`.
- [ ] Title bar text through `App/Labels.titleFor` (INV-G1) + tooltip.
- [ ] Manager: label column content, filter box (reuse `Session/Selector.elm`), sort by
      name while filtering, `✎ Rename`, the editor overlay, with its
      `open / close / input / commit` transitions as pure `Session/Labels.elm`
      functions returning `Label` + effects-as-data (the F-series' rule: ports stay in
      `App/Update.elm`).
- [ ] `KeyDown` stack slot + `EscapeOverlayTest` case (INV-G4).
- [ ] `make check-invariants` extended with INV-G1/G2 sections, including the
      "accessor still exists" anti-vacuity assertion.
- [ ] Gate: full verification. Commit + push ×3.

### G3 — prove it end to end, then distil

- [ ] `e2e/label-e2e.mjs` (add the basename to `e2e/scripts.txt` — a script in no list
      is not a test): name a session → the title bar shows it → a **real backend
      restart** → the manager shows it → Resume → the title bar shows it again → rename
      → the file on disk is the new one → delete the session → the label file is gone
      with the directory. Plus the auto-label case: send a prompt, never name it, and
      the row says something readable.
- [ ] `docs/manual-acceptance.md` §10 (Session identity): the human's checklist,
      including one deliberate corrupt-label-file case (SD-G9) and the unnamed-old-
      session case (SD-G8's known gap).
- [ ] README + README.zh-CN: the "Windows and solo view" section gains the naming
      paragraph, in sync, and the Known Limitations row about old unnamed sessions.
- [ ] `AGENTS.md`: this document joins the tracked-design table; the config-file
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

## Open questions ⚑

1. **Auto-label on by default?** SD-G8 writes a derived name into every new session's
   directory. Some users will read that as the app putting words in their file.
   Alternative: auto-label only in the UI (never persisted), and the manager shows hex
   for closed unnamed sessions — which is the hole this feature exists to close.
2. **Cap at 120, display at 60** — agree with SD-G10's numbers, or is a title bar that
   can be resized wide enough for 120 worth displaying more of?
3. **Node sessions** stay unlisted and unnamed (they already show `[Plan · planId/
   nodeId]`). Confirm the label document is *not* needed under `plans/<planId>/<nodeId>/`
   — i.e. a node session's identity is meaningful only inside its plan.
4. **Old unnamed sessions in the manager**: fall back to the 8-char id (today's
   behaviour) or show `Untitled`? Fallback is proposed; `Untitled` is friendlier and
   would make the id reachable only through the tooltip.
