// ─── Elm-Tauri Bridge ────────────────────────────────────────────────
//
// Plain JS bridge (no npm, no modules). Uses window.__TAURI__ global
// API (enabled by app.withGlobalTauri in tauri.conf.json).
//
// To port to web/VS Code: replace __TAURI__ calls accordingly.

(function () {
  "use strict";

  const invoke = window.__TAURI__.core.invoke;
  const listen = window.__TAURI__.event.listen;

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
      invoke("create_session", {
        binaryPath: "", configPath: "",
        toolConfirm: data.toolConfirm || null,
      }).then(function (id) { app.ports.onSessionCreated.send(id); });
    });

    on("closeSession", function (data) {
      invoke("close_session", { sessionId: data.sessionId });
    });

    on("sendPrompt", function (data) {
      invoke("alayacore_send_prompt", {
        sessionId: data.sessionId, text: data.text, media: data.media,
      });
    });

    on("cancelTask", function (data) {
      invoke("alayacore_cancel", { sessionId: data.sessionId });
    });

    on("setModel", function (data) {
      invoke("alayacore_model_set", {
        sessionId: data.sessionId, modelId: data.modelId,
      });
    });

    on("modelSync", function (data) {
      invoke("alayacore_model_sync", {
        sessionId: data.sessionId, config: data.config,
      });
    });

    on("listDefaultModels", function () {
      invoke("list_default_models", { binaryPath: "" })
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
      invoke("sync_default_models", { binaryPath: "", config: data.config })
        .then(function () {
          app.ports.onDefaultModelsSyncResult.send({ ok: true, error: "" });
        })
        .catch(function (err) {
          app.ports.onDefaultModelsSyncResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("listDefaultMcp", function () {
      invoke("list_default_mcp")
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
      invoke("sync_default_mcp", { config: data.config })
        .then(function () {
          app.ports.onDefaultMcpSyncResult.send({ ok: true, error: "" });
        })
        .catch(function (err) {
          app.ports.onDefaultMcpSyncResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("listGlobalSettings", function () {
      invoke("get_global_settings")
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
      invoke("sync_global_settings", {
        config: JSON.stringify({ tool_confirm: data.toolConfirm || "" }),
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
      invoke("list_presets")
        .then(function (presets) {
          app.ports.onPresetsList.send({ ok: true, presets: presets, error: "" });
        })
        .catch(function (err) {
          app.ports.onPresetsList.send({
            ok: false, presets: [], error: String((err && err.message) || err),
          });
        });
    });

    on("createPreset", function (data) {
      invoke("create_preset", { name: data.name || "" })
        .then(function () { app.ports.onPresetActionResult.send({ ok: true, error: "" }); })
        .catch(function (err) {
          app.ports.onPresetActionResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("renamePreset", function (data) {
      invoke("rename_preset", {
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
      invoke("delete_preset", { name: data.name || "" })
        .then(function () { app.ports.onPresetActionResult.send({ ok: true, error: "" }); })
        .catch(function (err) {
          app.ports.onPresetActionResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("setActivePreset", function (data) {
      invoke("set_active_preset", { name: data.name || "" })
        .then(function () { app.ports.onPresetActionResult.send({ ok: true, error: "" }); })
        .catch(function (err) {
          app.ports.onPresetActionResult.send({
            ok: false, error: String((err && err.message) || err),
          });
        });
    });

    on("confirmTool", function (data) {
      invoke("alayacore_confirm", {
        sessionId: data.sessionId, id: data.id, allowed: data.allowed,
      });
    });

    on("sendMcpDecline", function (data) {
      invoke("alayacore_mcp_decline", {
        sessionId: data.sessionId, server: data.server,
      });
    });

    on("sendMcpCancel", function (data) {
      invoke("alayacore_mcp_cancel", { sessionId: data.sessionId });
    });

    on("forkSession", function (data) {
      invoke("fork_session", {
        sourceSessionId: data.sourceSessionId,
        historyId: data.historyId,
        binaryPath: "",
      }).then(function (id) { app.ports.onSessionCreated.send(id); });
    });

    on("resumeSession", function (data) {
      invoke("resume_session", {
        sessionId: data.sessionId, binaryPath: "",
      });
    });

    on("listSessionDirs", function () {
      invoke("list_session_dirs").then(function (dirs) {
        app.ports.onSessionDirs.send(dirs);
      });
    });

    on("deleteSessionDir", function (data) {
      invoke("delete_session_dir", { sessionId: data.sessionId });
    });

    on("fsListDir", function (data) {
      invoke("fs_list_dir", { path: data.path }).then(function (entries) {
        app.ports.onFsListDir.send(entries);
      });
    });

    on("fsHomeDir", function () {
      invoke("fs_home_dir").then(function (home) {
        app.ports.onFsHomeDir.send(home);
      });
    });

    on("fsResolvePath", function (data) {
      invoke("fs_resolve_path", { path: data.path }).then(function (res) {
        app.ports.onFsResolvePath.send(res);
      });
    });

    on("fsReadFileDataUri", function (data) {
      invoke("fs_read_file_data_uri", { path: data.path }).then(function (uri) {
        app.ports.onFsReadFileDataUri.send(uri);
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
      invoke("start_mcp_auth_flow", {
        sessionId: data.sessionId,
        serverName: data.serverName,
        authUrl: data.authUrl,
      });
    });

    on("fillMcpAuthUrl", function (data) {
      invoke("fill_mcp_auth_url", {
        sessionId: data.sessionId,
        serverName: data.serverName,
        authUrl: data.authUrl,
      }).then(function (url) {
        navigator.clipboard.writeText(url).catch(function (e) {
          console.error("copyToClipboard failed:", e);
        });
      });
    });

                on("focusElement", function (id) {
      // Deprecated: focusing is now done via Elm's Dom.focus (FocusElement msg).
      // This port is kept for backward compatibility but does nothing.
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

        // 3. Register Tauri event listeners
    Promise.all([
      listen("tlv-delta", function (ev) { app.ports.onDelta.send(ev.payload); }),
      listen("tlv-frame", function (ev) { app.ports.onFrame.send(ev.payload); }),
      listen("core-status", function (ev) { app.ports.onStatus.send(ev.payload); }),
    ]).then(function () {
      console.log("[bridge] Tauri event listeners ready");
    }).catch(function (e) {
      console.error("[bridge] listen() failed:", e);
    });

    // 4. Scroll tracking: send scroll data from each messages container
    function sendScroll(el) {
      if (!el) el = document.querySelector(".messages");
      if (el) {
        app.ports.onScroll.send({
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
    window.__TAURI__.window.getCurrentWindow().isMaximized().then(function (v) {
      app.ports.onWindowMaximized.send(v);
    });
    window.__TAURI__.window.getCurrentWindow().onResized(function () {
      window.__TAURI__.window.getCurrentWindow().isMaximized().then(function (v) {
        app.ports.onWindowMaximized.send(v);
      });
    });
  }

  // Wait for DOM + __TAURI__ to be ready
  function waitForTauri(cb) {
    if (window.__TAURI__ && window.__TAURI__.core) {
      console.log("[bridge] __TAURI__ available, keys:",
        Object.keys(window.__TAURI__).join(", "));
      if (window.__TAURI__.event) {
        console.log("[bridge] event API available");
      } else {
        console.warn("[bridge] event API NOT available");
      }
      cb();
    } else {
      setTimeout(function () { waitForTauri(cb); }, 10);
    }
  }
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", function () { waitForTauri(init); });
  } else {
    waitForTauri(init);
  }
})();
