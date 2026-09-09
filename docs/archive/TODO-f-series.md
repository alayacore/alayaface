<!--
  ARCHIVED (2026-09-09): the F-series working file, kept as the record of how solo
  view and the layout store were decided — the SD/INV tables, the phase checklists
  with their commit hashes, and the reasoning that never made it into a commit
  message. NOT a live working file: F0–F4 shipped, the harness's "read this to
  continue" instructions are obsolete, and the tracked design now lives in
  docs/solo-view.md (with README.md for behavior and AGENTS.md for the rules that
  are enforced by scripts). Anything still open here (the Q quick-window, the
  §Later items) is a proposal, not a plan.

  F4.2 and F4.3 are the last two unchecked boxes below, and they were completed BY
  this archiving act (docs/solo-view.md + the AGENTS.md re-read), so they are left
  unticked here on purpose: the box and the archive are the same change.
-->

# TODO (archived): Solo View (F-series) — one window filling the viewport



Tracking file for the **solo view** feature: a presentation mode where the
topmost window (a session OR a plan) fills the viewport alone, with one click
back to the canvas. Design decisions below are **confirmed by the user** — do
not re-litigate them in code; if one proves wrong, update this file first.

> Anchored at commit `a14ae80`. **Line numbers drift — treat function names as
> the anchor and re-`grep` before editing.**
> This file is a gitignored working file (`.gitignore:/TODO.md`). When the
> series ships, distill the design into `docs/solo-view.md` (tracked, English)
> and archive this file to `docs/archive/`, per the repo convention.

## How to continue after an interruption (read first)

