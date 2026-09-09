# Slicing message families out of the dispatcher

`App/Update.elm` is the largest file in the frontend and the reason the dispatcher
is hard to hold in your head. This is the record of splitting it by message
family: what the shape is, what resisted, and the checklist for the next one.
Nothing here is urgent — it is mechanical work that is cheap only if the method is
already written down.

The first slice is done: **`App/AsrConfig.elm`** (the `asr.conf` overlay — profile
list, edit form, delete confirm, both replies), landed 2026-09-09. Then four more
the same day: **`App/Presets.elm`** (the Preset Manager — 17 arms), **`App/Arch.elm`**
(the freeze queue and object-store replies — 6 arms + 2 helpers),
**`App/SettingsConfig.elm`** and **`App/GlobalConfig.elm`** (the two config editors,
15 arms between them). All five are the worked examples below; where they differ is
in "What the second slice taught", "What the third slice taught" and "What the
fourth and fifth taught".


## Measure before choosing

Every number in a doc like this is stale the moment the file changes, so take your
own:

```python
# arm sizes of the dispatcher's outer `case msg of`
import re
lines = open('src-elm/src/App/Update.elm').read().split('\n')
pat = re.compile(r"^        ([A-Z]\w*)\b")          # 8 spaces = outer arm
hits = [(i, pat.match(l).group(1)) for i, l in enumerate(lines)
        if pat.match(l) and not l.startswith('         ')]   # 9+ = nested
```

The 8-vs-9-space test is what makes it accurate. A first pass keyed on arms whose
line *ends* with `->` and silently merged every arm whose body started on the same
line as its arrow — which inflated one file-system arm from 24 lines to 124 and
made the wrong cluster look like the best candidate. Measure the arm you are about
to move before you move it.

For each candidate family, the number that decides feasibility is not its size but
its **coupling**: which dispatcher-local helpers its arms call, how many are its
own private decoders (movable with it), and how many `Task.perform` / `Process.sleep`
it emits.


## What resists, and why

Three things, all found by reading the arms rather than by guessing:

- **Arms that mutate the model mid-flight and re-enter `update`.** The frame /
  status / delta event arms (~400 lines) route into `ForSession` recursively and
  schedule their own timing commands. Splitting them means passing a dispatcher
  around, which is what `Plan/Update.elm` does with `Dispatch` — workable, but it
  is a different and larger change than a slice.
- **Arms whose body IS the glue.** The pointer arms are already thin: the FSM
  lives in `App/PointerFsm.elm`. Extracting a second wrapper around a wrapper
  moves lines without moving decisions.
- **The shared helpers.** A slice module that takes `Model` would have to import
  `App/Update.elm` for helpers like `updateActiveSession`, and Elm forbids the
  cycle. This turned out not to bind: none of the 42 `Model`-taking helpers in the
  dispatcher is referenced from any other module, so they can be moved or
  duplicated freely. Re-check that claim before assuming it.


## The two shapes a slice can take

**Schema owner** (`App/UiConfig.elm`, `App/AsrConfig.elm`,
`Session/ModelConfig.elm`) — the module owns the types that `Model`'s fields use.
`App.Types` imports it, so it can **never** import `App.Types` back: purity is
forced by the cycle rule, not chosen. This is the good shape, and it is why
`App/AsrConfig.elm` is pure even though the code it replaced was not.

**Model-aware policy** (`App/UiLayout.elm`) — takes `Model`, returns
`(Model, Cmd Msg)`. Available when the module reads the whole board rather than
one feature's state, and the reason F3 needed two modules: `UiConfig` owns the
document and `UiLayout` folds it into `Model`. A feature whose state fits in two
fields does not need the second one.

Effects leave as **data** either way (`Action` / `Op` / `Effect`), and one small
mapper in `App/Update.elm` turns them into port calls. That mapper is what keeps
"which code can write this file" a single grep — `applyAsrAction` here, the
`withUiSave` set for the layout store.


## Purity is not what makes a slice safe

Moving code is only verifiable if something can tell you it moved wrong. Three
things did the work on the first slice:

1. **The existing suite drove these arms already** — `VoiceInputTest.elm` has ~200
   lines that send the ASR messages through `App.Update.update`. It stayed green
   unchanged, which is the actual behaviour-preserving proof.
