# AlayaFace

A Tauri GUI frontend for [AlayaCore](https://github.com/alayacore/alayacore).
Built with **Elm** for the frontend and **Rust** for the Tauri backend.

## Architecture

```
src-elm/              ← Elm frontend (no npm, no bundler)
├── src/
│   ├── Main.elm       — Thin app shell: main/init/subscriptions
│   ├── App/
│   │   ├── Types.elm  — App-level Model, Msg, editor/window types
│   │   ├── Update.elm — All update logic (transport, overlays, windows)
│   │   └── View.elm   — All view functions
│   ├── Ports.elm      — All Tauri IPC ports (inbound + outbound)
│   ├── Fuzzy.elm      — Fuzzy string matching
│   └── Session/
│       ├── Types.elm    — SessionState, Message, ToolCall, etc.
│       ├── Protocol.elm — TLV tag constants, event decoders
│       ├── Selector.elm — Shared list-selector state machine (pure)
│       └── Handlers.elm — Pure event handlers (no side effects)
├── bridge.js          — Plain JS bridge: Elm ports ↔ Tauri __TAURI__
├── index.html         — Entry point (loaded by Tauri webview)
├── style.css          — Application styles
├── homescreen.css     — Home screen / welcome styles
└── tests/             — Elm unit tests (elm-test)

src-tauri/            ← Rust Tauri backend
├── src/
│   ├── main.rs
│   ├── lib.rs          — App entry, Tauri builder
│   ├── commands.rs     — All IPC commands
│   ├── reader.rs       — stdout/stderr readers, TLV frame dispatch
│   ├── session.rs      — Session lifecycle (create, close, fork)
│   ├── tlv.rs          — TLV wire protocol encode/decode
│   ├── alayacore.rs    — Subprocess spawn & binary discovery
│   ├── dirs.rs         — Directory structure (~/.alayaface/)
│   └── event.rs        — Tauri event payload types
└── tauri.conf.json
```

### Data Flow

```
AlayaCore (subprocess)
    │  stdout: TLV frames
    ▼
reader.rs → dispatch_frame() → app.emit("tlv-frame", ...)
    │
    ▼  Tauri event system
bridge.js → listen("tlv-frame") → app.ports.onFrame.send(payload)
    │
    ▼  Elm port
Main.elm → subscriptions → Ports.onFrame → FrameEvent raw
    │
    ▼  Decode + handle
Handlers.elm → handleFrameEvent → update SessionState
    │
    ▼  Render
Main.elm → view → HTML
```

## Requirements

- [Elm](https://elm-lang.org/) 0.19.2 (`elm` in PATH)
- [elm-test](https://elm-test.readthedocs.io/) for running the Elm test suite
- [Rust](https://www.rust-lang.org/) with Cargo
- [AlayaCore](https://github.com/alayacore/alayacore) binary (`alayacore` in PATH or `ALAYACORE_BIN` env var)
- Linux: `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, etc. (see [Tauri prerequisites](https://v2.tauri.app/start/prerequisites/))

## Quick Start

```bash
make run
```

This compiles Elm and launches the Tauri desktop app.

### Individual commands

```bash
make elm    # Compile Elm frontend only (src-elm/ → elm.js)
make run    # Compile Elm + launch Tauri
make dev    # Alias for run
make build  # Release build
make test   # Run Rust unit tests + Elm tests
make clean  # Remove build artifacts
```

### Manual build

```bash
cd src-elm && elm make src/Main.elm --output=elm.js
cd ../src-tauri && cargo run
```

## TLV Protocol

AlayaFace communicates with AlayaCore via TLV (Tag-Length-Value) frames
over stdin/stdout. See the [adapter guide](../alayacore/adapter-guide/README.md)
for the full protocol specification.

Key tags:

| Tag | Direction | Description |
|-----|-----------|-------------|
| UT  | stdin     | User text input |
| UI  | stdin     | User image (data URI or URL) |
| UE  | stdin     | User message end (flush) |
| At  | stdout    | Assistant text streaming delta |
| Ar  | stdout    | Assistant reasoning streaming delta |
| Af  | stdout    | Tool argument streaming delta |
| Uf  | stdout    | Tool result preview snapshot (ephemeral, display-only; UF overwrites) |
| AT  | stdout    | Assistant text complete |
| AR  | stdout    | Assistant reasoning complete |
| AF  | stdout    | Tool call lifecycle |
| UF  | stdout    | Tool result |
| SM  | stdout    | System message (JSON) |

All stdout frames are prefixed with `\x00<history_id>\x00` for streaming
correlation.

## Debugging

TLV frame logs are printed to stderr with the `[tlv]` prefix:

```
[tlv] << abc-123 AT 0b
[tlv] >> abc-123 UT 15b :cancel
[tlv] << abc-123 SM 80b {"type":"task",...}
```

These appear in the terminal when running `cargo run`.

## Porting to Web / VS Code

The Elm core is platform-agnostic (`Session/` modules have no Tauri
dependencies). To port:

1. Replace `bridge.js` with a WebSocket / VS Code postMessage bridge
2. Update `index.html` to load the alternative bridge
3. The `session/` modules remain unchanged
