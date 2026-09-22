# Guidelines for AI Agents

## Before Proposing Changes

1. **Check browser console for errors.** If `init()` crashes partway, some features work while others silently fail—the app looks operational but tracking is dead. Always verify infrastructure is running before debugging logic.

2. **Confirm the baseline.** Is the relevant event listener attached? Is the function being called? Don't assume—verify with console output or user observation.

3. **Find the minimal change.** Start from the working original. Change one thing at a time. If a single variable substitution fixes it, don't rewrite the surrounding logic.

## Code Principles

4. **One source of truth.** Don't duplicate a mechanism that already exists (e.g., JS-side scroll guard when Elm already has `atBottom`). Two parallel systems drift apart and confuse future readers.

5. **Reuse checked variables.** If a DOM lookup is validated non-null at the top of a function, reuse that variable later instead of querying the DOM again. A second lookup can fail unexpectedly (element removed, race condition).

## Language

- **All documents (docs/, README, design notes, archive) are written in English.**
- **No Chinese in code** — comments, identifiers, log strings, and UI text must
  be English. The only allowed exception is **test fixtures that verify Chinese
  text renders/round-trips correctly** (Chinese display effect tests).
- User-facing UI copy is English; keep translations in sync across the codebase.

## Architecture (current)

Three parts share ONE Elm client:

- `src-tauri/` — Rust/Tauri backend. Commands in `commands/*.rs`; TLV frame
  dispatch in `reader.rs`; session lifecycle in `session.rs`. Tests: `cargo test`.
- `src-go/` — Go backend (browser/HTTP+WS), a symmetric port of the Rust one.
  Commands in `internal/server/handlers/`; reader/dispatch in
  `internal/session/`. Tests: `go test -race ./...` (integration tests build
  `fakecore` automatically).
- `src-elm/` — Elm frontend (no bundler). `App/Update.elm` is the message
  dispatcher; Plan Mode logic lives in `Plan/Update.elm` (pure, injects the
  dispatcher as `Dispatch`); window/canvas/zoom/z-index in `App/Windows.elm`
  (pure); the plan state machine in `Plan/Runner.elm` (pure). Per-feature state
  machines are extracted the same way — `Plan/MetaScan.elm` (the plan-meta
  rebuild walk), `Session/Voice.elm` (mic/ASR/raw capture),
  `Session/FilePicker.elm` (picker transitions) — and they return `(state, Int,
  List Effect)` / an `Op` value: **effects are data, ports stay in
  `App/Update.elm`**. A pure module must not import `App.Types` or
  `Plan.Update` (cycle); the caller passes the context it resolved. That cycle
  rule has a consequence worth knowing before you write a module: if a module
  owns a type that a `Model` field uses (`App.UiConfig`, `App.AsrConfig`,
  `Session.ModelConfig`), then `App.Types` imports IT, so it can never import
  `App.Types` back — purity is forced by where the types live, not chosen.
  Slicing message families out of the dispatcher is written up in
  [`docs/update-slices.md`](docs/update-slices.md); six are done —
  `App/AsrConfig.elm`, `App/Presets.elm`, `App/Arch.elm`, `App/SettingsConfig.elm`,
  `App/GlobalConfig.elm` and `Session/Events.elm` (the inbound event arms' routing,
  which cannot reuse the pure shape because it must read the whole `Model`) — and
  the cheap same-shape families are now exhausted
  (the remaining big arms need `Dispatch` injection; see the repo's gitignored
  `TODO.md`). Read that doc before starting another one: it says how to scope a
  family by state WRITTEN rather than by message name, and what made each slice
  verifiable.
  The JS bridge is split: `transport.js` (RPC ports ↔ tauri/http), `chain.js`
  (connection-chain SVG overlays), `overlay.js` (scrollbar/canvas zoom).
  Tests: `elm-test`.

**The two backends must stay symmetric.** Any behavior/protocol change goes
into Go AND Rust together — command-name parity alone does not prevent
behavioral drift (B2: Rust held a lock across a 5s graceful close, Go did
not). `scripts/check-backend-parity.sh` asserts the command names match
(Rust `commands::<name>` == Go `"<name>": Handler` == `transport.js`
`invoke("<name>")`, bridge ⊆ backends).