1. Read `AGENTS.md` (architecture, verification matrix, the two rules this
   feature lives or dies by: **#4 one source of truth**, and "no behavior
   decision in JS — Elm owns it").
2. Read this file: **SD1–SD19 = confirmed decisions**, **INV1–INV7 = invariants**,
   then the progress table. Start from the first `[ ]` in the earliest
   non-complete phase. Never skip F0 to get to F1. **Every open question in the
   F-series is already answered** — if you think one needs re-opening, change the
   decision row here first and say so in the commit message.
3. Every phase: implement → full verification (§Verification) → `git commit` →
   push to all three remotes (`origin`, `gitee`, `org`, branch `main`) →
   `git ls-remote` to confirm.
4. Update the checkboxes AND the progress table as you go, in the same commit.
5. F0–F2 touch **Elm only** — no Rust, no Go, no new commands. If you find
   yourself editing `src-tauri/` or `src-go/` during F0–F2, stop: backend work
   belongs to F3, whose design is already settled below (§F3) — it is not an
   F1 detail to discover on the way.
6. **Working-tree hygiene, learned the expensive way in F1:** never `git
   checkout -- <file>` (or `git stash`) to undo one experiment in a file that
   holds uncommitted work. Two negative tests of
   `check-layout-invariants.sh` did exactly that and deleted most of F1's
   `App/Update.elm` and `App/View.elm` edits — twice, the second time *after*
   the work had already been rebuilt. Copy the file to `/tmp` first, or run the
   experiment on a `cp -r` of the tree. And commit as soon as a phase is green:
   the commit is the only undo that works.

## Progress

| Phase | Scope | State | Commit |
|---|---|---|---|
| F0 | Pure refactor: one accessor for effective window geometry + invariant check | [x] done | `92c923a` |
| F1 | Solo view: state, derivation, interaction gating, chain, focus-follows-create | [x] done | `2c41a18` |
| F2 | Reachability: ⋯ menu button, attention badge, Ctrl+W / Esc ordering | [x] done | `116e1d3` |
| F3 | Layout persistence via `ui.conf` (Go + Rust symmetric) — scope decided (SD15–SD17) | [x] done — storage layer `58bd111`, client half (§F3-B) landed 2026-09-09 (ports + store, validated restore, interaction-end writes, prune/LRU, 34 elm-tests, `solo` §12 restart case) | `58bd111` |
| F4 | Dead-state cleanup + docs distillation | [ ] | |
| SD19 | Solo renders no ✕ (closing a window is a canvas-view act) + window content always spans the window, blocks bounded top/bottom only (user request) | [x] done | |
| H1 | Opportunistic: `pendingEvents` unbounded buffer (independent commit) | [x] done | `a20fad0` |
| Q | Quick window (OS hotkey, ephemeral session) — **explicitly not now** | [ ] blocked, see §Later | |

**Push status:** F0 `92c923a`, F1 `2c41a18`, F2 `116e1d3`, H1 `a20fad0`, F3-part-1
`58bd111`, guard fix `cd3d042` — all on `gitee`, `origin` and `org` (tracking
refs agree; `cd3d042` verified on all three). github.com (`origin`, `org`) is
FLAKY from this box, not dead: the ssh tunnel through `nc -x 127.0.0.1:7890`
connects and then often stalls until timeout — the fix is to retry the push 2–4
times and treat the push's own `a14ae80..2c41a18 main -> main` / "Everything
up-to-date" line as the evidence, because a hung `git ls-remote` does NOT mean
the commit is missing. gitee answers first try.

**One process rule this series earned twice:** re-run the WHOLE §Verification list
after the last file you created, not after the last one you remember. `cd3d042`
exists because F3-part-1's commit message claimed `make check-invariants` had
passed; it had not been run since `App/UiConfig.elm` was added, and that file
tripped the guard. The gate was right and the log was wrong — so the lesson is
not "be more careful", it is "the claim is only earned by the last run".



## Verification (identical for every phase; from AGENTS.md)

```bash
make test-go                                   # go vet + go test -race
cd src-elm && elm make src/Main.elm --output=/tmp/m.js && elm-test
cd src-tauri && cargo test && cargo clippy --lib   # clippy: zero errors
./scripts/check-backend-parity.sh
./scripts/check-layout-invariants.sh            # added by F0
make check-schema
make e2e                                       # every script in e2e/scripts.txt
```

Manual smoke (Tauri, `make run`): create 3 sessions → enter/exit solo on each →
resize/pan/zoom absent in solo and restored after exit → a plan window can go
solo → **no ✕ anywhere while solo** (the bar is ⤡ +  only), and the ✕ is back
after exiting → close a window from canvas view → the canvas comes back with all
layouts intact. While there: drag a window wide and confirm the messages, the
message blocks and the input box span it (no reading column left behind), and
each block is bounded by a rule above and below with nothing on its sides.

---

## The feature, in one paragraph

Today there is exactly one presentation: an infinite canvas
(`#main-content` → `.canvas` → N `.session-panel` + M `.plan-panel`). Solo view
shows **one** window, filling the viewport, and hides (does not close) every
other window; one button returns to the canvas. It is a **presentation** state,
not a new identity, not a new window, not a new session kind.

### Naming (why "solo" and not "focus")

The codebase already uses "focus" for **z-order raising** (`raiseWindow`'s doc
comment: "Focus a window (D6)"), plus `activeId` / `planActiveId`. Reusing
"focus" for a second concept is how a maintainer gets the two mixed up. Use
**solo**: field `soloWin : Maybe String`, msgs `SoloWindow/ExitSolo/ToggleSolo`,
CSS `.main-content-solo`, accessor `isSolo : Model -> Bool`.

---

## Confirmed decisions

| # | Decision | Status |
|---|---|---|
| SD1 | Solo = **presentation only**. Every window stays alive: streaming, `taskRunning`, tool confirms, MCP auth, plans, work copies, version freezes — all continue untouched. Solo never calls `close_session`, never truncates, never writes refs. | ✅ confirmed |
| SD2 | `soloWin : Maybe String` — a key in the **existing `windowPositions` key space**, which already holds both session ids and plan ids (`raiseWindow` disambiguates by "which dict contains it"). **No new identity type** (`WinKey` was proposed and rejected: it duplicates an existing mechanism). | ✅ confirmed |
| SD3 | Solo works for **session AND plan** windows. Opening a plan from a solo session moves solo onto the plan window. This is what makes "solo + Plan Mode" coherent without a modal system. | ✅ confirmed |
| SD4 | `windowPositions` remains the **single source of truth for canvas layout**; entering/leaving solo **never writes it**. No restore-rect bookkeeping. | ✅ confirmed |
| SD5 | Effective geometry is **derived**, read through **one accessor** (`winRect`). The alternative — mutate `windowPositions` to viewport size and stash a restore rect — was rejected: it creates a second geometry, must track OS resizes (`RequerySize`), z-rebase interactions, and dangling restore state. Derived state auto-follows viewport resize and exiting solo is free. | ✅ confirmed |
| SD6 | DOM must **match** the model: non-visible windows are **not rendered** (no `display:none`), resize handles and the plan info window are **not rendered** in solo (no CSS hiding of state that the model thinks exists). The pointer pipe classifies by DOM class — hidden-but-present DOM is a lie that eventually produces a drag on an invisible window. | ✅ confirmed |
| SD7 | **Behavior decisions live in Elm.** `transport.js` / `overlay.js` / `chain.js` get **zero changes** in F1–F2 (verified by `git diff --stat`). The wheel-zoom listener keeps sending; `CanvasZoom` / `CanvasZoomReset` return `(model, Cmd.none)` in solo. JS stays a dumb pipe (its own comment says so). | ✅ confirmed |
| SD8 | New session created **by the user** while solo → solo follows the new window. New window created **by the plan runner** (node session) → does **not** steal solo; it appears in the canvas and is counted by the attention badge (SD11). | ✅ confirmed |
| SD9 | Solo **auto-exits** when its window closes / on delete / when a cascade closes it. Never leave `soloWin` pointing at a key that is gone (see INV2's two-layer guard). | ✅ confirmed |
| SD10 | **Revised by the user (2026-09): `Ctrl+W` is not a close key at all.** It closes nothing and confirms nothing in canvas view — fully inert — and in solo it does NOT return to the canvas either (SD18 — the ⤡ button is the only way back). Closing a window belongs to its ✕ alone (visible, per-window, always asks first). The original row read "`Ctrl+W` in solo exits solo and does not close (the classic close-my-app-window accident)", which still assumed the key closed the topmost window outside solo; that half is gone. It also said "closing the solo window through its ✕ still closes that window and then exits solo (SD9)" — that sentence is superseded by SD19: in solo there is no ✕ to close with. | ✅ superseded |
| SD11 | **Reachability invariant**: no modal may become unreachable because its window is hidden. A `⋯` button in the solo bar opens the global menu (right-clicking the canvas is impossible in solo — the panel covers it), and the "exit solo" control carries a live count of windows needing attention and of running tasks. | ✅ confirmed |
| SD12 | `Esc` exits solo, inserted **last** in the existing overlay-close chain (so open overlays/media preview close first) and never closing `ConfirmTool` — both existing rules preserved. | ✅ superseded by SD18 |
| SD18 | **Only a pointer control leaves solo.** The ⤡ button and the global menu's "Exit solo" — nothing else. No keyboard chord exits: `Ctrl+W` is inert (see SD10), `Esc` closes an open overlay and then stops (see SD12), and `Ctrl+Shift+F` ENTERS but never leaves. Rationale from the user, after F2 shipped: the keyboard is where typing and reflexes live, and both exiting and not-exiting must be predictable from the keys alone — a view whose panel covers the whole screen makes "Ctrl+W changed what I see" indistinguishable from "Ctrl+W closed my window", whatever the code did. | ✅ confirmed |
| SD19 | **Solo renders no ✕ at all** (user request, 2026-09): closing a window belongs to canvas view. While a window is solo its bar carries exactly two controls — ⤡ (leave) and ⋯ (the global menu) — and nothing that destroys the session behind the presentation; the last sentence of SD10 ("closing the solo window through its ✕…") is gone with it. The button is not rendered rather than styled away (SD6), and `RequestCloseSession`/`PlanClose` have no other sender, so the absent button is the whole rule — no second gate to keep in sync. SD9 still holds for the closes that do not come from a ✕: a Session Manager delete (reachable in solo through ⋯), an ownership-graph cascade, the runner dropping a node session. | ✅ confirmed |
| SD13 | The **connection chain is a canvas feature**: in solo, `setConnectionChain` gets an empty payload; on exit it is recomputed and re-sent explicitly (never rely on `List.isEmpty` to save us). | ✅ confirmed |
| SD14 | Solo is **not persisted in F1–F2** (restart → canvas). Persistence is F3 and lives in a **new `ui.conf`**, never in `global.conf`: `sync_global_config` **replaces** the file, so a half-modelled schema silently deletes the fields it does not carry — the exact `model.conf` trap documented in AGENTS.md. | ✅ confirmed |
| SD15 | **F3 scope = the whole layout**, not just the solo flag: every window's rect + `canvasOffset` + `canvasScale` + `soloWin`. Rationale: persisting "solo" while the board layout is still lost on restart is a half-measure, and the current behavior (restart re-cascades everything through `centeredSessionPos`, so an 8-window board comes back shuffled) is a defect users would report by itself. One coherent piece instead of two. | ✅ confirmed |
| SD16 | **F3 write policy = at the end of an interaction** (drag/resize pointerup, zoom settled, window create/close, solo enter/exit, session close) **plus a best-effort flush on `beforeunload`**. No per-frame writes and **no periodic save timer**. One exception, because it has no natural end event: wheel-zoom bursts use a **single one-shot idle debounce (~1 s)** — the timer fires once to flush, it never polls. The unload flush is *explicitly best-effort*: over the Go transport it cannot carry the `Authorization` header (`sendBeacon` cannot set headers) and over Tauri the webview is being torn down — so correctness must not depend on it, and the interaction-end writes are what make that acceptable. | ✅ confirmed |
| SD17 | **F3 persists geometry only — never `z`, never the order lists.** `nextZIndex`/`z` are derived mutable state that `rebasePositions` deliberately shrinks; storing them would smuggle a stale stacking model into a fresh process. Stacking after a restart follows creation order, which is what `sessionOrder`/`planOrder` already encode. | ✅ confirmed |

## Invariants (checkable, not aspirational)

- **INV1** Every *read* of effective window geometry in `App/View.elm` /
  `App/Update.elm` goes through `Win.winRect` / `Win.hasWin` / `Win.winRectList`.
  `App/Windows.elm` owns the accessors. Enforced mechanically:
  `scripts/check-layout-invariants.sh` fails on any
  `Dict.get|Dict.member|Dict.toList .*windowPositions` in `App/View.elm` /
  `App/Update.elm`, and counts the remaining in-`Windows.elm` reads so they can
  only shrink.
  **Verified baseline (`a14ae80`): 13 read sites in 3 files** — `App/Update.elm`
  6 (`planFocusAboveSession:153,156`, `resumeSessionCreated:804`,
  `createSessionWindow:948`, the `bringIntoView` read at `:1014`, `armDrag:6661`),
  `App/View.elm` 2 (`viewSessionPanel:150`, `viewPlanPanel:756`),
  `App/Windows.elm` 5 (`raiseWindow:300`, `chainPayload:347`,
  `planPositionBelowSession:492`, `nodeSessionPositionBesidePlan:511`,
  `addPlanWindow:623`). 43 total textual references to the field (reads **and**
  writes); writes stay direct — they are the layout store.
  A view-layer-only override (the shortcut this file rejects) would leave
  `chainPayload`, `armDrag`, `bringIntoView`, `planFocusAboveSession` and both
  placement functions describing a screen that no longer exists.
- **INV2** Two layers against a stale `soloWin`: (a) cleanup on every close
  path; (b) the **derived** accessor returns `Nothing` when the key is absent
  from `windowPositions`, so a missed cleanup degrades to "canvas view", never
  to a blank screen.
- **INV3** `soloWin` is written by exactly three update helpers
  (`enterSolo`, `exitSolo`, and the SD8/SD9 follow logic). No ad-hoc
  `{ model | soloWin = ... }` in message branches.
  **Checked mechanically since F1**, both directions, by
  `scripts/check-layout-invariants.sh` §3: a `soloWin =` record update anywhere
  in `App/Update|View` or `Plan|Session|Overlay|Arch` fails, and so does the
  *name* `soloWin` in code (comments blanked first) in any `src-elm/src` file
  outside `App/Windows.elm` + `App/Types.elm` + `Main.elm` — reading the raw
  field is the bug, because it skips INV2's de-risking. Three helpers exactly as
  written here: `followSolo` takes a `SoloChange` (`SoloCreated`/`SoloClosed`),
  so SD8's follow and SD9's release are two cases of one writer. A rule about
  code shape that only prose enforces is a rule the next edit breaks.
  **Checked mechanically since F1**, in both directions, by
  `scripts/check-layout-invariants.sh` §3: a `soloWin =` record update in
  `App/Update|View` or `Plan|Session|Overlay|Arch` fails the check, and so does
  the *name* `soloWin` appearing in code (comments are blanked first) in any
  `src-elm/src` file outside `App/Windows.elm` + `App/Types.elm` + `Main.elm` —
  because reading the raw field skips INV2's de-risking. Three helpers, exactly
  as written here: `followSolo` takes a `SoloChange` (`SoloCreated` /
  `SoloClosed`) so SD8's "follow" and SD9's "release" are two cases of one
  writer instead of two functions. Prose rules do not survive the next edit;
  this one is now a build failure.
- **INV4** Entering/leaving solo changes **no** field of `windowPositions`,
  `canvasOffset`, `canvasScale`, `sessionOrder`, `planOrder`, `nextZIndex`,
  `sessions`, `planWindows`. (Assert in an elm-test: same model in/out →
  these dicts equal.)
- **INV5** `#main-content` and the `.canvas` layer keep existing in solo (JS
  measures them: `Dom.getElement "main-content"`, the scrollbar/scale math at
  `overlay.js:535-543`). Solo changes *content*, never the shell.
- **INV6** All new logic is pure and elm-tested; gesture logic stays testable
  through `toDragKind` (`App/Types.elm:712`) + `armDrag` (`Update.elm:6661`),
  not through DOM.
- **INV7** Zero user-visible behavior change in F0 (its diff contains no `if
  isSolo`). Any solo branch appearing in F0's diff is a mistake — revert and
  re-do.

---

## F0 — One accessor for effective geometry (pure refactor, no behavior change)

Add to `src-elm/src/App/Windows.elm` (exports + impl):

```elm
winRect : Model -> String -> Maybe WindowPos      -- F0: == Dict.get key model.windowPositions
winRectList : Model -> List ( String, WindowPos ) -- F0: == Dict.toList model.windowPositions
hasWin : Model -> String -> Bool                  -- F0: == Dict.member key model.windowPositions
```

Convert every **read** site (writes stay direct — they *are* the layout store):

| File | Site (function) | Becomes |
|---|---|---|
| `App/View.elm` | `viewSessionPanel` winPos | `winRect` |
| `App/View.elm` | `viewPlanPanel` winPos | `winRect` |
| `App/Windows.elm` | `chainPayload` | `winRectList` |
| `App/Windows.elm` | `raiseWindow` member test | `hasWin` |
| `App/Windows.elm` | `raiseChainWindows`, `rebasePositions` consumers | keep (whole-dict writes) |
| `App/Windows.elm` | `planPositionBelowSession` / `nodeSessionPositionBesidePlan` / `centeredSessionPos` / `centeredPlanPos` | `winRect` (+ viewport fallback) |
| `App/Windows.elm` | `addPlanWindow` member test | `hasWin` |
| `App/Windows.elm` | `handleResizeMove` / `resizeMove` read side | `winRect` |
| `App/Update.elm` | `planFocusAboveSession` (`:153/:156`) | `winRect` (z only) |
| `App/Update.elm` | `resumeSessionCreated` member test (`:804`) | `hasWin` |
| `App/Update.elm` | `createSessionWindow` member test (`:948`) + `bringIntoView` read (`:1014`) | `hasWin` / `winRect` |
| `App/Update.elm` | `armDrag` (`:6661`) | `winRect` |
| `Main.elm:52`, `App/Types.elm:82` | declaration / init | unchanged |

- [x] F0.1 Add the three accessors, doc-commented as "effective geometry —
      the SOLE read path for where a window is" with a pointer to INV1.
- [x] F0.2 Convert all read sites (table above). `elm make` + `elm-test`.
      13/13 done. One extra read fell out of the table: `addPlanWindow`'s
      closing `Dict.get key positions1` (bringIntoView anchor) now reads
      `winRect m1 key` — the same rect (raiseWindow only moves z), and it
      keeps the "geometry is read through the accessor" rule true inside the
      module too.
- [x] F0.3 Write `scripts/check-layout-invariants.sh` (style: follow
      `scripts/check-backend-parity.sh` — portable shell, `code_only`
      normalisation, fail-list output). Checks:
      (a) **zero** `Dict.get|member|toList .*windowPositions` in `App/View.elm`
      and `App/Update.elm` (baseline 8: 6 + 2 — this check starts red and F0.2
      turns it green, which is what makes it a real check);
      (b) the count inside `App/Windows.elm` (baseline 5) is pinned as a
      **maximum**, so it can only shrink;
      (c) `src-elm/*.js` contain no `soloWin`/`solo` identifier while F1–F2 run
      (SD7: behaviour stays in Elm) — note `transport.js` already matches
      `maximiz` for the OS-window `isMaximized` plumbing, so match `solo` only.
      **Deviations from the wording above, both deliberate:**
      (b) pins **3**, not 5 — after F0.2 the only reads left in the module are
      the three accessor bodies, so 3 is the tightest value that is green, and
      the "can only shrink" ratchet is worth more than the historical 5. If the
      count reaches 0 the script fails loudly (accessors deleted/renamed → the
      grep matches nothing → green-by-accident).
      (c) skips `src-elm/elm.js`: it is the generated Elm bundle (`make elm`,
      gitignored) and it starts containing `solo` the moment F1 lands — which is
      exactly where this rule wants the logic.
      Comment-blanking (not deleting) keeps real line numbers in the failure
      output, and both failure modes were provoked to confirm they fail.
- [x] F0.4 Makefile: `check-invariants` target. CI (`.github/workflows/ci.yml`):
      run it in the **Elm frontend** job (where `elm-test` runs — note
      `check-backend-parity.sh` currently lives in the E2E job, so copy that
      step's shape but do not assume the same job). AGENTS.md's verification
      block now lists `make check-invariants` too — a check that no one is told
      to run is a check that gets skipped.
- [x] F0.5 elm-tests in `tests/AppWindowsTest.elm`: accessors agree with the
      raw dicts for a model with 3 sessions + 2 plans; a key absent from
      `windowPositions` (a plan that was never placed) yields `Nothing` and the
      callers fall back exactly as before.
- [x] F0.6 **Gate**: 13/13 e2e green (`make e2e`), `elm-test` green, diff has
      no solo concept anywhere. Commit + push.
      Verification result: elm 637 tests green (635 baseline + 2 new), `make
      e2e` 13/13, `make test-go` green, `cargo test` 127 green, `cargo clippy
      --lib` no errors (2 pre-existing warnings, untouched), parity + schema +
      invariants scripts green. On "no solo concept": no solo *code* exists in
      the diff (no field, no msg, no branch — INV7 holds); the accessor's doc
      comment does NAME solo, because "why is `Dict.get` wrapped?" has no other
      honest answer, and deleting the reason is how the next maintainer deletes
      the accessor.

## F1 — Solo state, derivation, interaction gating

- [x] F1.1 `App/Types.elm`: add `soloWin : Maybe String` to `Model` + msgs
      `SoloWindow String | ExitSolo | ToggleSolo String`. Init in `Main.elm`.
      **One thing the spec did not anticipate:** `Ctrl+Shift+F` cannot be told
      apart without the Shift modifier, and `KeyDown` carried
      `key/ctrl/alt/defaultPrevented` only. `KeyDown` now carries `shift` as
      well (`Main.elm`'s `D.map4` → `D.map5`; `Browser.Events` exposes
      `shiftKey` the same way it already exposes `ctrlKey`), which touched 11
      test call sites. The alternative — inferring "shift was held" from the
      case of `"F"` — was rejected: layouts and CapsLock break it, and it hides
      a modifier inside a character.
- [x] F1.2 `App/Windows.elm`: `isSolo`, `soloRect`, `winRect` **override**
      (solo window → `Just (soloRect model key)`, every other key → `Nothing`),
      `enterSolo`/`exitSolo`/`followSolo` (INV3), `soloKey` (the only reader of
      `soloWin`, INV2b). `winRect` returning `Nothing` for hidden windows makes
      visibility and geometry ONE derivation (INV1/SD6).
      **Two corrections to the wording above, both found by reading the CSS:**
      (a) `soloRect` is NOT `0,0,appWidth,appHeight`. Panels are children of
      `.canvas`, which is `translate3d(offset) scale(scale)`, so that rect only
      fills the viewport at offset 0 / scale 1 — a user who had panned or
      zoomed would get a panel placed elsewhere and sized wrong. The derived
      rect is the viewport inverse-transformed into canvas coordinates
      (`(0 - offset)/scale`, `appWidth/scale`), the same conversion
      `centeredSessionPos` already uses. `soloRect` therefore takes the KEY as
      well: `z` comes from that window's stored rect, so entering solo
      re-stacks nothing.
      (b) `layoutRect` (the private "where does a new window JOIN the layout"
      read, decided during F0) is implemented: the two placement rules and
      `addPlanWindow`'s bringIntoView anchor read the STORED rect, because
      answering from the solo rect would write viewport-relative numbers into
      the persistent layout — SD4 forbids exactly that. But the Windows.elm
      ratchet stayed at **3**, not the 4 predicted: `winRect` delegates to
      `layoutRect` and `soloKey` asks `hasWin`, so a new named read appeared
      without a new raw read. Fewer bypasses than planned is the right direction
      for a ratchet.
- [x] F1.3 `App/View.elm`: `view` filters both order lists — through
      `Win.visibleWindows`, i.e. through `winRect` itself, so the renderer and
      the accessor cannot disagree (and it is a testable function instead of an
      inline lambda); `#main-content` gains `main-content-solo`;
      `viewResizeHandle`/`viewPlanResizeHandle` take the model and render
      NOTHING in solo; the plan info window is not rendered either.
      The handle guard went INSIDE the two renderers rather than into a list
      splice at the 16 call sites: same DOM result (`.resize-handle` count 0 in
      solo — the e2e asserts it), without re-indenting both panel bodies. That
      was not a style preference: the splice version was written first, mangled
      twice, and is the reason F1's `App/View.elm` had to be rebuilt.
- [x] F1.4 `toDragKind` → `Bool -> …` (the solo flag first), `Nothing` for every
      draggable surface. Regressions live in `tests/PointerFsmTest.elm`
      (where `toDragKind` and the gesture FSM are tested — `PointerTest.elm`
      covers only the decoder and the target classifier, neither of which knows
      what a drag kind is) and cover Pan / WindowMove / PlanMove / both Resizes
      plus an FSM case: no pinch from two canvas fingers, and `activePointers`
      still fills.
- [x] F1.5 Gate in `App/Update.elm`: `PointerDown` — the guard sits after the
      `activePointers` insert, so the map stays truthful (a finger the model
      still thinks is down breaks the first gesture after solo ends, and
      `PointerUp` removes by id only if the id is in there) and no `armDrag`,
      no `startPinch`, no `shouldArmLongPress` runs. `CanvasZoom` /
      `CanvasZoomReset` → `( model, Cmd.none )`.
- [x] F1.6 Chain (SD13): the **preferred** option — `chainPayload` derives the
      emptiness (segments AND positions), so none of the 18
      `Ports.setConnectionChain` call sites changed. On `ExitSolo` the chain is
      recomputed for the focused window and re-sent — deliberately WITHOUT the
      raise `activateSessionModel` also does: raising writes `z` into
      `windowPositions`, and INV4 forbids that on a solo transition. The board
      the user left is the board they come back to.
- [x] F1.7 Entry points: `⤢`/`⤡` in `session-bar` and `plan-bar` (new
      `Icons.expand`/`Icons.compress`; ONE button per bar sending `ToggleSolo
      <key>`, the glyph chosen by `soloKey model == Just key`); the global-menu
      item ("Solo window" ⇄ "Exit solo") acting on `soloTarget` — the topmost
      window, which is the same question Ctrl+W asks; and `Ctrl+Shift+F`,
      placed BEFORE the `Escape/Ctrl+[` block. `defaultPrevented` remains the
      first branch, and the chord does fire while the prompt textarea has focus:
      that textarea's own keydown handler only preventDefaults plain Enter.
      Pinned by elm-tests (both the chord and the `defaultPrevented = True`
      early return) and by the e2e with real Chrome key events — including
      plain `Ctrl+F`, which must NOT be hijacked.
- [x] F1.8 SD8/SD9 wiring. `createSessionWindow` follows solo unless
      `isRunnerCreate` (the already-checked discriminator, so a runner node
      session cannot steal it); `addPlanWindow` follows per SD3 through
      `soloFollowsPlan` — the new plan must belong to the SAME live session as
      the solo window, which makes "opening a plan from the solo session moves
      solo onto it" and "a runner window does not steal it" one rule instead of
      two guesses at `planCreating` (which tracks SESSION creates, not plan
      windows, so the literal `planCreating == UserCreate _` test in this line
      would have followed almost never). Close paths: solo is cleared in
      `minimalCloseSession` and `minimalPlanClose` — the ONLY two places a
      window key leaves the layout store — so ✕, Ctrl+W, `DeleteSession` and
      the cascade `closeSet` teardown are covered at the chokepoint rather than
      at five call sites each needing its own re-derivation.
      `requestCloseSession` deliberately does NOT clear it: it only opens the
      confirmation, and leaving solo because the user hovered ✕ would be a
      surprise. INV2's derived `soloKey` stays the second layer, and
      `followSolo (SoloCreated _)` also heals a dirty `soloWin` (session ids
      are REUSED by resume — `Session.id` is the on-disk dir id — so a stale key
      would silently re-attach solo the next time that session opens).
- [x] F1.9 elm-tests: new `tests/SoloViewTest.elm` (29 tests):
      (a) INV4 — a solo round trip through `update` leaves
      `windowPositions/canvasOffset/canvasScale/sessionOrder/planOrder/nextZIndex`
      identical — `layoutOf` packs them into ONE record so a new write shows up
      as a named field, not a silent tuple element;
      (b) SD6 — `visibleWindows` filters both order lists (the pure function
      behind the view); (c) INV2b — a `soloWin` pointing at a gone key reads as
      canvas view; (d) SD8 — user create follows, runner create does not,
      creating in canvas view never ENTERS solo, SD3 plan follow + refusal;
      (e) SD13 — the payload is empty on both sides in solo and full again
      outside it, and exit rebuilds the chain. Plus geometry (the canvas-space
      conversion, an OS resize, `z` preserved) and `soloTarget`. 668 tests
      green (637 → 668: 29 here, 2 in `PointerFsmTest`).
- [x] F1.10 New `e2e/solo-e2e.mjs`, **registered as `solo` in
      `e2e/scripts.txt`** (14 suites). Eight sections: three windows → ⤢ →
      exactly one `.session-panel` whose client rect == `#main-content`'s, zero
      `.resize-handle`, no visible `.connection-seg`, `.main-content-solo` on
      the shell → wheel + bar-drag are no-ops and write nothing → ⤡ returns 3
      panels at their pre-solo `style.left/top/width/height` and the same canvas
      transform → **the control that makes the wheel claim mean something** (the
      same synthetic wheel on the same element DOES zoom outside solo, then the
      menu resets the scale) → `Ctrl+Shift+F` toggles both ways → plain `Ctrl+F`
      is untouched → the global-menu path in both directions → closing the solo
      window exits solo and leaves the other two exactly where they were.
      Deviation: it compares `getBoundingClientRect()` rather than
      `offsetWidth` — offsetWidth ignores the canvas `scale`, so at zoom ≠ 1 it
      is not the size the user sees.
- [x] F1.11 **Gate.** Green on every item of §Verification: `make test-go`,
      `elm make` + 668 `elm-test`, `cargo test` (127) + `cargo clippy --lib`
      (0 errors), `check-backend-parity`, `make check-invariants`,
      `make check-schema`, `make e2e` **14/14**. SD7 asserted mechanically:
      `git diff --stat src-elm/transport.js src-elm/chain.js src-elm/overlay.js`
      is EMPTY — F1 did not touch the bridge at all.
      **Not done by F1, deferred to F2 on purpose** (each is an SD11
      reachability question, not a state-machine question): the `⋯` button, the
      attention counts, `Esc`-exits-solo (SD12) and `Ctrl+W`-exits-solo (SD10, since revised — see the row: Ctrl+W now closes nothing at all).
      A user resume (`resumeSessionCreated`, e.g. from the Session Manager
      while solo) also does not move solo today, so the resumed window appears
      behind the solo one — F2's badge is what makes that visible; if it turns
      out to be the wrong answer, it is an SD8 amendment, recorded here.

## F2 — Reachability (SD11) — do not skip, it is a correctness fix not a UI favor

- [x] F2.1 `App/Windows.elm`: pure `attentionCounts : Model -> { waiting : Int,
      running : Int }`. `waiting` = hidden windows holding a blocking modal —
      the fields named in this line, all nine (`closeConfirm`,
      `cancelTaskConfirm`, `pendingConfirm`, `pendingMcpAuths`,
      `mcpAuthRunning`, `mcpStatus`, `filePicker.show`, `showModelSelector`,
      `mediaPreview`), behind one predicate `sessionIsWaiting`; `running` =
      hidden windows with `taskRunning`. Hidden is `winRect key == Nothing`, so
      the count and the rendering cannot disagree. Plan windows are not counted
      (they have no modal state; a plan reaches the user through its session).
      The sync comment went on the RENDER SIDE as promised, and one comment at
      the seven-renderer call site rather than seven comments — they are called
      from one list in `viewChatArea`, which is where a new modal would be
      added anyway.
- [x] F2.2 `⋯` button → `ShowGlobalMenuAt`, rendered by `soloOnlyControls`
      (both bars, session and plan, from one function). It is placed from
      `appWidth`, not from the button: Elm has no DOM measurement, and SD7
      forbids getting one — `appWidth` is already what the bar's geometry is
      derived from. The counts ride on the **⤡ button itself**
      (`Canvas · 1 waiting`, `waiting > 0` adds `.solo-attention` + an
      explanatory tooltip) rather than a separate exit control: a badge next to
      the exit button is something to notice, the button itself is something
      you click.
- [x] F2.3 SD10 + SD12. `Ctrl+W` exited solo before any close logic. `Esc`
      exits through `exitSoloLast`, reached only where the existing chain
      reaches nothing: every overlay keeps its turn, and the tool-confirm
      dialog still cannot be dismissed by Escape. The guard is
      `if isSolo … else ( model, Cmd.none )` — not a bare `update ExitSolo` —
      because `ExitSolo` re-sends the chain payload, and an Escape with nothing
      open in canvas view must not start talking to the bridge.
      Tests: `CloseConfirmTest` (Ctrl+W in solo: solo gone, no `closeConfirm`,
      session alive) and `EscapeOverlayTest` (media preview first, solo second;
      plus the canvas-view no-op above).

      **SUPERSEDED TWICE.** First for the close half, then by SD18: `Ctrl+W` no
      longer exits solo either, and `Esc` no longer does either — see SD12/SD18.
      The surviving code is `exitSoloIfSolo`… which was then DELETED, because
      with both chords inert nothing had a caller left; do not resurrect it to
      "make Escape useful again". The user has since ruled that `Ctrl+W`
      is not a close key at all, so the canvas-view branch (topmost plan →
      `PlanClose`, else `RequestCloseSession`) is gone and the chord now runs
      through `exitSoloIfSolo` — exit solo, otherwise touch nothing. Two
      consequences worth knowing before you re-derive them: (a) the helper was
      renamed from `exitSoloLast`, because two chords now share it and "last"
      only described its place in the Escape chain; (b) `planFocusAboveSession`
      was DELETED, not kept — it existed to answer "which window does Ctrl+W
      close", `soloTarget` already answers "which window is the user looking
      at", and two functions comparing the same z pair is AGENTS.md #4 waiting
      to drift. Its four tests became two `soloTarget` tests in
      `AppWindowsTest`, including the case the old code got wrong by omission:
      a focused id whose window is gone is not a target.
- [x] F2.4 Checked rather than rewritten: solo is IMPOSSIBLE with zero windows
      (INV2b derives `isSolo` from a key that must exist, and SD9 clears the
      field on close), so `viewNoSessionPanel`'s "right-click the canvas"
      tagline is true exactly when it is readable. Pinned by the elm-test
      "closing the only window leaves canvas view, not solo". A copy change
      here would have been a guess dressed as a fix.
- [x] F2.5 e2e: `solo-e2e.mjs` §9–§10. **Deviation, on purpose:** the spec
      asked for a fakecore tool-confirm marker; faking one means editing
      `src-go/internal/fakecore`, and rule 5 says F0–F2 do not touch the
      backends. The file picker is in the same `waiting` list and opens from a
      real click, so it exercises the whole path (hidden window → counted →
      highlighted → clicked → reachable) with no backend change. What the e2e
      DID have to learn: panels cascade 50×40, so an older window's footer is
      UNDER a newer one and must be clicked through the DOM, not at its
      coordinates; and the click raises the window it lands on, which reorders
      `sessionOrder`, so "which panel is which" is read back from the DOM after
      the click instead of assumed before it. Both are noted in the script.
- [x] F2.6 **Gate.** `make test-go` green; `elm make` + 677 `elm-test`
      (668 → +9 here); `cargo test` 127 and `cargo clippy --lib` 0 errors
      (nothing in `src-tauri/` changed); `check-backend-parity`;
      `make check-invariants` (still 3/3 raw reads, `soloWin` confined);
      `make check-schema`; `make e2e` **14/14**, with the two new solo sections
      inside the already-registered `solo` script. The bridge is still untouched
      — `git diff src-elm/transport.js src-elm/chain.js src-elm/overlay.js` is
      empty (SD7 held for F1 AND F2).
- [x] F2.7 `README.md` "Windows and solo view" + the mirrored
      `README.zh-CN.md` section (same table, same order, nothing added on one
      side). Both say what solo stops and — the part users worry about — what
      it does NOT stop.

**F2 leaves no known reachability hole for the modal set it counts.** Two
things are deliberately still open, both because they are not modal-blocking:
a user `resumeSessionCreated` does not move solo (the resumed window appears
behind the view; its badge shows nothing because a fresh session has no modal —
if that turns out to matter it is an SD8 amendment, made here rather than in
code), and a plan window's own errors/feedback are not counted (no blocking
dialog, and the plan's session is).

## F3 — Persist the layout (`ui.conf`) — scope decided by SD15/SD16/SD17

Schema (new `~/.alayaface/ui.conf`, AlayaFace-owned like `global.conf`/`asr.conf`,
honours `--config-path`):

```json
{ "version": 1
, "soloWin": "<key|null>"
, "canvasOffset": { "x": 0, "y": 0 }
, "canvasScale": 1.0
, "windows": { "<session-or-plan-key>": { "x": 0, "y": 0, "w": 560, "h": 640, "t": 1 } } }
```

(`t` = the monotonic touch counter described below; it is layout bookkeeping, not
a stacking order — see SD17.)

Design consequences that follow from SD15 and must NOT be discovered later:

- **The store outlives the open windows.** After a restart nothing is open, so
  `windows` must be keyed by stable window keys (`Session.id` / `planId`) and
  **survive while its window is closed** — pruning it because the window is not
  currently open would make the feature meaningless. Prune only where the
  identity itself dies: `DeleteSession` ("Close and Delete"), plan subtree
  removal (preset delete has no layout impact → not touched). **Do not prune
  against the startup disk scan** — that scan is async (`FsHomeDirResult` →
  `planMetaScanPending`) and making the layout store depend on its ordering
  would be a race.
- **Bound the file with an explicit touch counter, not "LRU".** Decoding JSON
  into an Elm `Dict` sorts keys alphabetically, so insertion order is *not*
  recoverable and a real LRU is unimplementable without stored metadata. Each
  entry therefore carries `"t": <Int>` (a monotonic `layoutTouchCounter` on the
  Model, bumped when a window is created/moved), and a save that exceeds
  `maxStoredWindows = 200` drops the lowest `t` entries whose window is not
  currently open, `Ports.logWarn` once. Deterministic, and testable both sides.
- **Restore validates, never clamps to garbage.** A stored rect is accepted only
  if all four fields are finite integers and `w >= minWinW && h >= minWinH`;
  otherwise the key falls back to the normal placement path (`centeredSessionPos`
  / `planPositionBelowSession` / `nodeSessionPositionBesidePlan`). `canvasScale`
  is clamped to `[canvasMinScale, canvasMaxScale]`, `canvasOffset` to
  `canvasMaxPan`. A corrupt file must degrade to "defaults", never to "app
  unusable" — and unlike `global.conf` (which reports a parse error), `ui.conf`
  is non-critical, so log and continue.
- **Restore is per-window, on creation** — `createSessionWindow` /
  `resumeSessionCreated` / `addPlanWindow` ask the layout store first and fall
  back to placement rules. The store has no `z` (SD17), so restore composes
  `{ x, y, w, h }` from disk with a **fresh** `z` from `nextZIndex` — never
  reuse a stored `z`, or the rebased-z contract (`zRebaseThreshold`) leaks into
  a new process. `soloWin` re-attaches when its key appears, and stays inert if
  that window is never opened again (INV2).
- **Writes are triggered by events, not by the clock** (SD16): exactly one
  `sync_ui_config` per interaction end (`PointerUp` that finishes an active
  move/resize, window create/close, solo enter/exit). Never from `PointerMove`
  / `dragMove` / `applyZoom`.
- **Wheel zoom is the one burst with no end event**, so it gets a *one-shot idle
  debounce* (SD16's exception): `Task.perform (\_ -> SaveUiTick n) (Process.sleep 1000)`
  using the repo's existing sleep+tagged-message pattern (`LongPressFired`,
  `DeleteWorkCopyDir`), where `n` is a **generation counter on the Model**. A tick
  whose `n` is stale (the user zoomed again meanwhile) is ignored — without the
  generation, a slow burst would either save an intermediate state or never save
  the final one. This is the only timer in the feature; `SaveUiTick` must not be
  able to start another `SaveUiTick`.
- `get_ui_config` / `sync_ui_config` in **both** backends in the same commit;
  names must satisfy `check-backend-parity.sh` (Rust `commands::` ↔ Go handler
  registry ↔ `transport.js` `invoke`), and its **behavioral constants** section
  must learn `DEFAULT_UI_CONF_VERSION` + `maxStoredWindows` (name parity alone
  passed real drift before — see the script's own header).
- Atomic write via the existing `write_file_atomic` (unique temp name; a shared
  `.tmp` name already bit this repo once).

- [x] F3.1 Model the schema in **one** Elm module with lenient decode +
      unknown-key tolerance (precedent: `Session/ModelConfig.elm`, whose whole
      reason for existing is the replace-semantics trap). Rust
      `src-tauri/src/commands/ui_config.rs` + Go
      `src-go/internal/server/handlers/ui_config.go` mirror it.
- [x] F3.2 Ports + `transport.js` wiring, including the best-effort
      `beforeunload` flush (and a comment saying exactly why it may not arrive —
      SD16).
- [x] F3.3 Restore path (per-window, validated) + write triggers (interaction-end).
- [x] F3.4 Prune on delete paths + LRU cap.
- [x] F3.5 Rust + Go tests: round trip ✓, corrupt file → defaults ✓, out-of-range rect →
      rejected ✓ (per-entry drop in the client, shape refusal in the backends),
      `--config-path` isolation ✓, eviction: the RULE tested on both sides ✓, and
      the wiring that calls it landed with part 2 (`UiLayout.syncUiLayout` applies
      `UiConfig.evict` at assembly time with the open keys protected).
- [x] F3.6 elm-test: decode leniency, validation, "stale `soloWin` key behaves as
      canvas".
- [x] F3.7 e2e: extend `solo` — complete a session, restart the backend with the
      same HOME, reopen, assert each window returns to its stored rect and solo
      re-attaches; then delete a session and assert its layout entry is gone.
- [x] F3.8 **Gate**: full verification. Commit + push.

---

### §F3-B — the client half. LANDED 2026-09-09; kept as the record of what it had to be.

**Landed in `58bd111` (F3 part 1, verified end to end):** `get_ui_config` /
`sync_ui_config` in BOTH backends + registered + in the parity script's
command list; `App/UiConfig.elm` owning the schema (decode/encode/`evict`,
top-level unknown keys carried through); the shared accept/refuse table
`testdata/serialization/ui_cases.json` run by the Rust and Go test suites; the
three-way constant check (Rust / Go / Elm on `version` + `maxStoredWindows`);
15 elm-tests, 8 cargo tests, 7 go tests. **Nothing in the app calls the two
commands yet, so no user's layout is read or written.** That is the safe state
to be in: part 1 cannot be wrong about the user's board, only about the file.

**Do NOT start by wiring the save.** Start with the two things that decide
everything downstream:

1. **Where the store lives in the Model.** Add
   `uiLayout : Dict String UiConfig.Entry` + `uiTouch : Int` (the counter) —
   NOT a field inside `windowPositions`. `windowPositions` stays the live board
   (SD4: solo never writes it, and it loses entries when a window closes);
   `uiLayout` is the identity-keyed store that SURVIVES a closed window (SD15).
   Two dictionaries, two lifetimes, one writer each. `UiConfigTest` pins the
   cap/eviction; the elm-test for this part pins that they stay in sync.
2. **The write trigger set, before any port exists.** SD16's list is
   interaction-end only: pointerup that ends an active move/resize, window
   create, window close, solo enter/exit, session close — plus the ONE
   generation-numbered idle tick for wheel zoom. Write the helper that assembles
   the `UiConfig.Document` from the model first, and call it from a single
   `syncUiLayout : Model -> (Model, Cmd Msg)` so there is exactly one place that
   can produce a document. If you find yourself saving from a `dragMove`-ish
   path, stop.

**Then, in this order** (each step is independently verifiable, and the order is
what keeps a bad restore from destroying a good file):

- **Restore behind a flag of its own logic, not a runtime flag:** read →
  validate → apply per window at creation (`createSessionWindow` /
  `resumeSessionCreated` / `addPlanWindow` ask `uiLayout` first and fall back to
  the placement rules). Validation lives in `App/Windows.storedRect` (new):
  finite ints, `w >= minWinW && h >= minWinH`, else `Nothing` → placement path.
  Compose with a FRESH `z` from `nextZIndex` — never the stored one (SD17).
  `canvasScale` clamped to `[canvasMinScale, canvasMaxScale]`, `canvasOffset` to
  `canvasMaxPan`, so a hand-edited file cannot pan the board into a float
  overflow. An elm-test per case.
- **The save side second**, once restore is proven: the `beforeunload` flush in
  `transport.js` is best-effort and MUST be commented as such (over HTTP the
  beacon cannot carry the `Authorization` header; over Tauri the webview is
  already going away). Correctness rests on the interaction-end writes only.
- **Prune + cap last** (F3.4): prune `uiLayout` where the IDENTITY dies
  (`DeleteSession`, plan subtree removal), not where a window closes; apply
  `UiConfig.evict` (open keys protected) at assembly time, `Ports.logWarn` once
  when it drops anything.
- **e2e (F3.7):** extend `solo`, do not add a script — the restart case is about
  the same board the solo sections already assert. The Go server is restarted in
  place with the same HOME; assert each window returns to its stored rect, the
  solo flag re-attaches to a reopened session, and a DELETED session's entry is
  gone from `ui.conf` (read the file back through the RPC, not through the DOM).

**Two facts part 1 already established, do not re-derive them:**
- `version: 1.0` in JSON is an integer; `1.5` is not. The two backends disagreed
  on exactly this until the shared fixture caught it (serde's `as_i64` rejects
  what Go's float64 decode accepts). Any NEW validation goes through
  `ui_cases.json` in the same commit on both sides, or it will drift the same way.
- The backends refuse an oversized or non-object document; they do NOT trim.
  Eviction is the client's job because only the client knows which windows are
  open. A backend that "helpfully" trimmed would silently drop the rect of the
  window the user is looking at.

**§F3-B LANDED (2026-09-09).** What the client half is, in the files:

- `App/Types.elm`: `uiLayout : Dict String UiConfig.Entry`, `uiTouch`,
  `uiSoloPending`, `uiExtras`, `uiZoomGen` — and msgs `UiConfigGetResult`,
  `UiConfigSyncResult`, `UiFlush`, `UiZoomIdle Int`.
- `App/UiLayout.elm` (new, pure): `decodeGet` / `decodeSyncResult` (the two
  envelopes), `applyLoaded`, `absorb`, `syncUiLayout` + `withUiSave` (the ONLY
  producers of a payload), `attachPendingSolo`, `prune`. Every SD16 trigger in
  `App/Update.elm` is spelled `withUiSave`, so the write set is one grep.
- `App/Windows.elm`: `layoutRects` (the board WITHOUT solo's viewport override —
  `winRectList` is now expressed through it, so INV1's read count is still 3),
  `storedRect` (size/coordinate floor), `restoreOrPlace` (fresh z always, SD17),
  `storedScale` / `storedOffset` (clamps). `addPlanWindow` consults the store.
- `App/UiConfig.elm`: `fromStore` / `soloIntent` — so `soloWin`, which is the
  NAME OF A KEY in the file, is never spelled in Model-reading code (the
  invariant gate keeps its allow-list honest).
- **`uiLoaded` — the read gate on every write.** `syncUiLayout` refuses to
  produce a document until the startup read has ANSWERED (either a document, or
  "there is no file"). A client whose read failed has an empty store, and
  publishing that would delete the user's layout with no trace. `Ok Nothing`
  unlocks writes without applying anything, because a late "no file" answer must
  not clear a store the session already built. Pinned by two elm-tests; the
  gate is why `board` in the test fixtures marks the model as read.
- `Ports.elm` + `transport.js`: `getUiConfig`/`syncUiConfig`/`onUiConfigGet`/
  `onUiConfigSync`/`onUiFlush`; the HTTP `invoke` gained `opts.keepalive` for the
  unload write, and the flush sends NO document — it nudges Elm, which decides
  (SD7: the pipe still makes no behavior decision). Bridge command count 42 → 44.

**The one bug part 2 produced, and what it teaches.** Pruning the deleted
session at the END of `DeleteSession` left the key in `ui.conf`: the delete
cascades closes, every close writes the whole document, and two POSTs of
`sync_ui_config` have no delivery-order guarantee — so a stale document could
land last and resurrect the key. The fix is to prune at `m1`, BEFORE the
cascade, which makes every later write already correct in any order. elm-test
cannot see this (the final model is pruned either way); `solo-e2e` §12(g), which
reads the file back through the RPC after a real delete, is what caught it. That
split is worth remembering for any future F3-style writer: **model assertions pin
what was decided, e2e assertions pin what arrived.**

**Verification for part 2** is the whole §Verification list, unchanged, plus the
manual smoke in this file's header (the restart case is the one a browser
round-trip cannot fake: kill the server, start it again on the same HOME, reopen
the same session).

## F4 — Cleanup + docs

- [x] F4.1 Resolve the dead OS-maximize state: `Model.isMaximized`
      (`Types.elm:74`), `WindowMaximized` (`Types.elm:428`),
      `Update.elm:4828`, `transport.js:862-867`, `Ports.onWindowMaximized` —
      nothing in the view reads it. **Deleted** (2026-09-09), field, message, arm,
      port, subscription, `init` sites and BOTH transports' `isMaximized` /
      `onWindowEvent` members — the bridge now exposes no OS-window state at all.
      The field invited confusion with solo, and the pipe cost a resize listener
      plus an RPC at startup for a value nothing could observe. Viewport size,
      which the app DOES need, arrives independently (`Browser.Events.onResize →
      RequerySize`, and overlay.js's container re-measure), so nothing was lost.

      Found while verifying it: F3's `sync_ui_config` had been sending EVERY save
      with `fetch(keepalive)`. Browsers cap how much a page may send that way, so
      the flag is now Elm's to set — `syncUiConfig { config, teardown }`, true
      only for the `UiFlush` arm — and ordinary interaction-end writes are plain
      requests again. A `keepalive`-heavy plan run is also the likeliest cause of
      the one Chrome `Segmentation fault` seen during this series' e2e runs.
- [ ] F4.2 Write tracked `docs/solo-view.md` (body: this file's SD/INV tables +
      the F0 accessor contract) and archive this TODO to `docs/archive/TODO-f-series.md`.
- [ ] F4.3 Re-read AGENTS.md's architecture paragraph and update it if the
      module map changed.

## H1 — Opportunistic, independent commit (do not mix into F1)

- [x] H1.1 `bufferPendingEvent` (`Update.elm:417-425`, fed by the unknown-session
      branch at `:1430` and friends) has **no cap**: frames for a session this
      client never created accumulate forever. Reachable today (Go backend +
      several tabs/SSH clients) and structurally guaranteed later
      (multi-window, §Later). Cap per session key (drop oldest, keep newest
      N=512) + one `Ports.logWarn` on first overflow; elm-test the cap.
      Rationale/commit message: pre-existing, unrelated to solo.

---

## Resolved questions (were blocking F3 — answered 2026-09)

- **OQ1 → SD15.** Whole layout, not just the solo flag. Rationale recorded there.
- **OQ2 → SD16.** Interaction-end writes + best-effort `beforeunload` flush; no
  timer. The unload flush is documented as non-load-bearing.
- **New question raised while writing F3, resolved as SD17:** persist `z` / the
  order lists too? **No.** They are derived mutable state that
  `rebasePositions` shrinks on purpose; a stale stacking model imported into a
  fresh process is worse than creation-order stacking.
- **Config-file location, settled by precedent (no question left):** `ui.conf`
  lives in `alayaface_dir()` like `global.conf` / `asr.conf` / `preset_order.conf`,
  so it automatically follows `--config-path` (per-profile isolation, already
  tested for the other files). Nothing to decide — just do not hard-code
  `$HOME/.alayaface`.

## Later — the Quick window (Q-series). Not now, and here is why

The "OS hotkey summons a small window, do the task, destroy it" idea is A+B+C
of: layout axis (solo — shipping in F1), **host axis** (a real second native
window) and **lifecycle axis** (an ephemeral session). It is blocked on ground
work that has nothing to do with solo:

1. **Events are broadcast, not routed.** `app.emit` (`reader.rs:49,59,128,215`)
   and `hub.Broadcast` reach every window/client; a second Elm instance would
   buffer every foreign frame in `pendingEvents` (H1) and "own" state it never
   created. Needs per-target routing (Rust + Go, symmetric, same commit).
2. **Every Elm instance runs global jobs at init**: `close_all_sessions`
   (`Main.elm:135`, safe today only because `clientId` scopes it),
   the plan-meta directory scan, `freezeSessionVersion` → `session.refs.json`
   writes, and plan auto-create (`autoOfferCmd`). Two instances doing that
   concurrently is a real corruption risk. The quick window must be a
   *reduced* program → needs `Flags` (currently `Flags = ()`,
   `Types.elm:62`; `transport.js:186` inits with `flags: null`).
3. **Fast requires warm.** alayacore spawn + MCP init is seconds; the
   pre-warmed hidden window (or accepting first-open latency behind
   `pendingNodePrompts`-style hold-and-flush) is a design decision, not a flag.
4. **Ephemeral sessions need a kind + GC**, else `sessions/` fills with
   one-shot tasks and the Session Manager rots.
5. **Platform**: `tauri-plugin-global-shortcut` is not in `Cargo.toml`;
   capabilities are `["main"]` only; **Wayland cannot register global
   shortcuts**; macOS needs permission; the **Go/browser backend has no
   capability for it at all** → it must be documented as Tauri-only, with a
   fallback (`tauri-plugin-single-instance`: "launch again = summon").

When Q is picked up, write `docs/quick-window.md` with its own confirmed-
decision table (the way `docs/arch-persistent.md` does) **before** code. Solo
leaves no debt for it: `soloWin` is derived presentation state and adds no
per-window assumption anywhere.

## Rejected approaches (so nobody re-proposes them)

| Idea | Why rejected |
|---|---|
| Override geometry inside `view` only (leave `windowPositions` readers alone) | Two geometries; violates AGENTS.md #4. Half the model would keep drawing curves/positions/anchors for a screen that does not exist. This is the "hack" this file exists to prevent. |
| Mutate `windowPositions` to viewport size + stash a restore rect | Second source of truth, must track OS resize, dangling restore state on close. Derivation makes it free. |
| `display:none` / CSS-hiding for hidden windows and handles | DOM and model disagree; `pointerTargetKind` classifies by class → drags/pinches on invisible windows. |
| `type WinKey = WSession String \| WPlan String` | New identity mechanism duplicating `windowPositions`' key space + `activeId`/`planActiveId`/`planFocusAboveSession`. |
| Behavior checks added to `overlay.js` / `transport.js` (e.g. "skip zoom if the panel has class X") | The pipe must stay dumb; Elm owns behavior. Also unverifiable by elm-test. |
| Persist solo in `global.conf` | Its `sync` **replaces** the file — an unmodelled field is silently deleted (the `model.conf` trap). New `ui.conf` instead. |
| A parallel `viewSolo` tree | Forks every renderer (chat, tool confirm, voice, attachments, selectors, plan DAG) → guaranteed drift. F1's whole point is one renderer with a different rect + visibility. |
| Zoom-to-fit the canvas instead of a rect | Aspect ratios differ (`560×640` vs viewport) so "fill" is impossible; `scale ≠ 1` gives re-rasterised text and no content reflow (`--content-width` is computed from `appWidth`, `View.elm:68`). |
