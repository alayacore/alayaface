// ─── Transport: Elm ports ↔ Tauri (Rust) / HTTP+WS (Go) ────────────
//
// Plain JS, no modules. Two backends, one transport interface:
//
//   Tauri (Rust)   → window.__TAURI__ present → tauriTransport()
//                    invoke = __TAURI__.core.invoke
//                    onEvent = __TAURI__.event.listen
//   Go (HTTP/WS)   → no __TAURI__ → httpTransport()
//                    invoke = fetch POST /rpc/{cmd}
//                    onEvent = WebSocket /ws ({type, payload} messages)
//
// This file wires the Elm RPC ports to the transport and registers the
// backend event listeners. DOM/overlay concerns live in overlay.js
// (scrollbar, canvas zoom, cursor/scroll ports) and chain.js
// (connection-chain SVG overlays) — M4/D5 split of the former
// bridge.js. The Elm port wiring is identical for both backends.

(function () {
  "use strict";

  // Per-page client identity. Persisted in sessionStorage so a page
  // REFRESH keeps the same id (its orphaned sessions are reclaimable),
  // while a new tab gets its own id. close_all_sessions / create /
  // resume carry it so one tab's page load never closes another tab's
  // live sessions (the Go backend is reachable from several clients
  // over LAN/SSH port forwarding).
  var clientId = (function () {
    try {
      var id = window.sessionStorage.getItem("alayaface-client-id");
      if (!id) {
        id = "c-" + Math.random().toString(36).slice(2) + Date.now().toString(36);
        window.sessionStorage.setItem("alayaface-client-id", id);
      }
      return id;
    } catch (e) {
      return "c-" + Date.now().toString(36);
    }
  })();

  // Go backend --token mode: the server injects the token into the
  // served index document as <meta name="alayaface-token"> (Tauri has no
  // token). Every RPC carries it as Authorization: Bearer and the WS URL
  // gets ?token= — without this the documented --token mode would reject
  // all requests from the shipped client (401 on every call, WS handshake
  // failure).
  var backendToken = (function () {
    try {
      var m = document.querySelector('meta[name="alayaface-token"]');
      return m ? (m.getAttribute("content") || "") : "";
    } catch (e) {
      return "";
    }
  })();

  // ─── Transport ────────────────────────────────────────────────────
  // interface:
  //   invoke(cmd, args, timeoutMs?) → Promise<result>
  //       (Tauri invoke parity; timeoutMs bounds the HTTP fetch only —
  //        the Tauri transport has no client-side abort)
  //   onEvent(name, cb) → unlisten | Promise<unlisten>
  //   isMaximized()     → Promise<boolean>
  //   onWindowEvent(cb) → void

  function tauriTransport() {
    var invoke = window.__TAURI__.core.invoke;
    var listen = window.__TAURI__.event.listen;
    return {
      invoke: function (cmd, args) {
        return invoke(cmd, args);
      },
      onEvent: function (name, cb) {
        return listen(name, function (ev) { cb(ev.payload); });
      },
      isMaximized: function () {
        return window.__TAURI__.window.getCurrentWindow().isMaximized();
      },
      onWindowEvent: function (cb) {
        window.__TAURI__.window.getCurrentWindow().onResized(function () {
          window.__TAURI__.window.getCurrentWindow().isMaximized().then(cb);
        });
      },
    };
  }

  function httpTransport() {
    var ws = null;
    var listeners = {}; // event name → [cb]
    var stopped = false;
    var retryDelay = 1000; // ms, backs off up to 10s; resets on connect

    // Stop reconnecting when the page goes away.
    window.addEventListener("beforeunload", function () { stopped = true; });

    function connect() {
      var proto = location.protocol === "https:" ? "wss" : "ws";
      var wsUrl = proto + "://" + location.host + "/ws";
      if (backendToken) {
        wsUrl += "?token=" + encodeURIComponent(backendToken);
      }
      try {
        ws = new WebSocket(wsUrl);
      } catch (e) {
        scheduleReconnect();
        return;
      }
      ws.onopen = function () { retryDelay = 1000; };
      ws.onmessage = function (ev) {
        var msg;
        try { msg = JSON.parse(ev.data); } catch (e) { return; }
        var cbs = listeners[msg.type] || [];
        for (var i = 0; i < cbs.length; i++) { cbs[i](msg.payload); }
      };
      ws.onclose = function () {
        if (stopped) return;
        scheduleReconnect();
      };
      ws.onerror = function () { /* onclose follows */ };
    }
    function scheduleReconnect() {
      setTimeout(connect, retryDelay);
      retryDelay = Math.min(retryDelay * 2, 10000);
    }
    connect();

    return {
      invoke: function (cmd, args, timeoutMs) {
        // Abort long-hanging requests so the UI never waits forever on a
        // stalled backend. The default (60s) covers normal RPCs; callers
        // with a longer backend budget (asr_transcribe allows 120s) pass
        // an explicit timeout. The Tauri transport has no abort at all.
        var limit = (typeof timeoutMs === "number" && timeoutMs > 0) ? timeoutMs : 60000;
        var controller = (typeof AbortController !== "undefined") ? new AbortController() : null;
        var timer = controller ? setTimeout(function () { controller.abort(); }, limit) : null;
        var headers = { "Content-Type": "application/json" };
        if (backendToken) {
          headers["Authorization"] = "Bearer " + backendToken;
        }
        return fetch("/rpc/" + cmd, {
          method: "POST",
          headers: headers,
          body: JSON.stringify(args || {}),
          signal: controller ? controller.signal : undefined,
        }).then(function (res) {
          return res.text().then(function (text) {
            var body = null;
            if (text) {
              try { body = JSON.parse(text); } catch (e) { body = null; }
            }
            if (!res.ok) {
              var err = new Error((body && body.error) || ("HTTP " + res.status));
              err.message = (body && body.error) || ("HTTP " + res.status);
              throw err;
            }
            return body;
          });
        }).finally(function () {
          if (timer) clearTimeout(timer);
        });
      },
      onEvent: function (name, cb) {
        (listeners[name] = listeners[name] || []).push(cb);
        return function () {
          listeners[name] = (listeners[name] || []).filter(function (f) { return f !== cb; });
        };
      },
      isMaximized: function () {
        return Promise.resolve(window.innerHeight >= screen.availHeight);
      },
      onWindowEvent: function (cb) {
        window.addEventListener("resize", function () {
          cb(window.innerHeight >= screen.availHeight);
        });
      },
    };
  }

  var transport = null;

  // ─── App init ─────────────────────────────────────────────────────

  function init() {
    var root = document.getElementById("root");
    if (!root) { console.error("No #root element"); return; }

    // 1. Create Elm app
    var app = Elm.Main.init({ flags: null, node: root });

    // Helper: typed subscribe with safety check
    function on(port, cb) {
      var p = app.ports[port];
      if (!p) { console.warn("[bridge] port not found:", port); return; }
      if (!p.subscribe) { console.warn("[bridge] port has no subscribe:", port); return; }
      p.subscribe(function (v) { cb(v); });
    }

    // Surface a backend RPC failure to the Elm UI (clears stuck
    // "Sending…" states, shows the reason in the session status line).
    function rpcError(kind, sessionId, err) {
      var message = String((err && err.message) || err);
      app.ports.onRpcError.send({
        kind: kind,
        sessionId: sessionId || "",
        message: message,
      });
      console.error("[" + kind + "] failed:", message);
    }

    // 2. Subscribe to all Elm ports SYNCHRONOUSLY

    on("createSession", function (data) {
      transport.invoke("create_session", {
        binaryPath: "", configPath: "",
        toolConfirm: data.toolConfirm || null,
        preset: data.preset || null,
        // Preserve an explicit empty string: Plan Sessions pass
        // builtinTools="" → NO builtin tools (the planner must not
        // execute tools). `|| null` would turn "" into null.
        builtinTools: (data.builtinTools === undefined || data.builtinTools === null)
          ? null : data.builtinTools,
        systemPrompt: data.systemPrompt || null,
        workDir: data.workDir || null,
        // Plan node sessions are stored nested on disk:
        // sessions/<originSessionId>/plans/<planId>/<nodeId>/<uuid>/
        // (plain sessions omit all three).
        planId: (data.planId === undefined || data.planId === null) ? null : data.planId,
        nodeId: (data.nodeId === undefined || data.nodeId === null) ? null : data.nodeId,
        originSessionId: (data.originSessionId === undefined || data.originSessionId === null)
          ? null : data.originSessionId,
        clientId: clientId,
      }).then(function (id) { app.ports.onSessionCreated.send(id); })
        .catch(function (err) {
          console.error("create_session failed:", err);
          app.ports.onSessionCreateError.send(String((err && err.message) || err));
        });
    });

    on("closeSession", function (data) {
      transport.invoke("close_session", { sessionId: data.sessionId })
        .catch(function (err) { rpcError("close_session", data.sessionId, err); });
    });

    on("sendPrompt", function (data) {
      transport.invoke("alayacore_send_prompt", {
        sessionId: data.sessionId, text: data.text, media: data.media,
      }).catch(function (err) { rpcError("send_prompt", data.sessionId, err); });
    });

    on("cancelTask", function (data) {
      transport.invoke("alayacore_cancel", { sessionId: data.sessionId })
        .catch(function (err) { rpcError("cancel_task", data.sessionId, err); });
    });

    on("setModel", function (data) {
      transport.invoke("alayacore_model_set", {
        sessionId: data.sessionId, modelId: data.modelId,
      }).catch(function (err) { rpcError("model_set", data.sessionId, err); });
    });

    on("setReasoningLevel", function (data) {
      transport.invoke("alayacore_reason", {
        sessionId: data.sessionId, level: data.level,
      }).catch(function (err) { rpcError("reason", data.sessionId, err); });
    });

    on("modelSync", function (data) {
      transport.invoke("alayacore_model_sync", {
        sessionId: data.sessionId, config: data.config,
      }).catch(function (err) { rpcError("model_sync", data.sessionId, err); });
    });

    on("listDefaultModels", function (data) {
      transport.invoke("list_default_models", { binaryPath: "", preset: (data && data.preset) || "" })
        .then(function (res) {
          app.ports.onDefaultModelsList.send({
            ok: true,
            models: (res && res.models) || [],
            active_id: (res && res.active_id) || null,
            error: "",
          });
        })
        .catch(function (err) {
          app.ports.onDefaultModelsList.send({
            ok: false, models: [], active_id: null,
            error: String((err && err.message) || err),
          });
        });
    });

    on("setDefaultModel", function (data) {
      const modelId = (data && data.modelId) || 0;
      transport.invoke("set_default_model", {
        preset: (data && data.preset) || "",
        modelId: modelId,
      })
        .then(function () {
          app.ports.onDefaultModelSetResult.send({ ok: true, modelId: modelId, error: "" });
        })
        .catch(function (err) {
          app.ports.onDefaultModelSetResult.send({
            ok: false, modelId: modelId, error: String((err && err.message) || err),
          });
        });
    });

    on("syncDefaultModels", function (data) {
      transport.invoke("sync_default_models", {
        binaryPath: "", config: data.config, preset: (data && data.preset) || "",
      })
        .then(function () {
          app.ports.onDefaultModelsSyncResult.send({ ok: true, error: "" });
        })
        .catch(function (err) {
          app.ports.onDefaultModelsSyncResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("listDefaultMcp", function (data) {
      transport.invoke("list_default_mcp", { preset: (data && data.preset) || "" })
        .then(function (servers) {
          app.ports.onDefaultMcpList.send({ ok: true, servers: servers, error: "" });
        })
        .catch(function (err) {
          app.ports.onDefaultMcpList.send({
            ok: false, servers: [], error: String((err && err.message) || err),
          });
        });
    });

    on("syncDefaultMcp", function (data) {
      transport.invoke("sync_default_mcp", {
        config: data.config, preset: (data && data.preset) || "",
      })
        .then(function () {
          app.ports.onDefaultMcpSyncResult.send({ ok: true, error: "" });
        })
        .catch(function (err) {
          app.ports.onDefaultMcpSyncResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("listGlobalSettings", function (data) {
      transport.invoke("get_global_settings", { preset: (data && data.preset) || "" })
        .then(function (res) {
          app.ports.onGlobalSettingsList.send({
            ok: true,
            tool_confirm: (res && res.tool_confirm) || "",
            builtin_tools: (res && res.builtin_tools) || "",
            system_prompt: (res && res.system_prompt) || "",
            reasoning_level: (res && typeof res.reasoning_level === "number")
              ? res.reasoning_level : 1,
            error: "",
          });
        })
        .catch(function (err) {
          app.ports.onGlobalSettingsList.send({
            ok: false, tool_confirm: "", builtin_tools: "", system_prompt: "",
            reasoning_level: 1,
            error: String((err && err.message) || err),
          });
        });
    });

    on("syncGlobalSettings", function (data) {
      transport.invoke("sync_global_settings", {
        config: JSON.stringify({
          tool_confirm: data.toolConfirm || "",
          builtin_tools: data.builtinTools || "",
          system_prompt: data.systemPrompt || "",
          reasoning_level: (data.reasoningLevel === undefined || data.reasoningLevel === null)
            ? 1 : data.reasoningLevel,
        }),
        preset: (data && data.preset) || "",
      })
        .then(function () {
          app.ports.onGlobalSettingsSyncResult.send({ ok: true, error: "" });
        })
        .catch(function (err) {
          app.ports.onGlobalSettingsSyncResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("getGlobalConfig", function () {
      transport.invoke("get_global_config")
        .then(function (res) {
          app.ports.onGlobalConfigGet.send({
            ok: true,
            recursion_limit: (res && typeof res.recursion_limit === "number") ? res.recursion_limit : 8,
            error: "",
          });
        })
        .catch(function (err) {
          app.ports.onGlobalConfigGet.send({
            ok: false, recursion_limit: 8,
            error: String((err && err.message) || err),
          });
        });
    });

    on("syncGlobalConfig", function (data) {
      transport.invoke("sync_global_config", {
        config: JSON.stringify({ recursion_limit: data.recursionLimit }),
      })
        .then(function (res) {
          app.ports.onGlobalConfigSync.send({
            ok: true,
            recursion_limit: (res && typeof res.recursion_limit === "number") ? res.recursion_limit : data.recursionLimit,
            error: "",
          });
        })
        .catch(function (err) {
          app.ports.onGlobalConfigSync.send({
            ok: false, recursion_limit: data.recursionLimit,
            error: String((err && err.message) || err),
          });
        });
    });

    on("getAsrConfig", function () {
      transport.invoke("get_asr_config")
        .then(function (res) {
          app.ports.onAsrConfigGet.send({
            ok: true,
            active: (res && res.active) || "",
            profiles: (res && res.profiles) || [],
            error: "",
          });
        })
        .catch(function (err) {
          app.ports.onAsrConfigGet.send({
            ok: false, active: "", profiles: [],
            error: String((err && err.message) || err),
          });
        });
    });

    on("syncAsrConfig", function (data) {
      transport.invoke("sync_asr_config", { config: data.config })
        .then(function (res) {
          app.ports.onAsrConfigSync.send({
            ok: true,
            active: (res && res.active) || "",
            profiles: (res && res.profiles) || [],
            error: "",
          });
        })
        .catch(function (err) {
          app.ports.onAsrConfigSync.send({
            ok: false, active: "", profiles: [],
            error: String((err && err.message) || err),
          });
        });
    });

    on("listPresets", function () {
      transport.invoke("list_presets")
        .then(function (presets) {
          app.ports.onPresetsList.send({ ok: true, presets: presets, error: "" });
        })
        .catch(function (err) {
          app.ports.onPresetsList.send({
            ok: false, presets: [], error: String((err && err.message) || err),
          });
        });
    });

    on("copyPreset", function (data) {
      transport.invoke("copy_preset", {
        source: (data && data.source) || "", name: (data && data.name) || "",
      })
        .then(function () { app.ports.onPresetActionResult.send({ ok: true, error: "" }); })
        .catch(function (err) {
          app.ports.onPresetActionResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("renamePreset", function (data) {
      transport.invoke("rename_preset", {
        oldName: data.oldName || "", newName: data.newName || "",
      })
        .then(function () { app.ports.onPresetActionResult.send({ ok: true, error: "" }); })
        .catch(function (err) {
          app.ports.onPresetActionResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("deletePreset", function (data) {
      transport.invoke("delete_preset", { name: data.name || "" })
        .then(function () { app.ports.onPresetActionResult.send({ ok: true, error: "" }); })
        .catch(function (err) {
          app.ports.onPresetActionResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("confirmTool", function (data) {
      transport.invoke("alayacore_confirm", {
        sessionId: data.sessionId, id: data.id, allowed: data.allowed,
      }).catch(function (err) { rpcError("tool_confirm", data.sessionId, err); });
    });

    on("sendMcpDecline", function (data) {
      transport.invoke("alayacore_mcp_decline", {
        sessionId: data.sessionId, server: data.server,
      }).catch(function (err) { rpcError("mcp_decline", data.sessionId, err); });
    });

    on("sendMcpCancel", function (data) {
      transport.invoke("alayacore_mcp_cancel", { sessionId: data.sessionId })
        .catch(function (err) { rpcError("mcp_cancel", data.sessionId, err); });
    });

    on("forkSession", function (data) {
      transport.invoke("fork_session", {
        sourceSessionId: data.sourceSessionId,
        historyId: data.historyId,
        binaryPath: "",
      }).then(function (id) { app.ports.onSessionCreated.send(id); })
        .catch(function (err) { console.error("fork_session failed:", err); });
    });

    // P38: cascade fork — like fork_session but for the re-run cascade's
    // history truncation: the fork carries the node-session attributes so
    // it replaces the parent session in place. The result (success or
    // failure) arrives on the DEDICATED onCascadeForkResult port — the
    // app then routes a success through SessionCreated itself, so the
    // fork's window registration AND the adoption (meta binding rewrite)
    // happen in ONE update: the fork session never renders with the stale
    // pre-fork binding, and a user-created session that races the fork can
    // never be mistaken for it (only this result event triggers the
    // adoption path).
    on("cascadeForkSession", function (data) {
      transport.invoke("fork_session", {
        sourceSessionId: data.sourceSessionId,
        historyId: data.historyId,
        binaryPath: "",
        toolConfirm: data.toolConfirm,
        preset: data.preset,
        builtinTools: data.builtinTools,
        systemPrompt: data.systemPrompt,
        workDir: data.workDir,
        planId: data.planId,
        nodeId: data.nodeId,
        originSessionId: data.originSessionId,
        clientId: clientId,
      }).then(function (id) {
        app.ports.onCascadeForkResult.send({ ok: true, sessionId: id, error: "" });
      }).catch(function (err) {
        console.error("cascade fork_session failed:", err);
        app.ports.onCascadeForkResult.send({
          ok: false, sessionId: "", error: String((err && err.message) || err),
        });
      });
    });

    on("resumeSession", function (data) {
      transport.invoke("resume_session", {
        sessionId: data.sessionId, binaryPath: "",
        workDir: (data && data.workDir) || null,
        planId: (data && data.planId) || null,
        nodeId: (data && data.nodeId) || null,
        originSessionId: (data && data.originSessionId) || null,
        clientId: clientId,
      }).then(function (id) {
        app.ports.onSessionCreated.send(id);
        app.ports.onSessionActionResult.send({ ok: true, error: "", kind: "resume" });
      }).catch(function (err) {
        console.error("resume_session failed:", err);
        app.ports.onSessionActionResult.send({
          ok: false, error: String((err && err.message) || err), kind: "resume",
        });
        transport.invoke("list_session_dirs").then(function (dirs) {
          app.ports.onSessionDirs.send({ ok: true, dirs: dirs, error: "" });
        }).catch(function (err) {
          app.ports.onSessionDirs.send({
            ok: false, dirs: [], error: String((err && err.message) || err),
          });
        });
      });
    });

    on("listSessionDirs", function () {
      transport.invoke("list_session_dirs")
        .then(function (dirs) {
          app.ports.onSessionDirs.send({ ok: true, dirs: dirs, error: "" });
        })
        .catch(function (err) {
          app.ports.onSessionDirs.send({
            ok: false, dirs: [], error: String((err && err.message) || err),
          });
        });
    });

    // Page load: reclaim sessions orphaned by a previous page (refresh).
    // Their windows are gone but the backend still holds the handles;
    // without this, resume_session keeps failing with "Session is
    // already active" until the backend process is restarted. The
    // clientId scopes the reclaim to THIS page's sessions — a second
    // tab (new id) or another client's live sessions are untouched.
    on("closeAllSessions", function () {
      transport.invoke("close_all_sessions", { clientId: clientId }).catch(function (err) {
        console.error("close_all_sessions failed:", err);
      });
    });

    on("deleteSessionDir", function (data) {
      transport.invoke("delete_session_dir", {
        sessionId: data.sessionId,
        planId: (data && data.planId) || null,
        nodeId: (data && data.nodeId) || null,
        originSessionId: (data && data.originSessionId) || null,
      })
        .then(function () {
          // Reflect the deletion immediately
          transport.invoke("list_session_dirs").then(function (dirs) {
            app.ports.onSessionDirs.send({ ok: true, dirs: dirs, error: "" });
          }).catch(function (err) {
            app.ports.onSessionDirs.send({
              ok: false, dirs: [], error: String((err && err.message) || err),
            });
          });
          app.ports.onSessionActionResult.send({ ok: true, error: "", kind: "delete" });
        })
        .catch(function (err) {
          console.error("delete_session_dir failed:", err);
          app.ports.onSessionActionResult.send({
            ok: false, error: String((err && err.message) || err), kind: "delete",
          });
        });
    });

    on("fsListDir", function (data) {
      transport.invoke("fs_list_dir", { path: data.path })
        .then(function (entries) {
          app.ports.onFsListDir.send({
            reqId: data.reqId, ok: true, entries: entries, error: "",
          });
        })
        .catch(function (err) {
          // Surface the failure (with the reqId so Elm routes it to the
          // right flow) instead of silently dropping it — a swallowed
          // failure used to leave the file picker stuck in loading and
          // the plan-meta scan spinning forever.
          app.ports.onFsListDir.send({
            reqId: data.reqId, ok: false, entries: [],
            error: String((err && err.message) || err),
          });
        });
    });

    on("fsHomeDir", function () {
      transport.invoke("fs_home_dir")
        .then(function (home) {
          app.ports.onFsHomeDir.send({ ok: true, home: home, error: "" });
        })
        .catch(function (err) {
          app.ports.onFsHomeDir.send({
            ok: false, home: "", error: String((err && err.message) || err),
          });
        });
    });

    on("fsResolvePath", function (data) {
      transport.invoke("fs_resolve_path", { path: data.path })
        .then(function (res) {
          app.ports.onFsResolvePath.send({
            ok: true, resolved: res.resolved, exists: res.exists, isDir: res.isDir, error: "",
          });
        })
        .catch(function (err) {
          app.ports.onFsResolvePath.send({
            ok: false, resolved: "", exists: false, isDir: false,
            error: String((err && err.message) || err),
          });
        });
    });

    on("fsReadFileDataUri", function (data) {
      transport.invoke("fs_read_file_data_uri", { path: data.path })
        .then(function (uri) {
          app.ports.onFsReadFileDataUri.send({ ok: true, uri: uri, error: "" });
        })
        .catch(function (err) {
          app.ports.onFsReadFileDataUri.send({
            ok: false, uri: "", error: String((err && err.message) || err),
          });
        });
    });

    on("fsWriteFileText", function (data) {
      transport.invoke("fs_write_file_text", {
        path: data.path,
        content: data.content,
        createParents: !!data.createParents,
      }).then(function () {
        app.ports.onFsWriteResult.send({ ok: true, error: "" });
      }).catch(function (err) {
        app.ports.onFsWriteResult.send({
          ok: false, error: String((err && err.message) || err),
        });
      });
    });

    on("fsReadFileText", function (data) {
      transport.invoke("fs_read_file_text", { path: data.path })
        .then(function (content) {
          app.ports.onFsReadResult.send({
            reqId: data.reqId, ok: true, content: content, error: "",
          });
        })
        .catch(function (err) {
          app.ports.onFsReadResult.send({
            reqId: data.reqId, ok: false, content: "",
            error: String((err && err.message) || err),
          });
        });
    });

    on("objectPut", function (data) {
      transport.invoke("object_put", { content: data.content })
        .then(function (res) {
          app.ports.onObjectPut.send({
            reqId: data.reqId, ok: true, hash: (res && res.hash) || "", error: "",
          });
        })
        .catch(function (err) {
          app.ports.onObjectPut.send({
            reqId: data.reqId, ok: false, hash: "",
            error: String((err && err.message) || err),
          });
        });
    });

    on("objectGet", function (data) {
      transport.invoke("object_get", { hash: data.hash })
        .then(function (content) {
          app.ports.onObjectGet.send({
            reqId: data.reqId, ok: true, content: content, error: "",
          });
        })
        .catch(function (err) {
          app.ports.onObjectGet.send({
            reqId: data.reqId, ok: false, content: "",
            error: String((err && err.message) || err),
          });
        });
    });

    on("startMcpAuthFlow", function (data) {
      transport.invoke("start_mcp_auth_flow", {
        sessionId: data.sessionId,
        serverName: data.serverName,
        authUrl: data.authUrl,
      }).catch(function (err) { rpcError("mcp_auth", data.sessionId, err); });
    });

    on("fillMcpAuthUrl", function (data) {
      transport.invoke("fill_mcp_auth_url", {
        sessionId: data.sessionId,
        serverName: data.serverName,
        authUrl: data.authUrl,
      }).then(function (url) {
        navigator.clipboard.writeText(url).catch(function (e) {
          console.error("copyToClipboard failed:", e);
        });
      }).catch(function (err) {
        // Surface the failure (dead session / backend error) so Elm can
        // release the running-auth marker instead of sticking forever.
        rpcError("mcp_auth", data.sessionId, err);
      });
    });

    // 3. Register backend event listeners (Tauri events / WS messages)
    Promise.all([
      transport.onEvent("tlv-delta", function (payload) { app.ports.onDelta.send(payload); }),
      transport.onEvent("tlv-frame", function (payload) { app.ports.onFrame.send(payload); }),
      transport.onEvent("core-status", function (payload) { app.ports.onStatus.send(payload); }),
    ]).then(function () {
      console.log("[bridge] event listeners ready");
    }).catch(function (e) {
      console.error("[bridge] listen() failed:", e);
    });
    // DOM/overlay modules (split files, same IIFE-scope pattern):
    //   chain.js   — connection-chain SVG overlays (P36)
    //   overlay.js — overlay scrollbar (P37), canvas zoom, cursor/scroll ports
    window.AlayaChain.init(app);
    window.AlayaOverlay.init(app, root, transport);
    installPointerPipe(app);

    // 5. Window maximize state
    transport.isMaximized().then(function (v) {
      app.ports.onWindowMaximized.send(v);
    });
    transport.onWindowEvent(function (v) {
      app.ports.onWindowMaximized.send(v);
    });
  }

  // ─── Pointer input pipe (touch & pointer design D1/D2) ─────────────
  //
  // A DUMB pipe — no gesture logic here. It classifies the pointerdown
  // target, captures + preventDefaults draggable surfaces (so move/up
  // keep flowing even when released outside the window, and the compat
  // mouse events are suppressed for a single input path), and forwards
  // every raw event to Elm. The gesture state machine (drag / pinch /
  // long-press) lives in App/Update + App/Pointer and is elm-tested.
  //
  // Classification order matters: handles and bars are INSIDE panels,
  // so check the most specific selectors first. Plan windows carry
  // both .plan-panel and .session-panel (they are session panels), so
  // plan kinds are decided by presence of .plan-panel.
  var DRAGGABLE = [".main-content", ".session-bar", ".resize-handle"];

  function pointerTargetKind(e) {
    var t = e.target;
    if (!t || typeof t.closest !== "function") return "other";
    if (t.closest(".resize-handle")) {
      return t.closest(".plan-panel") ? "plan-handle" : "session-handle";
    }
    if (t.closest(".session-bar")) {
      return t.closest(".plan-panel") ? "plan-bar" : "session-bar";
    }
    if (t.closest(".global-menu")) return "menu";
    if (t.closest(".overlay") || t.closest(".ctx-overlay") || t.closest(".ctx-menu")) return "overlay";
    if (t.closest(".session-panel")) return "content";
    if (t.closest("#main-content")) return "canvas";
    return "other";
  }

  function pointerPayload(e, kind) {
    var t = e.target;
    var panel = (t && t.closest) ? t.closest(".session-panel") : null;
    var plan = (t && t.closest) ? t.closest(".plan-panel") : null;
    var handle = (t && t.closest) ? t.closest(".resize-handle") : null;
    return {
      pointerId: e.pointerId,
      pointerType: e.pointerType || "mouse",
      button: e.button,
      clientX: e.clientX,
      clientY: e.clientY,
      targetKind: kind,
      sessionId: (panel && panel.dataset) ? (panel.dataset.session || "") : "",
      planId: (plan && plan.dataset) ? (plan.dataset.plan || "") : "",
      handle: (handle && handle.dataset) ? (handle.dataset.handle || "") : "",
    };
  }

  function isDraggable(kind) {
    return kind === "canvas" || kind === "session-bar" || kind === "plan-bar" ||
           kind === "session-handle" || kind === "plan-handle";
  }

  function isPrimary(e) {
    // Primary contact: left button (mouse/pen) or any touch contact.
    return e.button === 0 || e.pointerType !== "mouse";
  }

  function installPointerPipe(app) {
    // Long-press menu: Elm opens the global menu on a 500ms touch hold
    // (App/Pointer.longPressMs). The finger release produces a click
    // that would bubble to .app and close the menu it just opened, so
    // when Elm says the menu opened we swallow exactly the next click
    // (a new pointerdown — any new gesture — re-arms the swallow).
    var swallowNextClick = false;
    if (app.ports.longPressMenuOpened && app.ports.longPressMenuOpened.subscribe) {
      app.ports.longPressMenuOpened.subscribe(function () { swallowNextClick = true; });
    }
    document.addEventListener("click", function (e) {
      if (swallowNextClick) {
        swallowNextClick = false;
        e.preventDefault();
        e.stopPropagation();
      }
    }, true);

    // Capture phase: sees pointerdown even where bubble handlers stop
    // propagation, so classification is always based on the real target.
    document.addEventListener("pointerdown", function (e) {
      swallowNextClick = false;
      var kind = pointerTargetKind(e);
      if (isDraggable(kind) && isPrimary(e) && e.target && e.target.setPointerCapture) {
        try { e.target.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
        // Suppress compatibility mouse events (single input path) and
        // text selection. Click still fires, so taps on bars/handles
        // keep working.
        e.preventDefault();
      }
      app.ports.onPointerDown.send(pointerPayload(e, kind));
    }, true);
    document.addEventListener("pointermove", function (e) {
      app.ports.onPointerMove.send(pointerPayload(e, pointerTargetKind(e)));
    }, true);
    document.addEventListener("pointerup", function (e) {
      app.ports.onPointerUp.send(pointerPayload(e, pointerTargetKind(e)));
    }, true);
    document.addEventListener("pointercancel", function (e) {
      app.ports.onPointerCancel.send(pointerPayload(e, pointerTargetKind(e)));
    }, true);
  }

  // Wait for DOM + backend to be ready. __TAURI__ may be injected after
  // this script runs (Tauri webview), but in a plain browser it never
  // appears — so bound the wait, then fall back to the HTTP transport.
  function waitForBackend(cb, attempts) {
    if (window.__TAURI__ && window.__TAURI__.core) {
      transport = tauriTransport();
      cb();
      return;
    }
    if (attempts <= 0) {
      transport = httpTransport();
      cb();
      return;
    }
    setTimeout(function () { waitForBackend(cb, attempts - 1); }, 50);
  }

  function ready(cb) {
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", function () {
        waitForBackend(cb, 5); // up to ~250ms for __TAURI__ to appear
      });
    } else {
      waitForBackend(cb, 5);
    }
  }
  ready(init);
})();
