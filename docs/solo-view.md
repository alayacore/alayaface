# Solo view and the window layout

The design record for the **F-series**: what "solo" is, how window geometry is
derived, and what the layout store (`ui.conf`) may and may not remember. The
working file this was distilled from is archived at
[`archive/TODO-f-series.md`](archive/TODO-f-series.md) — decisions **SD1–SD19**
and invariants **INV1–INV7** there are confirmed, and this document is the
tracked form of them. Where the two disagree, the code and
`scripts/check-layout-invariants.sh` win.

User-facing behavior is in [README.md](../README.md) ("Windows and solo view").
This file is about why it is built the way it is.

## What solo is, and what it is not

Solo is a **presentation state**: one window — a session OR a plan, no
distinction — fills the viewport, and every other window stops being rendered.
Nothing is closed, stopped, or moved. Two consequences carry most of the design:

- **The window keeps running.** A session streaming in solo keeps streaming; a
  plan running in solo keeps running. Solo changes what is drawn, never what is
  alive (SD1).
- **It is not a maximized OS window.** The app deliberately holds no
  `isMaximized`-style state at all (F4.1 deleted the last of it: it was written
  by a port and read by nobody). "Fill the viewport" is a client-side render
  decision, and conflating the two is exactly how a zombie field gets born.

`Model.soloWin : Maybe String` is the whole state — a window **key**, in the same
key space as `windowPositions` (a session id or a plan id, SD2). There is no
third identity type and no `isSolo` flag to keep in sync with it.

## The one-geometry rule (INV1)

`windowPositions` is the single source of truth for where a window is. Solo
derives a *different* effective rect for one window and makes the others
invisible, so any code that reads the dict directly reads a screen that may no
longer exist — a drag started on a hidden window, a curve drawn to nowhere, a
close target taken from a z that is gone. Those bugs sit two hops from the change
that causes them, which is why this is enforced rather than documented:

| Question | Ask | Never |
|---|---|---|
| Where is this window (on screen)? | `Win.winRect` | `Dict.get key model.windowPositions` |
| Is it rendered at all? | `winRect → Nothing` | a separate visibility flag |
| Does the key have a window? | `Win.hasWin` | `Dict.member … windowPositions` |
| Every visible window | `Win.winRectList` | iterating the dict |
| Every window **as laid out**, solo ignored | `Win.layoutRects` | `winRectList` (that one lies while solo) |

`scripts/check-layout-invariants.sh` fails the build on a raw read outside
`App/Windows.elm` and ratchets the reads *inside* it (currently 3/3:
`layoutRect`, `hasWin`, `layoutRects`), so a second read path cannot be added
quietly. Writes stay direct everywhere — they *are* the store, and hiding a
mutation behind an accessor would only move the bug.

`layoutRects` was added by the layout store (see below) and is the reason the
distinction is load-bearing rather than stylistic: `winRectList` in solo reports
**the viewport**, so saving through it would write "this window is as big as the
screen" into the user's file.

## Where the state may be written (INV2, INV3)

`soloWin` is written by exactly three helpers in `App/Windows.elm`:
`enterSolo`, `exitSolo`, and `followSolo` (which takes a `SoloChange` —
`SoloCreated` / `SoloClosed` — so SD8's "follow the new window" and SD9's "don't
outlive your window" are two cases of one writer rather than two functions).

Two layers guard a stale key, because a missed cleanup is a blank screen:

1. cleanup on every close path (window close, delete, cascade — and solo cannot
   outlive the window it points at, SD9);
2. **`soloKey` de-risks on read**: it returns `Nothing` unless the key still names
   a window. So the worst case of a bug in (1) is "the user is back on the
   canvas", never "the app is showing nothing".

The gate checks both directions: a `soloWin =` record update anywhere in
`App/Update`, `App/View`, `Plan/*`, `Session/*`, `Overlay/*`, `Arch/*` fails, and
so does the *name* `soloWin` in any code there — reading the raw field is the
same bug as writing it, because it skips layer 2. `App/UiConfig.elm` is on the
allow-list for a different reason: its `soloWin` is the **name of a key in
`ui.conf`**, not the Model field, and renaming it to satisfy a grep would rename
the user's config. That exemption is itself checked (`UiConfig` must not import
`App.Types`), so it cannot quietly become a hole.

