# Go Backend Design (HTTP + WebSocket, Shared Elm Client)

## 1. Goal and Shared Boundary

The project currently has a single Tauri (Rust) + Elm backend. The goal is to add a
**Go backend** that provides an HTTP service implementing the equivalent functionality
of the Rust backend (starting/managing AlayaCore subprocesses, TLV forwarding,
preset/model/MCP/settings/filesystem commands), while **sharing the same Elm client**
with the Rust backend.

Shared boundary:

| Layer | Content | Shared? |
|-------|---------|---------|
| Elm application logic | `src-elm/src/**` (Main / App / Session / Ports) | ✅ Fully shared, zero changes |
| Frontend static assets | `elm.js`, `index.html`, `style.css`, `homescreen.css` | ✅ Shared (served by Go) |
| JS bridge layer | `src-elm/bridge.js` | 🔧 Minimal change: abstract `__TAURI__.invoke / listen` into a transport |
| Backend | `src-tauri/**` ↔ new `src-go/**` | ❌ Separate implementations, **behavior and JSON shapes must match** |

Key conclusion: **the only contract between Elm and the backend is the JSON format**.
As long as the Go backend produces request arguments / return values / pushed events
identical to Rust, the Elm client can be reused as-is.

---

## 2. Transport Design

Rust/Tauri has two channels, each of which needs a Go counterpart:

| Tauri channel | Semantics | Go counterpart |
|---------------|-----------|----------------|
| `invoke(cmd, args) → Promise<result>` | Request/response (30 commands) | `POST /rpc/{command}` |
| `event.listen(name, cb)` | Server push (tlv-delta / tlv-frame / core-status) | WebSocket `GET /ws` |

### 2.1 Command channel: RPC-style `POST /rpc/{command}`

**RPC style is recommended over full REST**, because:

1. **Lowest alignment cost**: a Tauri invoke is exactly `(command name, args object) → result`.
   `POST /rpc/create_session` + JSON body maps 1:1; bridge.js changes are compressed
   to "swap the invoke implementation", with no 30-entry command→URL/method table in JS.
2. **Consistent validation**: Rust commands take snake_case param names (e.g. `binary_path`)
   converted by serde from camelCase at the invoke layer; Go aligns via `json:"binaryPath"`
   tags matching the camelCase args bridge.js already sends.
3. A REST facade (`/api/...`) can be added later for curl/external tooling, but is not
   the primary channel, avoiding dual-API drift.

Protocol:

- Request: `POST /rpc/{command}`, body = JSON args object (identical to invoke args,
  `Content-Type: application/json`).
- Success: `200`, body = command return value (identical to the Tauri invoke resolve
  value; `create_session` returns a bare string `"<sessionId>"`, `list_presets` returns
  an array, etc.).