**NEVER modify AlayaCore.** Capability differences are expressed only through
spawn arguments (`--tool-confirm`, `--builtin-tools`, `--system`, work dir)
and the config files (`model.conf`, `mcp.conf`, `settings.conf`, `global.conf`).

**The protocol is a second thing AlayaCore owns, and this repo duplicates four
facts about it**: the `message_version` pin (both backends), the TLV tag
alphabet (both `tlv` modules), the session states AlayaCore broadcasts (read by
`reader.rs`/`reader.go`, not by the client — see below), and the command names
we send. `make check-protocol`
(`scripts/check-alayacore-protocol.sh`) is the guard: against the core when it
is checked out next door, refreshing `testdata/alayacore-{message-version,tlv-tags,
session-states,commands}.txt`; against those fixtures in CI, where the core does
not exist. It exists because v12 (`CE`, the `closed` state, the `quit` command,
prompts-held-before-ready) landed with the pin at 11 and nothing noticed — the
only symptom was a home-screen banner telling users to *downgrade* their core,
while sessions kept running against a format the adapter claimed not to know.
The check is mutation-verified on all four axes; an extractor that finds nothing
fails as "fix the extractor, do not delete the check".

Two consequences of that split are worth knowing before you touch a reader. A
session's END has one producer: the `core-status connected:false` emitted by the
reader — from the core's terminal `closed` frame if it arrives, otherwise from
EOF — and never from the client's SM handler, because the plan runner fails its
node on every `connected:false` it is told about (`Session/Events.elm
statusEvent`), so a second producer reports one death twice. `handlers.elm`'s
`handleSystemSession` therefore reads `ready` and ignores `closed` on purpose,
and `SessionEventsTest`/`HandlersTest` pin that. Second, stderr is a channel,
not a debug aid: AlayaCore reports the failures that abort startup (an
unloadable session file, a bad config) only there, before any frame exists, so
`spawn` pipes it into a bounded tail and the reader quotes its last line in the
disconnect message. Piping without re-logging every line to the backend's own
log would take output away from a developer to fix a problem on the other side.

And the reason has to reach the SCREEN, which is a separate fact from being
carried: this client shows a failure in the TRANSCRIPT
(`Session.Handlers.appendEndNotice`, applied by `Session/Events.elm` on a
disconnect), not in a status strip — 7c99f83 removed the title-bar status line,
which is why `SessionState.statusMsg` has no reader and why writing it is NOT
the same as telling the user. `e2e/end-reason-e2e.mjs` is what keeps that
honest; a unit test on the message string would pass whether or not anyone sees
it.

Because the bundled core always matches the pin, `resume_session` also REFUSES a
session file whose recorded `message_version` differs — BEFORE spawning, so the
user reads the reason on the row they clicked instead of watching a window open,
die, and then answer every retry with "Session is already active" (the entry was
registered). Unknown is NOT incompatible: a file with no frontmatter (what
fakecore writes), an unreadable file or a non-numeric value goes through to the
core, which owns the load rule. Read + compare + message sit in one function per
backend (`session_file_rejection` / `core.SessionFileRejection`) so the DECISION
is what a test covers.

