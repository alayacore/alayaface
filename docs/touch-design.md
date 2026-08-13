# Touch & Pointer Input Design

Status: **implemented** (see `TODO.md`; verification green: 466 elm-tests,
5 e2e incl. `touch-e2e.mjs`, Go/Rust untouched).

## Problem

The canvas was mouse-only: pan/window-drag/resize used
`mousedown/mousemove/mouseup`, zoom used `wheel`, the global menu used
`contextmenu`, and the New Session preset flyout was hover-only. On a
touchscreen: no pan (browser steals the gesture), no zoom (pinch
produces no wheel), no menu (long-press is not contextmenu), and the
preset submenu was unreachable (no hover). Worse, a right-button
`mousedown` entered drag mode, and a drag whose `mouseup` was missed
(release outside the window) left the canvas "grabbed" permanently.

## Goals

1. One input abstraction for mouse / touch / pen — no platform special
   cases.
2. Fix structural defects, not just "make touch work":
   - drag state must never stick (release outside the window),
   - hover-only UI must be reachable by touch,
   - touch needs zoom and a context-menu gesture,
   - iOS long-press must not open the system callout.
3. Keep the architecture: Elm is the single source of truth for
   behavior (gesture state machine, elm-tested); JS is a dumb pipe for
   what Elm cannot do (pointer capture, compat-event suppression);
   backends Go/Rust are untouched (parity script unchanged).

## Design decisions

### D1 — Pointer Events unify input

Drag-type mouse events are replaced by Pointer Events
(`pointerdown/move/up/cancel`), which carry `pointerId`, `pointerType`
and `button`. Migrated: canvas pan, session/plan window move, resize
handles, and the move/up subscriptions. Kept as-is: `click` (buttons,
menu items, DAG nodes — taps synthesize it), `contextmenu` (mouse
right-click; trackpad two-finger tap = button 2), `wheel` (mouse wheel
and trackpad pinch = ctrl+wheel).

### D2 — JS is a dumb pipe; the gesture FSM lives in Elm

`transport.js` (capture phase on document) does exactly four mechanical
things:

1. classify the pointerdown target via `closest()` →
   `canvas | session-bar | plan-bar | session-handle | plan-handle |
   content | menu | overlay | other` (plan kinds decided by the
   presence of `.plan-panel`);
2. for **primary** contact (`button === 0` or touch/pen) on a
   **draggable** surface: `setPointerCapture` (move/up keep flowing
   even when released outside the window — fixes the stuck-drag) and
   `preventDefault` (suppresses compat mouse events → one input path;
   `click` still fires);
3. forward every raw event:
   `{ pointerId, pointerType, button, clientX, clientY, targetKind,
   sessionId, planId, handle }`;
4. swallow the click that a long-press release produces (so the menu
   it just opened does not close on finger lift).

No gesture logic in JS. Elm (`App/Pointer.elm` pure module +
`App/Update.elm` FSM) decides tap vs drag vs pinch vs long-press.

### D3 — CSS `touch-action` instead of JS preventDefault races

`touch-action: none` on `.main-content`, `.session-bar`, `.plan-bar`,
`.resize-handle` — the deterministic way to stop the browser stealing
the gesture. Scroll containers (`.messages`, `.plan-page-canvas`,
menus) keep the default, so native touch scrolling/selection works
there. `overscroll-behavior: none` kills pull-to-refresh while panning.

### D4 — one drag state

`canvasDrag` / `dragInfo` / `resizeInfo` (three parallel states, the
source of the stuck-drag class of bugs) merge into a single
`DragState`:

```elm
type DragKind = Pan | WindowMove String | WindowResize String ResizeHandle
              | PlanMove String | PlanResize String ResizeHandle

type alias DragState =
    { kind : DragKind, pointerId : Int
    , startMouseX : Float, startMouseY : Float, active : Bool
    , startWinX : Int, startWinY : Int, startWinW : Int, startWinH : Int
    , startOffsetX : Int, startOffsetY : Int }
```

`active` flips when the pointer crosses the slop. `handleResizeMove`
now reads the origin from `DragState` instead of `model.resizeInfo`.

### D5 — gesture classification (Elm FSM)

