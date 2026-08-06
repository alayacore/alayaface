// ─── Elm Backend Bridge ──────────────────────────────────────────────
//
// Plain JS bridge (no npm, no modules). Two backends, one bridge:
//
//   Tauri (Rust)   → window.__TAURI__ present → tauriTransport()
//                    invoke = __TAURI__.core.invoke
//                    onEvent = __TAURI__.event.listen
//   Go (HTTP/WS)   → no __TAURI__ → httpTransport()
//                    invoke = fetch POST /rpc/{cmd}
//                    onEvent = WebSocket /ws ({type, payload} messages)
//
// The Elm port wiring below is identical for both backends.

(function () {
  "use strict";

  // ─── Transport ────────────────────────────────────────────────────
  // interface:
  //   invoke(cmd, args) → Promise<result>          (Tauri invoke parity)
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
      try {
        ws = new WebSocket(proto + "://" + location.host + "/ws");
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
      invoke: function (cmd, args) {
        // Abort long-hanging requests (60s) so the UI never waits
        // forever on a stalled backend.
        var controller = (typeof AbortController !== "undefined") ? new AbortController() : null;
        var timer = controller ? setTimeout(function () { controller.abort(); }, 60000) : null;
        return fetch("/rpc/" + cmd, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
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

    // 2. Subscribe to all Elm ports SYNCHRONOUSLY

    on("createSession", function (data) {
      transport.invoke("create_session", {
        binaryPath: "", configPath: "",
        toolConfirm: data.toolConfirm || null,
      }).then(function (id) { app.ports.onSessionCreated.send(id); })
        .catch(function (err) { console.error("create_session failed:", err); });
    });

    on("closeSession", function (data) {
      transport.invoke("close_session", { sessionId: data.sessionId });
    });

    on("sendPrompt", function (data) {
      transport.invoke("alayacore_send_prompt", {
        sessionId: data.sessionId, text: data.text, media: data.media,
      });
    });

    on("cancelTask", function (data) {
      transport.invoke("alayacore_cancel", { sessionId: data.sessionId });
    });

    on("setModel", function (data) {
      transport.invoke("alayacore_model_set", {
        sessionId: data.sessionId, modelId: data.modelId,
      });
    });

    on("modelSync", function (data) {
      transport.invoke("alayacore_model_sync", {
        sessionId: data.sessionId, config: data.config,
      });
    });

    on("listDefaultModels", function (data) {
      transport.invoke("list_default_models", { binaryPath: "", preset: (data && data.preset) || "" })
        .then(function (models) {
          app.ports.onDefaultModelsList.send({ ok: true, models: models, error: "" });
        })
        .catch(function (err) {
          app.ports.onDefaultModelsList.send({
            ok: false, models: [], error: String((err && err.message) || err),
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
            ok: true, tool_confirm: (res && res.tool_confirm) || "", error: "",
          });
        })
        .catch(function (err) {
          app.ports.onGlobalSettingsList.send({
            ok: false, tool_confirm: "", error: String((err && err.message) || err),
          });
        });
    });

    on("syncGlobalSettings", function (data) {
      transport.invoke("sync_global_settings", {
        config: JSON.stringify({ tool_confirm: data.toolConfirm || "" }),
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

    on("setActivePreset", function (data) {
      transport.invoke("set_active_preset", { name: data.name || "" })
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
      });
    });

    on("sendMcpDecline", function (data) {
      transport.invoke("alayacore_mcp_decline", {
        sessionId: data.sessionId, server: data.server,
      });
    });

    on("sendMcpCancel", function (data) {
      transport.invoke("alayacore_mcp_cancel", { sessionId: data.sessionId });
    });

    on("forkSession", function (data) {
      transport.invoke("fork_session", {
        sourceSessionId: data.sourceSessionId,
        historyId: data.historyId,
        binaryPath: "",
      }).then(function (id) { app.ports.onSessionCreated.send(id); })
        .catch(function (err) { console.error("fork_session failed:", err); });
    });

    on("resumeSession", function (data) {
      transport.invoke("resume_session", {
        sessionId: data.sessionId, binaryPath: "",
      }).then(function (id) {
        app.ports.onSessionCreated.send(id);
        app.ports.onSessionActionResult.send({ ok: true, error: "", kind: "resume" });
      }).catch(function (err) {
        console.error("resume_session failed:", err);
        app.ports.onSessionActionResult.send({
          ok: false, error: String((err && err.message) || err), kind: "resume",
        });
        transport.invoke("list_session_dirs").then(function (dirs) {
          app.ports.onSessionDirs.send(dirs);
        });
      });
    });

    on("listSessionDirs", function () {
      transport.invoke("list_session_dirs").then(function (dirs) {
        app.ports.onSessionDirs.send(dirs);
      });
    });

    on("deleteSessionDir", function (data) {
      transport.invoke("delete_session_dir", { sessionId: data.sessionId })
        .then(function () {
          // Reflect the deletion immediately
          transport.invoke("list_session_dirs").then(function (dirs) {
            app.ports.onSessionDirs.send(dirs);
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
      transport.invoke("fs_list_dir", { path: data.path }).then(function (entries) {
        app.ports.onFsListDir.send(entries);
      });
    });

    on("fsHomeDir", function () {
      transport.invoke("fs_home_dir").then(function (home) {
        app.ports.onFsHomeDir.send(home);
      });
    });

    on("fsResolvePath", function (data) {
      transport.invoke("fs_resolve_path", { path: data.path }).then(function (res) {
        app.ports.onFsResolvePath.send(res);
      });
    });

    on("fsReadFileDataUri", function (data) {
      transport.invoke("fs_read_file_data_uri", { path: data.path }).then(function (uri) {
        app.ports.onFsReadFileDataUri.send(uri);
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
          app.ports.onFsReadResult.send({ ok: true, content: content, error: "" });
        })
        .catch(function (err) {
          app.ports.onFsReadResult.send({
            ok: false, content: "", error: String((err && err.message) || err),
          });
        });
    });

    on("scrollToBottom", function (data) {
      var el = document.querySelector("#msg-input-" + data.sessionId);
      if (el) {
        var panel = el.closest(".session-panel") || el.closest(".chat-area");
        if (panel) {
          var container = panel.querySelector(".messages");
          if (container) { container.scrollTop = container.scrollHeight; }
        }
      }
    });

    on("startMcpAuthFlow", function (data) {
      transport.invoke("start_mcp_auth_flow", {
        sessionId: data.sessionId,
        serverName: data.serverName,
        authUrl: data.authUrl,
      });
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
      });
    });

    on("setCursorPos", function (id) {
      var el = document.getElementById(id);
      if (!el || !el.setSelectionRange) return;
      el.focus();
      el.setSelectionRange(el.value.length, el.value.length);
    });

    on("scrollIntoView", function (id) {
      var el = document.getElementById(id);
      if (el) { el.scrollIntoView({ block: "nearest" }); }
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

    // 4. Scroll tracking: send scroll data from each messages container,
    //    tagged with its session id so Elm keeps per-session scroll state
    function sendScroll(el) {
      if (!el) el = document.querySelector(".messages");
      if (el) {
        var sid = el.getAttribute("data-session");
        if (!sid) return;
        app.ports.onScroll.send({
          sessionId: sid,
          scrollTop: el.scrollTop,
          scrollHeight: el.scrollHeight,
          clientHeight: el.clientHeight,
        });
      }
    }
    sendScroll();
    // Listen for scroll on all present and future .messages containers
    function attachScroll() {
      document.querySelectorAll(".messages").forEach(function(el) {
        if (!el._scrollAttached) {
          el._scrollAttached = true;
          el.addEventListener("scroll", function() { sendScroll(el); }, { passive: true });
        }
      });
    }
    attachScroll();
    // Check for new messages containers periodically (e.g. new sessions)
    var scrollObserver = new MutationObserver(attachScroll);
    scrollObserver.observe(root, { childList: true, subtree: true });

    // 5. Window maximize state
    transport.isMaximized().then(function (v) {
      app.ports.onWindowMaximized.send(v);
    });
    transport.onWindowEvent(function (v) {
      app.ports.onWindowMaximized.send(v);
    });
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