## What solo refuses (INV4, SD7)

Entering or leaving solo changes **no** field of `windowPositions`,
`canvasOffset`, `canvasScale`, `sessionOrder`, `planOrder`, `nextZIndex`,
`sessions`, `planWindows`. Solo is free to enter and leave precisely because it
writes nothing but its own key; the geometry the user had before is the geometry
they get back.

This is a rule about **this process's mutable state**, and it does not conflict
with the layout store recording solo: entering or leaving writes `ui.conf`
(that is what "remember which window was alone" means), but it never touches a
rect, an order list or a z. What may not happen is solo's derived viewport
leaking INTO the geometry — see `layoutRects` below.

That extends to gestures: while solo, the wheel does not zoom, the bar does not
drag, no resize handle is rendered, and no keyboard chord leaves the view.
`toDragKind` takes the solo flag as its first argument and returns `Nothing` for
every draggable surface — a *gesture classification* decision, so it lives in
pure Elm where `tests/PointerFsmTest.elm` and `tests/SoloViewTest.elm` pin it.
The JS bridge keeps forwarding pointer events untouched and decides nothing: if
the pipe started filtering, the behavior would exist in exactly the one place
that cannot be elm-tested.

`Ctrl+Shift+F` enters solo and cannot leave it (SD18); `Ctrl+W` closes nothing at
all (SD10); `Esc` closes an open overlay and then stops. Leaving solo is a pointer
act: the ⤡ button, or the global menu's "Exit solo". And while solo there is **no
✕** (SD19) — closing a window belongs to canvas view, so the button is not
rendered rather than styled away.

## Reachability (SD11)

No modal may become unreachable because solo hid its window. Concretely: right
clicking the canvas is impossible in solo (the panel *is* the viewport), so the
solo bar carries a ⋯ button that opens the same global menu; and the ⤡ control
reports how many hidden windows are waiting for an answer ("Canvas · 1 waiting",
highlighted) so a picker left open three windows ago is not lost.

`App/View.elm` renders seven overlay kinds, and the comment at `viewChatArea`
names them as the definition of "waiting on the user". `App.Windows.sessionIsWaiting`
tests the same fields to compute that count, and `tests/SoloViewTest.elm` walks
one case per field. **Add a modal to the view and add its condition to the count,
or solo will hide a prompt nobody can reach.**

## The layout store (`ui.conf`, F3)

What a restart gives back: every window's rect, the canvas pan and zoom, and
which window was solo (SD15). What it does not store: `z` and the order lists
(SD17) — those are derived mutable state that `rebasePositions` deliberately
shrinks, and importing a stale stacking model into a fresh process is worse than
letting stacking follow creation order.

Two dictionaries, two lifetimes, one writer each:

| | `windowPositions` | `uiLayout` |
|---|---|---|
| holds | the board that exists now | where every identity ever was |
| loses an entry when | the window closes | the identity is **deleted** |
| written by | the board operations | `App/UiLayout` |

That asymmetry *is* SD15: closing a session and reopening it an hour later puts
the window back where the user left it, because the identity (a UUID that is never
reused) survived in the file.

**Schema**: `App/UiConfig.elm`, the same discipline `Session/ModelConfig.elm`
applies to `model.conf`, for the same reason — `sync_ui_config` *replaces* the
file, so any field the writer does not model is silently deleted from the user's
layout. Both backends pass the document through as opaque JSON and validate only
its shape, which lets a newer client save a richer file through an older backend.
Top-level unknown keys travel back out via `Document.extras`; per-window keys do
not, so a new per-window field is a deliberate schema change. `version` and
`maxStoredWindows` (200) are the only duplicated numbers, and
`scripts/check-backend-parity.sh` compares them across Rust, Go and Elm while
`testdata/serialization/ui_cases.json` is the accept/refuse table both backends
run.