2. **The transitions became unit-testable for the first time.** They had never been
   tested in isolation, only through the dispatcher. `tests/AsrConfigTest.elm`
   (38 cases) pins them directly, including the two that only ever hurt later: what
   a write may claim before the backend agrees, and what `close` refuses.
3. **A mutation check.** Deleting one field from the encoder must fail something —
   it fails five tests. A green suite that stays green when you break the code is
   not evidence, and that is the only way to know which of the two you have.

Note the trap in (1): `VoiceInputTest` covers the arms through `update`, so it
catches a mis-transcribed arm. It would NOT catch a schema field going missing,
because nothing reads the file back and compares. That is what (2) and (3) are for.


## What the second slice taught

Three things the first one could not show.

**Build a reply fixture the way the transport builds one.** A test here — "a failed
read keeps the rows the user is looking at" — failed at first, and the product was
innocent: I had written the failure body as `{ ok: false, error: … }`, while
`transport.js` sends `{ ok: false, presets: [], error: … }` so the strict decoder
is satisfied. Fixing the fixture made the test worth having, because the real reply
carries an empty list and the transition must *not* adopt it: adopting it would
empty the manager on a transient backend error. So an unrealistic fixture is not
merely a failing test — it hides the one behaviour most worth pinning. Check the
`.catch` branch in `transport.js` for any command whose reply you imitate (`asr.conf`
has the same shape: it synthesises `profiles: []` too).

**A view module may be holding a duplicate copy of the shape you are moving.**
`Overlay/PresetManager.elm` defined its own `PresetInfo` alias, structurally
identical to `App.Types`'. Elm's record typing means a divergence is caught by the
compiler rather than silently accepted, so this is duplication and not danger — but
unify it while you are in there, or the next reader has two shapes to reconcile.

**Read the dispatcher's `exposing` list before moving a helper.** Two of these
helpers were public API of `App/Update.elm`: `movePreset` was used by nothing but
its own test (which moved with it, and now names the module that owns the
arithmetic), and `nextCopyName` was imported by `App/View.elm` and never called —
a dead import that only surfaces when something forces you to look. An unused
exposed name produces no warning, because the module is used for the others.


## What the third slice taught

The third slice was **`App/Arch.elm`** — the freeze queue and the object-store
replies (6 arms, and the two helpers they own). Two things it showed that the
first two could not.

**Define the family by STATE, not by message name.** Six arms mention the object
store in their name; the freeze path also owns `startNextFreeze`, and — the part
that matters — the queue it drains has a SECOND writer in `Plan/Update.elm`, which
enqueues a freeze when a run finishes and starts that first item itself. So the
"one freeze at a time" invariant is held across two modules and cannot be made
local. Move the code and the rule disappears from sight; the fix is to say so in
the module comment, with the grep that finds every writer.

**A Model-aware slice can still return effects as data, and should.** The first
draft followed `App/UiLayout` and returned `(Model, Cmd Msg)`. It compiled, the
suite stayed green, and the interesting behaviour became untestable: which path
the refs file goes to, which `reqId` the version object gets, whether a failed
write drops the queue. `Cmd` is opaque — a test can only see the model. Returning
`List Action` instead costs one mapper in `App.Update` and bought 18 tests that
assert the commands themselves. Choose the `UiLayout` shape for what it is good at
(needs the whole `Model`), not as a licence to return `Cmd`.

**Assert that your mutation actually applied.** One mutation here appeared not to
be caught by the test that should catch it — and the test was fine. The mutation
had never been applied: the anchor string did not match the nested indentation, and
a `replace` with a non-matching needle is a silent no-op. A mutation check that
didn't mutate reports "your tests are weak", which is worse than no check because
it is unfalsifiable. Print the changed line, or assert the replacement count.


## What the fourth and fifth taught

The two config editors (`App/SettingsConfig.elm`, `App/GlobalConfig.elm`) were
planned from a name-based measurement of "11 arms, 254 lines" and turned out to be
**15 arms, 314 lines**.

**Scope by state WRITTEN, not by message name — and then separate reads from
writes.** The four field setters were named `SetToolConfirm`, `SetBuiltinTools`,
`SetSystemPrompt` and `SetRecursionLimit`: none contains "Settings"/"Global", all
four write the editors' state. Grepping for the fields instead caught them — and
also caught `KeyDown`, 166 lines that merely READS `settingsEditor.show` to route
Escape. A field grep is therefore the start of the scoping, not the end: writes
define the family, reads are the family's customers.