**`model.conf`: the schema lives in ONE module.** `src-elm/src/Session/ModelConfig.elm`
owns the field list, the `model_list` decoder, the `model_sync` encoder and the
editor form (`Overlay.ModelEditor` renders `ModelConfig.fields` and names no
field itself). This is not tidiness — `:model_sync` *replaces* the list and
AlayaCore rewrites `model.conf` from what comes back, so any field AlayaFace
does not carry is silently DELETED from the user's file on the next save. The
symptom is two hops away ("the REASONING window never appears", "tool calls
overlapped again") and nothing logs it; `reasoning_field`, `serial_tool_calls`
and `reasoning_0/1/2` were each lost this way. When AlayaCore adds a model
field: run `make check-schema` (it diffs `protocol.ModelInfo` against this
repo and refreshes `testdata/alayacore-model-fields.txt`), add the field to
`ModelConfig.fields` with its decode + encode, and `elm-test`
(`tests/ModelConfigTest.elm` pins the round trip). Keys this build does not
know survive via `ModelInfo.extras`, so an unupdated AlayaFace degrades to
"cannot edit" instead of "deletes it".

**A second axis of the same check, because there is a second way to lose a
model.** `make check-schema` also compares `validateModel`'s required keys
against the fields marked `requiredField`/`requiredChoice`, both directions, and
refreshes `testdata/alayacore-model-required.txt`. The consequence of an empty
required field is not a failed save: `syncFromContent` skips entries that fail
validation and `writeConfigFile` persists the SURVIVORS, so the entry is deleted
from `model.conf` and the MODEL_VALIDATION reply only arrives afterwards to
explain what already happened. Refusing at Save is the only place that can
prevent it. The check is symmetric on purpose — marking a key required that the
core does not require blocks saves the core would accept and can strand an entry
(`name` is the live example: not required, so `displayOf` keeps a nameless model
visible instead of the form refusing to save it). A helper whose name begins
with `required` is what the grep reads, so renaming one is caught by the check
rather than silently dropping a key from it.

**`ui.conf` is the same rule in a second file.** `src-elm/src/App/UiConfig.elm`
owns the whole layout-document schema (fields, `decode`, `encode`, `evict`,
`version`, `maxStoredWindows`) and both backends pass the document through as
**opaque JSON**, validating only its shape — that is what lets a newer AlayaFace
save a richer file through an older backend without the older one eating fields
it has never seen. `sync_ui_config` replaces the file, so an unmodelled
per-window field is deleted exactly like a model field above; top-level unknown
keys survive via `Document.extras`, per-window ones do not (the module documents
why). `version` and `maxStoredWindows` are deliberately duplicated numbers:
`scripts/check-backend-parity.sh` compares them across Rust
(`DEFAULT_UI_CONF_VERSION`, `MAX_STORED_WINDOWS`), Go
(`DefaultUiConfVersion`, `MaxStoredWindows`) and Elm, and
`testdata/serialization/ui_cases.json` is the accept/refuse table both backends
run. **When** a write happens is a second policy module, `App/UiLayout.elm`
(`syncUiLayout`/`withUiSave` are the only producers of a payload, and every write
trigger is spelled `withUiSave` so the set is one grep): at the end of an
interaction, never during one.

**`asr.conf` is the same rule in a third file, without the escape hatch.**
`src-elm/src/App/AsrConfig.elm` owns the voice-input profile document (seven
per-profile fields, `active` + `profiles`), the editor state, every transition of
the overlay, and the protocol vocabulary (the three wire protocols, their display
names, and the per-protocol default model id). `sync_asr_config` replaces the
file, and unlike `model.conf`/`ui.conf` there is no carry for keys this build does
not model: all three implementations agree on exactly those field names, so a
field dropped here is a line deleted from the user's config. That is what
`tests/AsrConfigTest.elm` pins by asserting the serialized key list, and what a
deliberately **strict** decode is for — the backends decode into typed structs and
re-serialise every field, so a reply missing one means the shape changed, and
guessing through it would write the guess back. `check-backend-parity.sh` now
compares the protocol list, the default-model table **and the field names**
across Rust, Go and this module — the third copy no longer moves by hand, because
a key the client's encoder omits is a value the user had and the next save
overwrites with the struct's zero. Extracted from the encoder and the structs
only (never a whole file), with a count guard, so a renamed function turns the
check red instead of quietly comparing nothing.

**`session.label.json` is the same rule in a fourth file — one document per session.**
`src-elm/src/Session/Labels.elm` owns the document (three keys `{v, label, auto}`,
plus `usableText`, `normalise`, `autoFromPrompt` and the rename editor's pure
transitions) and `App/Labels.elm` owns the policy: it is the ONLY module that reads
`Model.sessionLabels` or calls `Ports.syncSessionLabel`. `scripts/check-layout-invariants.sh`
section 5 enforces both halves (INV-G1/G2) and carries an anti-vacuity list of the
accessor names, so renaming `titleFor` cannot turn the check green by matching
nothing. `sync_session_label` replaces the file and there is no `extras` carry: three
keys, all modelled, so a dropped one is a line lost from the user's file. Two decisions
are easy to undo by accident — the Model stores the NAME and not the document (the
`auto` flag has no reader there; the SD-G8 guard is "an entry exists"), and the client
is deliberately the STRICTEST of the three implementations about length, because Elm
counts UTF-16 units where Go counts runes and Rust counts `chars()`.

**Not every config file is written the same way — check before you add a field.**
`model.conf`, `ui.conf`, `asr.conf`, `global.conf` and `session.label.json` are all
**REPLACED** by their sync command (the backend decodes into a typed struct, or takes the client's whole
document, and writes it back), so a key the client does not model is a key deleted
from the user's file. `settings.conf` is the exception: `sync_global_settings`
**MERGES** in both backends — only the keys present in the payload are applied, and
the Go handler says so in so many words — so a hand-added key survives, and a
partial save is the documented way to change one field. Consequences differ: the
replace group needs a byte-exact key-list pin (`tests/AsrConfigTest.elm` has one;
dropping a field fails five tests), while `settings.conf` needs its tests about the
round trip instead (a failed read must not blank the form; a save still sends the
whole form so a stale editor cannot write half of it). A **third** shape exists:
`sync_default_mcp` replaces its file too, but both backends validate the whole
payload and refuse before storing anything, so one bad server costs the save
rather than deleting that server quietly — which is why the MCP editor has no
client-side `problems` and the model editor must have one. Determine which of the
three a file is before adding a field, and before copying a validator.
`global.conf` holds one key
today, `recursion_limit`, whose default `8` is triplicated — `DefaultRecursionLimit`
(Go), `DEFAULT_RECURSION_LIMIT` (Rust), `defaultRecursionLimit`
(`App/GlobalConfig.elm`) — and `scripts/check-backend-parity.sh` now compares all
three.

## Verification (run before every commit)

```bash
make test-go                        # go vet + go test -race ./...
cd src-elm && elm make src/Main.elm --output=/tmp/m.js && elm-test
cd src-tauri && cargo test          # (and cargo clippy --lib: no errors)
./scripts/check-backend-parity.sh
make check-invariants               # windowPositions read path + JS-bridge freeze
make check-schema                   # model.conf fields vs AlayaCore
make check-protocol                 # message_version, tags, session states, commands
make check-css                      # stylesheets the browser can actually parse
make e2e                            # every script in e2e/scripts.txt
```

`make e2e` and CI both drive the list in **`e2e/scripts.txt`** — do not
hand-copy it into either runner. Four scripts had rotted (Phase 7's
button/overlay restyle renamed the selectors they matched) purely because
they were in no list anyone ran: CI executed 2 of 12 and `make e2e` 7.
A script that nothing runs is not a test.

**When an e2e suite fails on CI and passes locally, read the annotation before
blaming your change.** `pt-e2e` has failed this job three times. On `111085b` the
failure provably was not caused by the commit: `pt` never opens the Session
Manager (no `.sel-page-item`, no `list_session_dirs` anywhere in the file), and
that was the only thing the G-series change touched on its way. The two earlier
failures (`c4a749e`, `0406cc5`) were Elm dispatcher refactors, which sit closer
to pt's path, so they are not evidence of a pure flake — they are evidence the
suite is sensitive to something. All three announced themselves as
`e2e pt failed` and nothing else, while the detail sat in a job log that needs
repo admin to fetch. The CI step now quotes the failing assertion into the
annotation and puts the last 40 lines in the job summary — read that first. Do
NOT "fix" a suite that flakes there and passes here by adding a retry: it is a
real signal about a real environment, and re-running it until it goes quiet
destroys the only evidence. If the same quoted assertion fails twice more, that
is a bug worth chasing, and the usual shape to look for is a fixed `sleep()`
guarding something asynchronous.

**The two backends are behaviorally symmetric, not just name-symmetric.**
`check-backend-parity.sh` only proves command names match; it cannot see a
divergent error path, default, or byte range — those have been found by
reading both sides (see the B-series and the reasoning-level / MIME / WAV
slicing fixes). When you change behavior, change Go AND Rust in the same
commit, and say in the message which twin you checked.

## Where the design lives, and how to resume work

Tracked design documents, one per area — read the one you are touching:

| Document | Covers |
|---|---|
| `docs/solo-view.md` | solo view, the one-geometry rule (`winRect` / `layoutRects`), what may write `soloWin`, gesture refusal, reachability, and the `ui.conf` layout store (scope, write policy, what a file may never decide) |
| `docs/session-identity.md` | the per-session label (`session.label.json`): which file may hold it and which may not, the document/policy module split, `maxLabelChars` as the next parity scalar, why its write is its own command, and what "find it again" may not claim about content search |
| `docs/plan-mode.md` | Plan Mode: detection, meta, runner, cascade, node sessions |
| `docs/touch-design.md` | the unified pointer/gesture FSM (D1–D5) and what the bridge may classify |
| `docs/arch-persistent.md` | the Arch version/refs model (C-series) — what is persisted per session, which client module owns which half, and the two asymmetries (refs is not an object; a get reply cannot be routed to its asker) |
| `docs/update-slices.md` | how to slice a message family out of `App/Update.elm`: how to measure which family is cheap, the two module shapes and the cycle rule that forces one of them, what resisted, and what made each completed slice verifiable (the list is in Architecture above, so this row cannot go stale) — including replace-vs-merge semantics per config file, why an extracted arm is only testable if its effects leave as data, and how to tell a mutation check that worked from one that silently did not |
| `docs/go-backend.md` | the Go transport: RPC/WS mapping, per-command table, storage |
| `docs/overlay-focus.md` | why overlay focus goes through `focusAfterDelay` |
| `docs/manual-acceptance.md` | the checklist a human runs before calling a UI change done |
| `docs/archive/` | closed series as history: P/R (`TODO.md`, `REFACTOR.md`, `go-backend-todo.md`), P39, and the F-series working file (`TODO-f-series.md`). Tracked **history**, not live plans |

**Interrupt recovery:** this file (rules + verification + what `scripts/`
enforces) → the `docs/` row for the area → `git log --oneline`. Root `TODO.md` is
**gitignored scratch**, and since the F-series closed it has carried no plan: if a
task says "check the TODO", it means the archive. A phase list in a file nobody
tracks is how a finished feature gets re-opened by the next reader.

Every phase of any future series: implement → full verification below → `git
commit` → push to **all three remotes** (`origin`, `gitee`, `org`, branch `main`)
and verify with `git ls-remote`.

## Routing: tagged fs ports (B3/B4)

`fsListDir` and `fsReadFileText` are shared by TWO flows: the plan-meta scan
(sessions/ → plans/ dirs → *.meta.json rebuild) and the normal UI flows
(session manager, file picker, plan open/load). Responses are routed by
**reqId** (`fs-N`, allocated by `nextFsReq` in `Plan/Update.elm` and mirrored by
`MetaScan.allocReqId` — the two formats must never diverge, because they share
one counter): a response whose reqId matches `model.planMetaScan.scanReqId` or
`model.planMetaScan.readReqId` belongs to the meta scan, one matching
`planReadTarget` belongs to the single-file plan read, and anything else belongs
to the UI. The scan's own state is the single `planMetaScan` record
(`Plan/MetaScan.elm`) — the ten flat `planMeta*` fields it replaced are gone.
Never route by global
flags alone — a user listing racing the scan would be swallowed (stuck file
picker) or parsed as plan dirs (corrupted scan). `fsHomeDirResult`,
`fsReadFileUriResult`, `sessionDirsResult` are untagged but fire once per
request (no shared-flow ambiguity).

## History

`docs/archive/` holds the archived P/R-series design notes (`TODO.md`,
`REFACTOR.md`, `go-backend-todo.md` were archived there — they are tracked
history, not live working files).