- Failure: `4xx/5xx`, body = `{"error": "..."}`, aligned with Tauri rejection semantics
  (bridge.js's `.catch(err => String(err.message || err))` stays unchanged).
- Void commands (e.g. `close_session`): `200` + empty body.

### 2.2 Event channel: WebSocket `GET /ws`

One-way push (server → client), message format:

```json
{ "type": "tlv-delta",  "payload": { ...DeltaEvent... } }
{ "type": "tlv-frame",  "payload": { ...FrameEvent... } }
{ "type": "core-status","payload": { ...StatusEvent... } }
```

`payload` field names must match the Tauri event payloads byte-for-byte (see §4).

- Multiple sessions share one WS connection, distinguished by `session_id` in the payload.
- Reconnection is handled by bridge.js (exponential backoff); no server-side state
  recovery is needed — sessions live in the Go process memory, and the Elm side
  reconciles via existing flows (`list_session_dirs` / `onStatus`) after reconnect.
- Optional extension: `GET /ws?session=<id>` filtering, for future multi-tab/debugging.

---

## 3. Command Mapping (Rust command → Go endpoint)

| Rust command | Go endpoint | Args (camelCase) | Return |
|--------------|-------------|------------------|--------|
| `create_session` | `POST /rpc/create_session` | `binaryPath`, `configPath`, `toolConfirm`(nullable) | string sessionId |
| `resume_session` | `POST /rpc/resume_session` | `sessionId`, `binaryPath` | string sessionId |
| `close_session` | `POST /rpc/close_session` | `sessionId` | — |
| `list_session_dirs` | `POST /rpc/list_session_dirs` | — | `[{id, has_session_file, created_at}]` |
| `delete_session_dir` | `POST /rpc/delete_session_dir` | `sessionId` | — |
| `fork_session` | `POST /rpc/fork_session` | `sourceSessionId`, `historyId`, `binaryPath` | string sessionId |
| `alayacore_send_prompt` | `POST /rpc/alayacore_send_prompt` | `sessionId`, `text`, `media:[{media_type,uri}]` | — |
| `alayacore_cancel` | `POST /rpc/alayacore_cancel` | `sessionId` | — |
| `alayacore_model_set` | `POST /rpc/alayacore_model_set` | `sessionId`, `modelId`(int) | — |
| `alayacore_model_sync` | `POST /rpc/alayacore_model_sync` | `sessionId`, `config` | — |
| `alayacore_confirm` | `POST /rpc/alayacore_confirm` | `sessionId`, `id`, `allowed` | — |
| `alayacore_mcp_decline` | `POST /rpc/alayacore_mcp_decline` | `sessionId`, `server` | — |
| `alayacore_mcp_cancel` | `POST /rpc/alayacore_mcp_cancel` | `sessionId` | — |
| `list_models` | `POST /rpc/list_models` | `binaryPath`, `configPath` | `[model]` |
| `list_default_models` | `POST /rpc/list_default_models` | `binaryPath`, `preset` | `[model]` |
| `sync_default_models` | `POST /rpc/sync_default_models` | `binaryPath`, `config`, `preset` | CO `output` |
| `list_default_mcp` | `POST /rpc/list_default_mcp` | `preset` | `[server]` |
| `sync_default_mcp` | `POST /rpc/sync_default_mcp` | `config`, `preset` | — |
| `get_global_settings` | `POST /rpc/get_global_settings` | `preset` | `{tool_confirm}` |
| `sync_global_settings` | `POST /rpc/sync_global_settings` | `config`, `preset` | — |
| `list_presets` | `POST /rpc/list_presets` | — | `[{name, is_active}]` |
| `copy_preset` | `POST /rpc/copy_preset` | `source`, `name` | — |
| `rename_preset` | `POST /rpc/rename_preset` | `oldName`, `newName` | — |
| `delete_preset` | `POST /rpc/delete_preset` | `name` | — |
| `set_active_preset` | `POST /rpc/set_active_preset` | `name` | — |
| `fs_list_dir` | `POST /rpc/fs_list_dir` | `path` | `[{name, isDir}]` |
| `fs_home_dir` | `POST /rpc/fs_home_dir` | — | string |
| `fs_resolve_path` | `POST /rpc/fs_resolve_path` | `path` | `{resolved, exists, isDir}` |
| `fs_read_file_data_uri` | `POST /rpc/fs_read_file_data_uri` | `path` | string data URI |
| `start_mcp_auth_flow` | `POST /rpc/start_mcp_auth_flow` | `sessionId`, `serverName`, `authUrl` | string filled URL |
| `fill_mcp_auth_url` | `POST /rpc/fill_mcp_auth_url` | `sessionId`, `serverName`, `authUrl` | string filled URL |

> Note: snake_case fields in Rust command returns (`has_session_file`, `is_active`,
> `tool_confirm`, `media_type`, ...) are serde defaults (no rename). Go JSON tags must
> match these exactly — do not "fix" them to camelCase — the Elm decoders read these keys.

---

## 4. Event Payload Parity Contract (most important)

The Elm decoders in `Session/Protocol.elm` decode the following keys; the Go side must
match them field-for-field:

### DeltaEvent (At/Ar streaming deltas)
```json
{ "session_id": "…", "history_id": "…", "content": "…", "tag": "At" }
```

### FrameEvent (complete frames)
```json
{
  "session_id": "…",
  "tag": "AT",
  "raw_value": "…",
  "history_id": "…|null",
  "content": "…|null",
  "json": { } | null,
  "user_content_type": "…|null"
}
```
Rust `Option` fields serialize as `null` (no `skip_serializing_if`); Go must use
`*string` / `any` with **no** `omitempty` so the keys always exist.

### StatusEvent
```json
{ "session_id": "…", "connected": true, "message": "…" }
```

### Behavior contract (matches reader.rs)
- `At/Ar` emit **only** `tlv-delta`, never `tlv-frame` (double dispatch causes
  unnecessary re-renders on the Elm side).
- `AT/AR` go through `tlv-frame`; empty content maps to `content: null` (`empty_to_none`).
- `Af/AF/UF/Uf`: parse the NUL prefix and attach `json` (null if parsing fails).
- `CO`: **command-name injection** — look up `pending_commands[callId]` and inject the
  command name into the JSON `name` field before emitting.
- `SM`: transform to `{type, data}` before emitting (same as Rust `handle_sm_frame`).
- Any `SM model_list` updates the model cache first (global, shared across sessions).
- Reader on EOF/error: `connected=false`, kill the child, emit `core-status`, exit loop.

---

## 5. Go Backend Project Layout

```
src-go/
├── go.mod
├── cmd/
│   └── alayaface-server/
│       └── main.go            # entry: parse flags, assemble server, graceful shutdown
├── internal/
│   ├── tlv/                   # ← port of tlv.rs
│   │   └── tlv.go             #   encode / readFrame / writeFrame / unwrapDelta
│   ├── core/                  # ← port of alayacore.rs
│   │   └── core.go            #   findBinary / spawn(--rawio) / killChild
│   ├── dirs/                  # ← port of dirs.rs
│   │   └── dirs.go            #   ~/.alayaface layout, presets, session dirs
│   ├── session/               # ← port of session.rs
│   │   ├── session.go         #   SessionHandle / SessionMap / create / close / get
│   │   └── reader.go          # ← port of reader.rs: stdout goroutine + dispatchFrame
│   ├── probe/                 # ← port of models.rs TempCore/run_temp_probe
│   │   └── probe.go           #   throwaway alayacore probes (model_list / model_sync)
│   ├── mcp/                   # ← port of mcp.rs OAuth part
│   │   └── oauth.go           #   127.0.0.1:0 callback server + URL fill + open browser + 5min timeout
│   ├── hub/                   #   WebSocket event bus (new)
│   │   └── hub.go             #   Hub{clients} + Broadcast(Event) + per-connection write goroutine
│   └── server/
│       ├── server.go          #   http.Server, routing, static files, CORS
│       ├── rpc.go             #   POST /rpc/{command} dispatcher (command→handler registry)
│       ├── ws.go              #   GET /ws upgrade + read loop (keepalive/disconnect)
│       └── handlers/          # ← port of commands/*
│           ├── sessions.go
│           ├── io.go
│           ├── cmd.go
│           ├── models.go
│           ├── mcp_conf.go    #   mcp.conf parse/serialize (second half of mcp.rs)
│           ├── presets.go
│           ├── settings.go
│           └── fs.go
```

Prefer the standard library; only one third-party dependency is required:

- `github.com/gorilla/websocket` (WS upgrade/read/write)
- Open browser via `os/exec` calling `xdg-open` / `open` / `rundll32` (or
  `github.com/pkg/browser`) — no extra dependency needed.

---

## 6. Per-Module Porting Notes

### 6.1 tlv (internal/tlv)
- Frame format `[2B tag][4B BE len][len bytes value]` ported as-is.
- **Partial reads**: Go's `io.ReadFull` (Rust's `read_exact`) must be used for both the
  header and the value — never a bare `Read`.
