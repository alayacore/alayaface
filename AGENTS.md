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
  [`docs/update-slices.md`](docs/update-slices.md); five are done —
  `App/AsrConfig.elm`, `App/Presets.elm`, `App/Arch.elm`, `App/SettingsConfig.elm`
  and `App/GlobalConfig.elm` — and the cheap same-shape families are now exhausted
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
guessing through it would write the guess back. `check-backend-parity.sh` compares
the protocol list and the default-model table between Rust and Go but **not**
against this module, so the third copy moves by hand: all three together, or none.

**Not every config file is written the same way — check before you add a field.**
`model.conf`, `ui.conf`, `asr.conf` and `global.conf` are all **REPLACED** by their
sync command (the backend decodes into a typed struct, or takes the client's whole
document, and writes it back), so a key the client does not model is a key deleted
from the user's file. `settings.conf` is the exception: `sync_global_settings`
**MERGES** in both backends — only the keys present in the payload are applied, and
the Go handler says so in so many words — so a hand-added key survives, and a
partial save is the documented way to change one field. Consequences differ: the
replace group needs a byte-exact key-list pin (`tests/AsrConfigTest.elm` has one;
dropping a field fails five tests), while `settings.conf` needs its tests about the
round trip instead (a failed read must not blank the form; a save still sends the
whole form so a stale editor cannot write half of it). `global.conf` holds one key
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
make check-css                      # stylesheets the browser can actually parse
make e2e                            # every script in e2e/scripts.txt
```

`make e2e` and CI both drive the list in **`e2e/scripts.txt`** — do not
hand-copy it into either runner. Four scripts had rotted (Phase 7's
button/overlay restyle renamed the selectors they matched) purely because
they were in no list anyone ran: CI executed 2 of 12 and `make e2e` 7.
A script that nothing runs is not a test.

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
| `docs/plan-mode.md` | Plan Mode: detection, meta, runner, cascade, node sessions |
| `docs/touch-design.md` | the unified pointer/gesture FSM (D1–D5) and what the bridge may classify |
| `docs/arch-persistent.md` | the Arch version/refs model (C-series) — what is persisted per session, which client module owns which half, and the two asymmetries (refs is not an object; a get reply cannot be routed to its asker) |
| `docs/update-slices.md` | how to slice a message family out of `App/Update.elm`: how to measure which family is cheap, the two module shapes and the cycle rule that forces one of them, what resisted, and what made each of the three slices done so far (`App/AsrConfig`, `App/Presets`, `App/Arch`) verifiable — including replace-vs-merge semantics per config file and how to tell a mutation check that worked from one that silently did not |
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