- **Drag**: primary pointerdown on a draggable surface arms a drag with
  an origin snapshot; it stays inert (a tap) until movement crosses
  the **4px slop**. Activation raises + focuses window drags. A tap on
  a window bar activates the window on pointerup (pointer capture
  suppresses the compat mousedown that used to activate on mousedown).
- **Pinch**: when a second canvas pointer lands (and no drag is in
  motion, and any armed drag is itself a canvas pan), the pan arm and
  long-press are discarded and a pinch starts at the current distance;
  moves zoom by `current/start` distance centered on the midpoint.
  Lifting one finger ends the pinch without falling into a drag.
- **Long-press** (touch, or pen without buttons): 500 ms hold on the
  canvas with no movement opens the global menu at the finger — the
  touch equivalent of right-click. Movement past the slop cancels it
  (the drag wins). When the menu opens, the inert pan arm is discarded
  so moving with the menu open never pans underneath it.
- **Tap**: none of the above → native `click` (buttons, menu items,
  DAG nodes, window activation).
- Secondary/middle buttons never start a drag (`button === 0` only).

### D6 — hover-dependent UI becomes pointer-aware

DOM `mouseenter/mouseleave` fire for touch taps too (compat events:
tap = enter → click → leave), so a hover flyout driven by them opens
and closes in the same tap — unreachable on touch. The preset submenu
now:

- opens/closes on `click` (a toggle — clicking the item again closes
  it; tapping outside closes the whole menu, which resets the flyout),
- never opens on hover — a mouse over the item must not reveal the
  flyout; it only opens from an explicit click (or tap).

### D7 — coarse-pointer ergonomics

`@media (pointer: coarse)`: title bar min-height 44px, resize handles
enlarged (corner 22px, edges 12px), menu item padding up.
`@media (hover: none)`: custom overlay scrollbar thumbs hidden
(`overlay.js` also skips installing them — native touch scroll works).

### D8 — scroll containers stay native

Pointerdown on `content/menu/overlay` is never captured nor
preventDefaulted, and `touch-action` is untouched there: message
scrolling, plan-DAG scrolling and iOS text selection/callout keep
working. `-webkit-touch-callout: none` is applied only to draggable
surfaces.

## Gesture semantics

| Desktop | Touch |
|---|---|
| left-drag canvas → pan | single-finger drag canvas → pan |
| left-drag bar/handle | single-finger drag bar/handle |
| wheel / trackpad pinch → zoom | two-finger pinch → zoom (midpoint) |
| right-click → global menu | long-press 500 ms → global menu |
| click → preset submenu | tap → submenu opens; tap outside closes |
| title tooltips | visible copy / aria (where critical) |

## Files

- `src-elm/src/App/Pointer.elm` — pure input module: types, decoder,
  slop/long-press constants, distance/midpoint/pinch math.
- `src-elm/src/App/Types.elm` — `DragKind/DragState/PinchState/
  LongPress`, `toDragKind`, `handleFromString`, model fields, msgs.
- `src-elm/src/App/Update.elm` — gesture FSM (`Pointer*`,
  `LongPressFired`).
- `src-elm/src/App/Windows.elm` — `handleResizeMove` from `DragState`.
- `src-elm/src/App/View.elm` — drag handlers removed; `data-handle`
  attrs; click-open submenu.
- `src-elm/src/Main.elm`, `src-elm/src/Ports.elm` — pointer ports.
- `src-elm/transport.js` — the dumb pipe (capture/classify/forward,
  long-press click swallow).
- `src-elm/overlay.js` — scrollbar gated on `(hover: hover)`.
- `src-elm/style.css` — touch-action, overscroll, callout, media
  queries.
- `src-elm/tests/PointerTest.elm`, `src-elm/tests/PointerFsmTest.elm`
  — unit tests (466 total green).
- `e2e/touch-e2e.mjs` — CDP touch-emulation e2e (pan, long-press,
  tap-submenu create, window drag, pinch, mouse regression).

## Edge cases handled

- release outside the window → pointer capture keeps move/up flowing;
- OS steals the gesture (notification shade…) → `pointercancel` clears
  drag/pinch/long-press;
- pinch + one finger lifts → pinch ends, no jump into a drag;
- second finger during an active window drag → ignored (no hijack);
- bar grab + canvas finger → bar drag wins (no accidental pinch);
- long-press timer vs drag → movement cancels the menu gesture;
- `pointercancel` from a cancelled tap never leaves state behind.