- EOF detection: header under-read means EOF → return `(nil, nil)`; value under-read is
  a protocol error.
- Port `unwrapDelta` NUL-prefix parsing, including edge cases (no prefix, empty id,
  embedded NULs in content), mirroring tlv.rs test cases one by one.

### 6.2 core (internal/core)
- `findBinary`: `ALAYACORE_BIN` → `which/where alayacore` → common paths → fallback
  `"alayacore"`.
- `spawn(binary, configPath, sessionPath, toolConfirm)`: `--rawio`, optional
  `--config-path / --session / --tool-confirm=`; piped stdin/stdout, inherited stderr.
- `killChild`: close stdin → `Process.Kill` → poll `Wait` for 3s → force kill.

### 6.3 session + reader (internal/session)
```go
type Session struct {
    id          string
    stdin       io.WriteCloser
    stdinMu     sync.Mutex        // concurrent-write guard (Rust's tokio Mutex)
    connected   atomic.Bool
    pendingCmds sync.Map          // callID → commandName (CO injection)
    child       *exec.Cmd
    sessionDir  string
    cancel      context.CancelFunc
}
type SessionManager struct { mu sync.Mutex; sessions map[string]*Session }
```
- One **stdout reader goroutine** per session: `bufio.Reader` loop `tlv.ReadFrame` →
  `dispatchFrame` → `hub.Broadcast(...)`.