**Write policy** (SD16): at the **end** of an interaction — pointerup that ended
an active move/resize/pan, a cancelled gesture that had already moved something,
window create, window close, solo enter/exit, session close, zoom reset — plus
exactly one timer, because a wheel burst has no end event: each tick schedules a
single ~1 s idle flush with a generation number, so a 20-tick scroll costs one
write and a superseded generation writes nothing. Never from a `dragMove` path.
`App/UiLayout.syncUiLayout` is the only producer of a payload, and every trigger
in `App/Update.elm` is spelled `withUiSave`, so the whole write set is one grep.

**A client that has not read the file must not write it.** `uiLoaded` gates every
save until the startup read answers (a document, or "no file"). Publishing an
empty store would delete the user's layout with no trace — the same
replace-the-file hazard, applied to the reader.

**Restore never trusts the file** (`App/Windows.storedRect`): a rect below
`minWinW`/`minWinH`, or with coordinates outside the pannable canvas, is refused
and the placement rules decide instead — *not* clamped into an existence nobody
asked for. The `z` is always fresh. A hand-edited `canvasScale` of 0 is refused
because `applyZoom` divides by it. The stored viewport is applied only onto a
viewport nobody has touched yet, because the read is asynchronous and applying it
over an in-progress gesture would yank the board out from under the pointer.

**Solo survives a restart through an intent, not a write.** Sessions do not
auto-reopen, so the stored key lands in `uiSoloPending` and attaches through
`enterSolo` when that window is finally created — which keeps INV2's "a key with
no window is canvas view" true at every moment. Entering solo supersedes the
intent; leaving it clears the flag in the file, so a three-restarts-old solo
cannot hijack a session the user never asked to be alone.

**Pruning is ordered against the cascade, not just against the model.** A delete
closes its windows, and every close writes the whole document — so a prune
applied at the END of the delete arm can lose the race: two
`sync_ui_config` POSTs have no delivery-order guarantee, and a stale document
that lands last resurrects the deleted key. Pruning happens at the TOP of the
arm, before the cascade, which makes every write that follows already correct in
any order. No elm-test can see this (the final model is pruned either way) —
`solo` §12(g), which reads the file back through the RPC, is what caught it. The
general lesson: **model assertions pin what was decided; e2e assertions pin what
arrived.**

**Two clients, one HOME**: the last writer wins and the other tab's rects are
lost. There is no merge, deliberately — merging two boards' positions would
require deciding which client the user is looking through, and the result could
describe a board neither has. Recorded in `App/UiLayout.elm`'s header as the
constraint any successor has to satisfy.

## Testing map

| Layer | Covers |
|---|---|
| `tests/AppWindowsTest.elm` | the accessors, placement rules, `rebasePositions`, z bounds, viewport fallbacks |
| `tests/SoloViewTest.elm` | the solo state machine, geometry derivation, gesture gating, the waiting/attention counts |
| `tests/PointerFsmTest.elm` | the pointer FSM: slop, activation, pan/move/resize/pinch, cancel |
| `tests/UiConfigTest.elm` | the document schema: leniency, per-entry repair, cap arithmetic |
| `tests/UiLayoutTest.elm` | the client policy: envelope decode, what a file may do to the board, absorb/touch, the write gate, every trigger |
| `scripts/check-layout-invariants.sh` | INV1/INV2/INV3 mechanically: read paths, the ratchet, `soloWin` confinement, no solo logic in the bridge |
| `e2e/solo-e2e.mjs` | what only a browser can show: one panel filling the viewport, handles absent, the wheel behaving per view, and §12 — the drag, the file read back through the RPC, a real backend restart, solo re-attaching, the rect coming back, a deleted session pruned |

## Known limits, recorded rather than discovered

- **Solo is not sticky across a crash between the intent and the write.** The
  file says what the last interaction-end write said; SD16 accepted that.
- **The unload flush is best effort** and its failure is silent by design
  (`App/UiLayout`'s comment; `transport.js`'s `teardown` flag is the only write
  that asks to outlive the page).
- **A stored key that never reopens stays in the file** until LRU eviction
  (cap 200) drops it — closed windows are protected by eviction only when they
  are the oldest touched.
- **`e2e/restart-e2e.mjs` asserts behavior across a real restart** for plans; the
  layout half is asserted by `solo` §12, which is the one that restarts the
  backend in place with the same HOME.