**Whether a save merges or replaces decides what the tests should be about.**
`sync_global_settings` MERGES (both backends apply only the keys present in the
payload, and the Go comment says so explicitly), so an unmodelled key in
`settings.conf` survives and there is no byte-exact key-list pin to write; what
matters instead is that a failed read does not blank the form the user is typing
into, and that a save still sends the whole form so an editor cannot write a stale
half of it. `global.conf` is the opposite — both backends decode into a typed
struct and write that struct back, so it is REPLACE semantics, and its one default
(`8`) was triplicated across Go, Rust and Elm with nothing comparing them. Slicing
a family is when these semantics get written down; do not leave it for the next
person to rediscover from the handlers.

**A slice can expose a gate gap; fix it in the same commit.** Adding the
recursion-limit comparison to `scripts/check-backend-parity.sh` also surfaced that
`check_scalar` hardcoded "Rust:"/"Go:" in its messages while already being used for
"Rust vs Elm" checks — so two existing checks were printing an Elm value under a
"Go" label. Values are now printed neutrally, since every call site's label already
names both sides. Verify a new parity check by MUTATING one side and asserting both
the failure and the non-zero exit code: a check that never fails is decoration, and
`| tail -1` in a pipeline will happily report exit 0 for it.

**The mutation harness must assert its own anchor.** The helpers here `assert
s.count(old) == 1` before replacing anything; that is what turned the earlier false
negative ("my test didn't catch it") into the real finding ("my mutation never
applied").


## For the next slice

1. Pick by coupling, not size. Re-measured 2026-09-09 after five slices:
   `App/Update.elm` is 6737 lines and its `update` body 4414 lines over 235 arms.
   The cheap same-shape families are gone; what is left is either large-but-coupled
   or small-and-already-thin:
   **`Session`** lifecycle (4 arms, 194 lines: `SessionCreated`,
   `SessionCreateError`, `CloseSession`, `DeleteSession`) is the strongest
   remaining candidate, but it is entangled with window creation
   (`createSessionWindow`, `resumeSessionCreated`, `forkSessionCreated`), so it is
   an `App/Windows`-shaped change rather than a family slice.
   **`Fs`** (6 arms, 342 lines) is the biggest-looking cluster and the least
   sliceable: its arms ARE the glue between the file picker and `Plan/MetaScan`,
   they route through `updateActiveSession`, and moving them would move no
   decision. The **voice runtime** arms (`AsrResult`, `PushToTalk`, `VoiceError`,
   `RawAudio*`, `CursorPosResult`, ~280 lines over ~10 arms) are already thin
   wrappers over `Session/Voice.elm` — the machine exists, so the work there is
   consolidating effect mapping, not extracting state.
   Everything bigger needs the `Dispatch` injection written up in `TODO.md`
   (root of the repo, gitignored): `FrameEvent` (250 lines), `KeyDown` (166),
   `StatusEvent` + `DeltaEvent` (~150) and the 26 `Plan` orchestration arms (819).

2. Decide which of the two shapes applies BEFORE writing — if `Model` will reference
   your types, you have chosen the pure one and must pass every input explicitly.
3. Move the private helpers first (decoder + encoder + the type definitions), so the
   compiler lists every call site for you. `App.Types` exposing a type alias you
   moved is a compile error in every consumer, which is exactly the inventory you
   want; expect it in `Main.elm` and `tests/TestHelpers.elm`.
4. Rewrite the arms mechanically, then confirm the build has **zero** warnings — an
   import left behind is silent otherwise.
5. Add the transition tests after the move, while the semantics are fresh, and
   mutation-check the one that would hurt most.
6. `make e2e` before committing: the dispatcher owns gesture and timing paths that
   `elm-test` cannot reach.

Two Elm syntax rules that cost time on the first pass, both from the same cause —
a record update needs a plain variable base: `{ AS.emptyEditor | show = True }` and
`{ profile "p2" | id = "x" }` are both parse errors. Bind a `let` name first.

And one about this repo's test harness: `elm-test` collects **every** exported
`Test` value in a module, not just `tests` (verified with a scratch module). A suite
left unexported is silently not run — which is why `AsrConfigTest` builds one
aggregate `tests` from its suites instead of relying on the collection rule.