- Exit cleanup: EOF/error → `connected=false`, `killChild`, broadcast `core-status`,
  remove from manager (Rust relies on Drop; Go must do this explicitly in `close()`).
- All stdin writes go through `session.WriteFrame(tag, value)`: check connected → lock →
  `writeFrame` + `flush`.

### 6.4 model probes (internal/probe)
Port `run_temp_probe` wholesale: spawn temp process → (optionally) send one CI →
close stdin → read frames for 5s, collect `SM model_list` (refresh cache) and/or the
matching `CO` → kill process. Note Rust passes `--config-path` only when non-empty
(same as the real spawn); `list_default_models` must use a temp probe, not the session
cache (different semantics).

### 6.5 mcp.conf parsing (internal/handlers/mcp_conf.go)
`---`-separated key-value blocks: split_kv_line (skip blank lines / `#`), unquote,
dash→underscore key mapping (`auth-type`→`auth_type`, etc.), `args`/`env` normalized
to compact JSON text, filter by `server` key, infer `type` (url present → http,
else stdio); write back in fixed `MCP_CONF_ORDER`.

### 6.6 MCP OAuth (internal/mcp)
Rust uses a non-blocking `TcpListener 127.0.0.1:0` poll loop; Go uses
`net.Listen("tcp", "127.0.0.1:0")` + a small http.Server (or a hand-rolled handler).
Logic aligned: random state → replace `{{redirect_uri}}`/`{{state}}` → open browser →
validate state/code in callback → send `mcp_confirm`/`mcp_decline` (CI command) →
return the filled URL. 5-minute timeout fallback via `context.WithTimeout` closing the server.

### 6.7 Other plain commands
presets / settings / fs are pure filesystem operations — direct ports;
`normalize_tool_confirm`, `valid_preset_name`, directory copy (excluding
`settings.conf`) keep the same behavior as Rust; port their tests accordingly.

---

## 7. bridge.js Changes (the only frontend change)

Current state: bridge.js calls `__TAURI__.core.invoke` / `__TAURI__.event.listen`
in ~40 places.

Plan: a **transport abstraction** — bridge.js picks the implementation at the top
based on the environment; the remaining ~40 call sites change only to
`transport.invoke(...)` / `transport.onEvent(...)`, zero logic changes:

```js
var transport = (window.__TAURI__ && window.__TAURI__.core)
  ? tauriTransport()   // invoke → __TAURI__.core.invoke
                       // onEvent → __TAURI__.event.listen
  : httpTransport();   // invoke → POST /rpc/{cmd} (body=args, 200=result, else reject)
                       // onEvent → WebSocket /ws (dispatch by type + reconnect)
```

- `httpTransport.invoke(cmd, args)`: `fetch("/rpc/"+cmd, {method:"POST",
  headers:{"Content-Type":"application/json"}, body: JSON.stringify(args||{})})`;
  reject `{message: body.error}` on non-2xx so `.catch(err => String(err.message||err))`
  behaves like Tauri.
- `httpTransport.onEvent(name, cb)`: a single internal WS; on `{type, payload}` call
  `cb(payload)` when `type===name`; reconnect with exponential backoff.
