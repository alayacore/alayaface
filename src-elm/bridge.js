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

    on("modelSync", function (data) {
      transport.invoke("alayacore_model_sync", {
        sessionId: data.sessionId, config: data.config,
      }).catch(function (err) { rpcError("model_sync", data.sessionId, err); });
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
            ok: true,
            tool_confirm: (res && res.tool_confirm) || "",
            builtin_tools: (res && res.builtin_tools) || "",
            error: "",
          });
        })
        .catch(function (err) {
          app.ports.onGlobalSettingsList.send({
            ok: false, tool_confirm: "", builtin_tools: "",
            error: String((err && err.message) || err),
          });
        });
    });

    on("syncGlobalSettings", function (data) {
      transport.invoke("sync_global_settings", {
        config: JSON.stringify({
          tool_confirm: data.toolConfirm || "",
          builtin_tools: data.builtinTools || "",
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
          app.ports.onSessionDirs.send(dirs);
        });
      });
    });

    on("listSessionDirs", function () {
      transport.invoke("list_session_dirs").then(function (dirs) {
        app.ports.onSessionDirs.send(dirs);
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

    // ── Session ↔ node / plan ↔ session connection curves ──────────
    // Two fixed SVG overlays on <body> (outside Elm's vdom):
    //   .node-connection-overlay — focused node session → its node card
    //   .plan-connection-overlay — active plan window → its owning
    //                              session (anchored on the [Plan: …]
    //                              button when visible, else the edge)
    // The plan window is raised to the SECOND layer when one of its node
    // sessions is focused (session z = plan z + 1); the plan overlay is
    // drawn at the plan window's z (same value + later DOM position →
    // above the plan, below the session). The plan↔session overlay is
    // drawn at the session window's z (it runs between two windows).
    var nodeConnection = null;
    var planConnection = null;
    var connSvg = null;
    var connPath = null;
    var planConnSvg = null;
    var planConnPath = null;
    var connRaf = 0;

    function ensureConnSvg() {
      if (connSvg) return connSvg;
      var ns = "http://www.w3.org/2000/svg";
      connSvg = document.createElementNS(ns, "svg");
      connSvg.setAttribute("class", "node-connection-overlay");
      connSvg.style.display = "none";
      connPath = document.createElementNS(ns, "path");
      connPath.setAttribute("class", "node-connection-curve");
      connSvg.appendChild(connPath);
      document.body.appendChild(connSvg);
      return connSvg;
    }

    function ensurePlanConnSvg() {
      if (planConnSvg) return planConnSvg;
      var ns = "http://www.w3.org/2000/svg";
      planConnSvg = document.createElementNS(ns, "svg");
      planConnSvg.setAttribute("class", "plan-connection-overlay");
      planConnSvg.style.display = "none";
      planConnPath = document.createElementNS(ns, "path");
      planConnPath.setAttribute("class", "plan-connection-curve");
      planConnSvg.appendChild(planConnPath);
      document.body.appendChild(planConnSvg);
      return planConnSvg;
    }

    function connSessionPanel(sid) {
      var panels = document.querySelectorAll(".session-panel");
      for (var i = 0; i < panels.length; i++) {
        if (panels[i].dataset.session === sid) return panels[i];
      }
      return null;
    }

    function connPlanPanel(planId) {
      var panels = document.querySelectorAll(".plan-panel");
      for (var i = 0; i < panels.length; i++) {
        if (panels[i].dataset.plan === planId) return panels[i];
      }
      return null;
    }

    function connNodeEl(planPanel, nodeId) {
      if (!planPanel) return null;
      var nodes = planPanel.querySelectorAll(".plan-node");
      for (var i = 0; i < nodes.length; i++) {
        var idEl = nodes[i].querySelector(".plan-node-id");
        if (idEl && idEl.textContent === nodeId) return nodes[i];
      }
      return null;
    }

    // The [Plan: <planId>] button inside the owning session (the status
    // bar under the plan message, or a feedback link). Returns its rect
    // if one is found AND visible within the session panel's viewport,
    // else null (caller falls back to the session window edge).
    function connPlanButtonRect(sessionPanel, planId) {
      if (!sessionPanel) return null;
      var sr = sessionPanel.getBoundingClientRect();
      var marker = "[Plan: " + planId + "]";
      var btns = sessionPanel.querySelectorAll("button");
      for (var i = 0; i < btns.length; i++) {
        if ((btns[i].textContent || "").indexOf(marker) === -1) continue;
        var r = btns[i].getBoundingClientRect();
        // Visible = intersects the session panel's content area.
        if (r.width > 0 && r.height > 0 &&
            r.right > sr.left && r.left < sr.right &&
            r.bottom > sr.top && r.top < sr.bottom) {
          return r;
        }
      }
      return null;
    }

    // Edge anchor on a panel: the midpoint of the side nearest the
    // target point.
    function edgeAnchor(rect, tx, ty) {
      var cx = rect.left + rect.width / 2;
      var cy = rect.top + rect.height / 2;
      var dx = tx - cx, dy = ty - cy;
      var ax = Math.abs(dx), ay = Math.abs(dy);
      if (ax > ay) {
        return dx > 0
          ? { x: rect.right, y: cy }
          : { x: rect.left, y: cy };
      }
      return dy > 0
        ? { x: cx, y: rect.bottom }
        : { x: cx, y: rect.top };
    }

    // Cubic bezier with TWO independent control points, offset on
    // OPPOSITE sides of the travel line → an "S" shape with two reverse
    // arcs (user preference, 2025). cp1 leaves `from` pulled toward `to`
    // and bowed one way; cp2 arrives at `to` bowed the other way; the
    // curve crosses the straight line at its midpoint.
    function curvePath(from, to) {
      var dx = to.x - from.x, dy = to.y - from.y;
      var dist = Math.sqrt(dx * dx + dy * dy) || 1;
      var ux = dx / dist, uy = dy / dist;
      // Stronger, visible bow (clamped so short hops stay subtle).
      var bow = Math.max(20, Math.min(80, dist * 0.18));
      var bx = -uy * bow, by = ux * bow;
      // Control-point reach: fixed fraction of the distance (kept in a
      // sane band so very long curves still leave/enter smoothly).
      var k = Math.max(0.28, Math.min(0.42, 140 / dist));
      var c1x = from.x + ux * dist * k + bx;
      var c1y = from.y + uy * dist * k + by;
      // Second control point on the OPPOSITE side → reverse arc.
      var c2x = to.x - ux * dist * k - bx;
      var c2y = to.y - uy * dist * k - by;
      return "M " + from.x.toFixed(1) + " " + from.y.toFixed(1)
        + " C " + c1x.toFixed(1) + " " + c1y.toFixed(1)
        + " " + c2x.toFixed(1) + " " + c2y.toFixed(1)
        + " " + to.x.toFixed(1) + " " + to.y.toFixed(1);
    }

    function rectVisibleIn(rect, containerRect) {
      return rect.width > 0 && rect.height > 0 &&
        rect.right > containerRect.left && rect.left < containerRect.right &&
        rect.bottom > containerRect.top && rect.top < containerRect.bottom;
    }

    // The canvas layer has `transform`, which creates a stacking context:
    // window z-indexes now only order windows WITHIN that layer. The
    // connection overlays are fixed on <body>, so to sit between the
    // windows they must offset by the canvas layer's own z-index.
    function canvasZBase() {
      var c = document.querySelector(".canvas");
      return c ? (parseInt(getComputedStyle(c).zIndex, 10) || 0) : 0;
    }

    function drawNodeConnection() {
      if (!nodeConnection) {
        if (connSvg) connSvg.style.display = "none";
        return;
      }
      var s = connSessionPanel(nodeConnection.sessionId);
      var plan = connPlanPanel(nodeConnection.planId);
      var n = connNodeEl(plan, nodeConnection.nodeId);
      if (!s || !plan || !n) {
        if (connSvg) connSvg.style.display = "none";
        return;
      }
      var sr = s.getBoundingClientRect();
      var nr = n.getBoundingClientRect();
      var pr = plan.getBoundingClientRect();
      // Node scrolled out of the plan window's visible area → hide.
      if (!rectVisibleIn(nr, pr)) {
        if (connSvg) connSvg.style.display = "none";
        return;
      }
      var svg = ensureConnSvg();
      // Anchor on the session edge nearest the node center.
      var nx = nr.left + nr.width / 2;
      var ny = nr.top + nr.height / 2;
      var from = edgeAnchor(sr, nx, ny);
      var to = { x: nx, y: ny };
      connPath.setAttribute("d", curvePath(from, to));
      svg.setAttribute("width", String(window.innerWidth));
      svg.setAttribute("height", String(window.innerHeight));
      // Match the plan window's z-index: above it (same z, later in
      // <body>), below the session (session z = planZ + 1). Offset by
      // the canvas layer's z (it creates a stacking context).
      var planZ = parseInt(getComputedStyle(plan).zIndex, 10) || 0;
      svg.style.zIndex = String(canvasZBase() + planZ);
      svg.style.display = "block";
    }

    function drawPlanConnection() {
      if (!planConnection) {
        if (planConnSvg) planConnSvg.style.display = "none";
        return;
      }
      var plan = connPlanPanel(planConnection.planId);
      var s = connSessionPanel(planConnection.sessionId);
      if (!plan || !s) {
        if (planConnSvg) planConnSvg.style.display = "none";
        return;
      }
      var pr = plan.getBoundingClientRect();
      var sr = s.getBoundingClientRect();
      var svg = ensurePlanConnSvg();
      // From the plan window edge nearest the session…
      var scx = sr.left + sr.width / 2;
      var scy = sr.top + sr.height / 2;
      var from = edgeAnchor(pr, scx, scy);
      // …to the session's [Plan: <planId>] button when visible, else the
      // session edge nearest the plan window.
      var pcx = pr.left + pr.width / 2;
      var pcy = pr.top + pr.height / 2;
      var btnRect = connPlanButtonRect(s, planConnection.planId);
      var to = btnRect
        ? { x: btnRect.left + btnRect.width / 2, y: btnRect.top + btnRect.height / 2 }
        : edgeAnchor(sr, pcx, pcy);
      planConnPath.setAttribute("d", curvePath(from, to));
      svg.setAttribute("width", String(window.innerWidth));
      svg.setAttribute("height", String(window.innerHeight));
      // Between two windows: draw at the TOP of the two participants
      // (same z + later DOM position → above both, below anything
      // focused above them). Offset by the canvas layer's z.
      var planZ = parseInt(getComputedStyle(plan).zIndex, 10) || 0;
      var sessionZ = parseInt(getComputedStyle(s).zIndex, 10) || 0;
      svg.style.zIndex = String(canvasZBase() + Math.max(planZ, sessionZ));
      svg.style.display = "block";
    }

    function drawConnections() {
      drawNodeConnection();
      drawPlanConnection();
    }

    on("setNodeConnection", function (data) {
      nodeConnection = data || null;
      if ((nodeConnection || planConnection) && !connRaf) {
        connRaf = requestAnimationFrame(function tick() {
          drawConnections();
          connRaf = (nodeConnection || planConnection) ? requestAnimationFrame(tick) : 0;
        });
      } else if (!nodeConnection && !planConnection) {
        drawConnections(); // hides
      }
    });

    on("setPlanConnection", function (data) {
      planConnection = data || null;
      if ((nodeConnection || planConnection) && !connRaf) {
        connRaf = requestAnimationFrame(function tick() {
          drawConnections();
          connRaf = (nodeConnection || planConnection) ? requestAnimationFrame(tick) : 0;
        });
      } else if (!nodeConnection && !planConnection) {
        drawConnections(); // hides
      }
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
    //    tagged with its session id so Elm keeps per-session scroll state.
    //    Also installs a custom OVERLAY scrollbar: the native scrollbar
    //    is hidden via CSS so it never steals width from the messages
    //    column (messages stay exactly as wide as the prompt input); a
    //    thin thumb floats over the content instead (drag / track-click
    //    supported, native wheel scrolling is untouched).
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

    function updateOverlayScrollbar(el) {
      var sb = el._overlaySb, thumb = el._overlayThumb;
      if (!sb || !thumb) return;
      var scrollable = el.scrollHeight > el.clientHeight + 1;
      sb.style.display = scrollable ? "block" : "none";
      if (!scrollable) return;
      var trackH = sb.clientHeight || Math.max(1, el.clientHeight - 24);
      var thumbH = Math.max(24, trackH * trackH / el.scrollHeight);
      var maxTop = Math.max(0, trackH - thumbH);
      var range = el.scrollHeight - el.clientHeight;
      var ratio = range > 0 ? el.scrollTop / range : 0;
      thumb.style.height = thumbH + "px";
      thumb.style.transform = "translateY(" + (ratio * maxTop) + "px)";
    }

    function attachOverlayScrollbar(el) {
      if (el._overlaySb) return;
      var sb = document.createElement("div");
      sb.className = "overlay-scrollbar";
      var thumb = document.createElement("div");
      thumb.className = "overlay-scrollbar-thumb";
      sb.appendChild(thumb);
      el.appendChild(sb);
      el._overlaySb = sb;
      el._overlayThumb = thumb;

      var dragging = false;
      var dragStartY = 0;
      var dragStartScroll = 0;
      thumb.addEventListener("mousedown", function (e) {
        e.preventDefault();
        e.stopPropagation();
        dragging = true;
        dragStartY = e.clientY;
        dragStartScroll = el.scrollTop;
        thumb.classList.add("dragging");
      });
      window.addEventListener("mousemove", function (e) {
        if (!dragging) return;
        var range = el.scrollHeight - el.clientHeight;
        if (range <= 0) return;
        var trackH = sb.clientHeight || 1;
        var thumbH = thumb.offsetHeight || 24;
        var dy = e.clientY - dragStartY;
        el.scrollTop = dragStartScroll + (dy / Math.max(1, trackH - thumbH)) * range;
      });
      window.addEventListener("mouseup", function () {
        if (!dragging) return;
        dragging = false;
        thumb.classList.remove("dragging");
      });
      // Click on the track (not the thumb) → jump to that position.
      sb.addEventListener("mousedown", function (e) {
        if (e.target === thumb) return;
        var trackH = sb.clientHeight || 1;
        var thumbH = thumb.offsetHeight || 24;
        var y = e.clientY - sb.getBoundingClientRect().top - thumbH / 2;
        var range = el.scrollHeight - el.clientHeight;
        el.scrollTop = (y / Math.max(1, trackH - thumbH)) * range;
      });
      el.addEventListener("scroll", function () { updateOverlayScrollbar(el); }, { passive: true });
      // Container resize (window resize, layout change) → re-measure.
      if (typeof ResizeObserver !== "undefined" && !el._sbResizeObs) {
        el._sbResizeObs = new ResizeObserver(function () { updateOverlayScrollbar(el); });
        el._sbResizeObs.observe(el);
      }
      updateOverlayScrollbar(el);
    }

    sendScroll();
    // Listen for scroll on all present and future .messages containers
    function attachScroll() {
      document.querySelectorAll(".messages").forEach(function(el) {
        if (!el._scrollAttached) {
          el._scrollAttached = true;
          el.addEventListener("scroll", function() { sendScroll(el); }, { passive: true });
        }
        attachOverlayScrollbar(el);
        updateOverlayScrollbar(el);
      });
    }
    attachScroll();
    // Check for new messages containers (e.g. new sessions) and keep
    // the overlay thumbs in sync as content is added.
    var scrollObserver = new MutationObserver(function () {
      attachScroll();
      document.querySelectorAll(".messages").forEach(updateOverlayScrollbar);
    });
    scrollObserver.observe(root, { childList: true, subtree: true });

    // 4b. Canvas zoom: wheel anywhere inside main-content EXCEPT the
    //     native-scrolling .messages list zooms the infinite canvas
    //     centered on the cursor. Non-passive listener so we can
    //     preventDefault() — without it, Ctrl+wheel (pinch) would trigger
    //     the webview's page zoom and plain wheel over the background
    //     could scroll the page. .messages keeps native wheel scrolling.
    document.addEventListener("wheel", function (e) {
      var t = e.target;
      if (!t || typeof t.closest !== "function") return;
      if (!t.closest(".main-content")) return; // overlays don't zoom
      if (t.closest(".messages")) return;      // let messages scroll natively
      if (e.defaultPrevented) return;
      e.preventDefault();
      app.ports.onCanvasWheel.send({
        deltaY: e.deltaY * (e.deltaMode === 1 ? 16 : 1), // normalize line-mode
        clientX: e.clientX,
        clientY: e.clientY,
      });
    }, { passive: false });

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
