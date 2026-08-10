// ─── Connection-chain SVG overlays (P36) ────────────────────────────
//
// When a deep node session is focused (or a plan window is activated),
// Elm sends the FULL connection chain via the setConnectionChain port —
// every segment from that window up through each ancestor plan↔session
// pair to the TOP-LEVEL session. One fixed SVG overlay per segment on
// <body> (outside Elm's vdom), z-indexed between the canvas windows.
// Extracted from bridge.js (M4/D5).
//
// Exposes window.AlayaChain.init(app) — called by transport.js after
// the Elm app is created.

(function () {
  "use strict";

  window.AlayaChain = {
    init: function (app) {
      // Typed subscribe with safety check (mirrors transport.js's on()).
      function on(port, cb) {
        var p = app.ports[port];
        if (!p) { console.warn("[chain] port not found:", port); return; }
        if (!p.subscribe) { console.warn("[chain] port has no subscribe:", port); return; }
        p.subscribe(function (v) { cb(v); });
      }

    // ── Connection CHAIN overlays (session ↔ node / plan ↔ session) ─
    // P36: when a deep node session is focused (or a plan window is
    // activated), Elm sends the FULL connection chain — every segment
    // from that window up through each ancestor plan↔session pair to
    // the TOP-LEVEL session. One fixed SVG overlay per segment on
    // <body> (outside Elm's vdom):
    //   kind "node" → .node-connection-overlay — node session → its
    //                  node card (anchored on the session edge nearest
    //                  the node, ends at the node card center)
    //   kind "plan" → .plan-connection-overlay — plan window → its
    //                  owning session (anchored on the [Plan: …] button
    //                  when visible, else the session edge)
    // Each overlay gets its OWN z-index: node curves at their plan
    // window's z (above the plan, below the session — the session is
    // raised to plan z + 1), plan curves at the top of their two
    // participants. The chain windows are stacked top→bottom by Elm
    // (focused window, its plan, that plan's owning session, …), so
    // every curve on the path is visible.
    var chainSegs = [];
    var chainSvgs = [];
    var connRaf = 0;

    // Per-segment SVG (cached by index; recreated on demand).
    function ensureChainSvg(i) {
      while (chainSvgs.length <= i) {
        var ns = "http://www.w3.org/2000/svg";
        var svg = document.createElementNS(ns, "svg");
        svg.style.display = "none";
        var path = document.createElementNS(ns, "path");
        svg.appendChild(path);
        document.body.appendChild(svg);
        chainSvgs.push({ svg: svg, path: path });
      }
      return chainSvgs[i];
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

    // Windows grow z on every activation (unbounded); curves must NEVER
    // climb above the modal overlays (z-index 1000000), or they would
    // cover the dialog. Cap below the overlay.
    var CHAIN_Z_CAP = 900000;
    function chainZ(planZ) {
      return String(Math.min(canvasZBase() + planZ, CHAIN_Z_CAP));
    }

    // Draw one chain segment; hide it when a participant is missing
    // (closed window / plan) or the node card scrolled out of view.
    function drawChainSeg(i, seg) {
      var slot = ensureChainSvg(i);
      var svg = slot.svg, path = slot.path;
      var isNode = seg.kind === "node";
      svg.setAttribute("class", isNode ? "node-connection-overlay" : "plan-connection-overlay");
      path.setAttribute("class", isNode ? "node-connection-curve" : "plan-connection-curve");
      var s = connSessionPanel(seg.sessionId);
      var plan = connPlanPanel(seg.planId);
      if (!s || !plan) {
        svg.style.display = "none";
        return;
      }
      var sr = s.getBoundingClientRect();
      var pr = plan.getBoundingClientRect();
      if (isNode) {
        var n = connNodeEl(plan, seg.nodeId);
        if (!n || !rectVisibleIn(n.getBoundingClientRect(), pr)) {
          svg.style.display = "none";
          return;
        }
        var nr = n.getBoundingClientRect();
        // Anchor on the session edge nearest the node center.
        var nx = nr.left + nr.width / 2;
        var ny = nr.top + nr.height / 2;
        var from = edgeAnchor(sr, nx, ny);
        path.setAttribute("d", curvePath(from, { x: nx, y: ny }));
        // Match the plan window's z-index: above it (same z, later in
        // <body>), below the session (session z = planZ + 1). Capped so
        // curves never cover the modal overlays.
        var planZ = parseInt(getComputedStyle(plan).zIndex, 10) || 0;
        svg.style.zIndex = chainZ(planZ);
      } else {
        // From the plan window edge nearest the session…
        var scx = sr.left + sr.width / 2;
        var scy = sr.top + sr.height / 2;
        var from2 = edgeAnchor(pr, scx, scy);
        // …to the session's [Plan: <planId>] button when visible, else
        // the session edge nearest the plan window.
        var pcx = pr.left + pr.width / 2;
        var pcy = pr.top + pr.height / 2;
        var btnRect = connPlanButtonRect(s, seg.planId);
        var to = btnRect
          ? { x: btnRect.left + btnRect.width / 2, y: btnRect.top + btnRect.height / 2 }
          : edgeAnchor(sr, pcx, pcy);
        path.setAttribute("d", curvePath(from2, to));
        // Between two windows: draw at the TOP of the two participants
        // (same z + later DOM position → above both, below anything
        // focused above them). Offset by the canvas layer's z; capped
        // below the modal overlays.
        var planZ2 = parseInt(getComputedStyle(plan).zIndex, 10) || 0;
        var sessionZ = parseInt(getComputedStyle(s).zIndex, 10) || 0;
        svg.style.zIndex = chainZ(Math.max(planZ2, sessionZ));
      }
      svg.setAttribute("width", String(window.innerWidth));
      svg.setAttribute("height", String(window.innerHeight));
      svg.style.display = "block";
    }

    function drawConnections() {
      var i;
      for (i = 0; i < chainSvgs.length; i++) {
        if (i < chainSegs.length) {
          drawChainSeg(i, chainSegs[i]);
        } else {
          chainSvgs[i].svg.style.display = "none";
        }
      }
      // New chain may have more segments than cached overlays.
      for (i = chainSvgs.length; i < chainSegs.length; i++) {
        drawChainSeg(i, chainSegs[i]);
      }
    }

    function chainTick() {
      // Clear BEFORE drawing: if this callback is lost (rAF throttled in
      // a background tab) or draw throws, connRaf is already 0 so the
      // next setConnectionChain always restarts the loop — "clicking
      // around" can never leave the curves permanently frozen.
      connRaf = 0;
      try {
        drawConnections();
      } catch (e) {
        console.error("[chain] draw failed:", e);
      }
      if (chainSegs.length) {
        connRaf = requestAnimationFrame(chainTick);
      }
    }

    function ensureChainLoop() {
      if (chainSegs.length && !connRaf) {
        connRaf = requestAnimationFrame(chainTick);
      }
    }

    on("setConnectionChain", function (data) {
      chainSegs = data || [];
      if (chainSegs.length) {
        ensureChainLoop();
      } else {
        if (connRaf) cancelAnimationFrame(connRaf);
        connRaf = 0;
        drawConnections(); // hides
      }
    });

    // rAF stalls while the tab is hidden; resume drawing on return.
    document.addEventListener("visibilitychange", function () {
      if (!document.hidden) ensureChainLoop();
    });
    }
  };
})();