- Window-maximize event: in browser mode degrade to
  `window.innerHeight >= screen.availHeight` + `resize` listener (Tauri branch unchanged).

Thus **index.html doesn't change** (still loads the same bridge.js); the Tauri and Go
runtimes auto-switch on the presence of `window.__TAURI__`, avoiding two bridge files.

> Optional: override the backend URL via `window.ALAYA_BACKEND_URL` (default same-origin),
> useful for separating the Go port from static hosting or for debugging.

---

## 8. Static Assets and Startup

- The Go server serves `GET /` statically from `../src-elm/` (`elm.js`, `index.html`,
  `bridge.js`, css, icons). Set correct MIME (`.js` → `text/javascript`) and
  `Cache-Control: no-cache` for development; hash-based caching in production.
- Startup flags:
  ```
  alayaface-server \
    --addr 127.0.0.1:8765 \
    --static ../src-elm \
    [--alayacore-bin /path/to/alayacore] \
    [--token <random>]        # optional: validated on WS/fetch to protect against other local processes
  ```
- Bind to `127.0.0.1` only; CORS as needed (not needed for same-origin deployment).
- Graceful shutdown: SIGINT/SIGTERM → close all sessions (killChild) →
  `http.Server.Shutdown`.

---

## 9. Testing Strategy

| Suite | Content | Reference |
|-------|---------|-----------|
| Go unit tests | tlv encode/decode/partial-read/EOF/NUL edges; dirs creation/exclusion of settings.conf; preset lifecycle; settings normalize; mcp.conf parse roundtrip | port the same-named Rust tests one by one |
| Go integration (optional) | start server + fake alayacore (a `sh`/`python` script echoing TLV frames) to verify create/send/close end-to-end | — |
| Elm tests | unchanged — verify the shared client is not broken | `make test` |
| Dual-backend smoke | run the same Elm frontend against both Tauri and Go, diff the event streams | manual |

---

## 10. Phased Implementation Plan

1. **P0 skeleton**: `go.mod`, `main.go`, `internal/tlv` (with tests), static hosting + `/ws` empty hub.
2. **P1 session core**: `core` + `session` + `reader` + `hub` + `rpc.go`; implement
   create/resume/close/send_prompt/cancel plus tlv-delta/frame/status push.
   → conversation main flow works (minimal viable).
3. **P2 remaining commands**: cmd (model_set/model_sync/confirm/mcp_*) + fork + session-dir management.
4. **P3 config domain**: presets, settings, models (incl. probes), mcp.conf, MCP OAuth.
5. **P4 frontend wrap-up**: bridge.js transport abstraction, window-event degradation, reconnection.
6. **P5 wrap-up**: Makefile (`make run-go` / `make test-go`), README update, integration tests.

---

## 11. Risks and Caveats

1. **JSON field-name drift** (highest risk): any mismatch in return/push field names or
   null semantics silently breaks Elm decoding. Treat `Session/Protocol.elm` and the Rust
   serde output as the single source of truth; add JSON round-trip tests to lock the Go
   struct formats.
2. **Concurrent stdin writes**: prompts may race with CI commands; a per-session write
   lock is required.
3. **Child-process cleanup**: Go has no Drop; every exit path (close, reader EOF, server
   shutdown) must explicitly killChild to avoid zombies.
4. **CO injection ordering**: register `pendingCmds` **before** writing the CI frame
   (the race point Rust comments call out).
5. **Temp probes**: `list_default_models` etc. must not read the session cache; use temp probes.
6. **Dual-backend coexistence**: both backends share `~/.alayaface/sessions/<uuid>`;
   resuming the same session dir from both sides at once conflicts (Rust already guards
   double-resume). Recommend using one backend at a time; document "do not operate the
   same session from both backends simultaneously".
7. **WS/fetch ordering**: Elm command callbacks (onSessionCreated etc.) come via fetch
   promises, events via WS — independent. Go must ensure `create_session` returns only
   after the session is registered and the reader goroutine is started (same ordering as
   Rust), so `onStatus` is not received before `onSessionCreated`.
