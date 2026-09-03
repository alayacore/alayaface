# Overlay Focus Timing

## Problem

Overlay search inputs (file picker, model selector, help window) did not
auto-focus when opened. On first open, focus went to the input but cursor
was at the beginning instead of the end. On subsequent opens, focus did
not reach the input at all.

## Root Cause

`Dom.focus` is a Task, scheduled asynchronously by Elm's runtime. Within
`Cmd.batch`, Ports execute synchronously while Tasks are deferred. This
can cause `Dom.focus` to run before the browser has finished initializing
a freshly inserted DOM element, causing silent failure.

The file picker happened to work because its command batch includes
`Ports.fsHomeDir {}`, which calls a Tauri invoke. The invoke's `.then()`
microtask implicitly creates a yield point, allowing `Dom.focus` to
execute after the DOM is ready — an accidental fix.

## Solution

Use `focusAfterDelay` instead of bare `Dom.focus`:

```elm
focusAfterDelay : String -> Cmd Msg
focusAfterDelay id =
    Task.attempt (\_ -> NoOp)
        (Process.sleep 0
            |> Task.andThen (\_ -> Dom.focus id)
        )
```

`Process.sleep 0` introduces a **macrotask boundary** that pushes
`Dom.focus` to the next event loop iteration, by which time the
browser has completed layout and rendering of the new element.

Any non-zero `Process.sleep` value would work — the key is the macrotask
boundary, not the specific delay. `Process.sleep 0` is sufficient.

## Cursor Positioning

Cursor position is handled separately via the `setCursorPos` port in
`transport.js`, which calls `el.setSelectionRange(el.value.length, el.value.length)` after focus. This is only called for overlay inputs (IDs
not starting with `msg-input-*`), preserving cursor position in the
prompt textarea.

## Overlay Components

Three overlay components were affected:

| Overlay | Input ID pattern | Handler |
|---------|-----------------|---------|
| File picker | `fp-page-input-{sessionId}` | `OpenFilePicker` |
| Model selector | `model-selector-input-{sessionId}` | `OpenModelSelector` |
| Help window | `help-filter-input-{sessionId}` | `OpenHelpWindow` |

All three now use `focusAfterDelay` on open.

## Additional Changes

- **`autofocus` removed** from all overlay input elements. Browser
  autofocus behavior interferes with programmatic focus control.
- **`pointer-events: none` on `.overlay`**: prevents the overlay
  backdrop from intercepting clicks on the input bar buttons.
- **Escape key**: Overlays are **not** closed by Escape — they are closed
  exclusively via their close (✕) buttons. Escape only dismisses the
  right-click context menu. This prevents accidental dismissal of overlays
  that hold state (e.g. the model editor).

## Files Changed

| File | Change |
|------|--------|
| `src/Main.elm` | Added `focusAfterDelay`, `Process` import; changed all overlay open handlers to use `focusAfterDelay` + `Ports.setCursorPos`; changed `focusInput` to use `Dom.focus`; removed Escape-close for overlays (only the context menu dismisses via Escape) |
| `src/Ports.elm` | Added `setCursorPos` port |
| `transport.js` | `focusElement` port deprecated (no-op); added `setCursorPos` handler; removed `requestAnimationFrame` wrapper from `scrollIntoView` |
| `style.css` | Added `pointer-events: none` to `.overlay`, `pointer-events: auto` to `.overlay-page` |
| `Overlay/FilePicker.elm` | Removed `Attr.autofocus True`; IDs now session-specific |
| `Overlay/ModelSelector.elm` | Removed `Attr.autofocus True`; IDs now session-specific |
| `Overlay/HelpWindow.elm` | Removed `Attr.autofocus True`; IDs now session-specific |
