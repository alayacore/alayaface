// ─── Connection-chain curves inside the canvas (P39/Phase A) ────────
//
// Elm sends the FULL connection chain plus the canvas state via the
// setConnectionChain port:
//   { segments:   [{kind, sessionId, planId, nodeId}]
//   , positions:  [{id, x, y, w, h, z}]      // every window, CANVAS coords
//   , planScroll: [{planId, scrollTop, scrollLeft}]  // plan DAG scrollers
//   , canvasScale: float }
//
// chain.js draws one bezier per segment as an absolutely-positioned
// <svg class="connection-seg"> INSIDE .canvas — canvas coordinates, so
// the canvas layer's transform carries the curves through pan/zoom for
// free. No body-level SVG, no canvasZBase offset, no z cap, no per-frame
// rAF: redraws happen only on DISCRETE events (chain change, window
// drag/resize, plan DAG scroll, zoom — all re-emit the port from Elm).
//
// Window rects come from Elm (never measured). Only two DOM reads stay:
// the node-card offset inside its plan panel (offsetParent walk, scroll-
// independent) and the [Plan: …] button offset inside the owning
// session — both tiny, both at redraw time only.
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

      // ── Connection CHAIN segments (P36/P39) ───────────────────────
      // One <svg class="connection-seg"> per segment, child of .canvas:
      //   kind "node" → session window edge → the node card center
      //                  inside its plan window (plan DAG scroll offsets
      //                  the card — compensated via planScroll);
      //   kind "plan" → plan window edge → the session's [Plan: …]
      //                  button when visible, else the session edge.
      // z-index per segment (from Elm's window z values, bounded by the
      // rebase): node curves at their plan window's z (above the plan,
      // below the session), plan curves at the top of their two
      // participants — so no curve is buried and none can ever reach
      // the modal overlays (z 1000000 lives OUTSIDE the canvas).
      var payload = { segments: [], positions: [], planScroll: [], canvasScale: 1 };
      var segSvgs = [];   // {svg, path, seg} — cached per chain index
      var canvasEl = null;

      function posMap() {
        var m = {};
        for (var i = 0; i < payload.positions.length; i++) {
          var p = payload.positions[i];
          m[p.id] = p;
        }
        return m;
      }

      function scrollMap() {
        var m = {};
        for (var i = 0; i < payload.planScroll.length; i++) {
          var s = payload.planScroll[i];
          m[s.planId] = s;
        }
        return m;
      }

      // .canvas is created by Elm's vdom; Elm may replace it when the
      // window list toggles empty↔non-empty, orphaning our svgs. Track
      // the element and re-create/re-append on change.
      function ensureCanvas() {
        var c = document.querySelector(".canvas");
        if (c && c !== canvasEl) {
          canvasEl = c;
          segSvgs = [];
        }
        return c;
      }

      function ensureSegSvg(i) {
        var canvas = ensureCanvas();
        if (!canvas) return null;
        while (segSvgs.length <= i) {
          var ns = "http://www.w3.org/2000/svg";
          var svg = document.createElementNS(ns, "svg");
          svg.setAttribute("class", "connection-seg");
          svg.style.position = "absolute";
          svg.style.pointerEvents = "none";
          svg.style.overflow = "visible";
          svg.style.display = "none";
          var path = document.createElementNS(ns, "path");
          svg.appendChild(path);
          canvas.appendChild(svg);
          segSvgs.push({ svg: svg, path: path, seg: null });
        }
        var slot = segSvgs[i];
        // Re-append if Elm reordered children (e.g. a new window was
        // added after our svgs — z-index keeps the paint order, but the
        // svg must stay INSIDE the canvas).
        if (slot.svg.parentNode !== canvas) canvas.appendChild(slot.svg);
        return slot;
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

      // The [Plan: <planId>] button inside the owning session (the
      // status bar under the plan message, or a feedback link). Returns
      // the button element if visible, else null (caller falls back to
      // the session window edge).
      function connPlanButton(sessionPanel, planId) {
        if (!sessionPanel) return null;
        var marker = "[Plan: " + planId + "]";
        var btns = sessionPanel.querySelectorAll("button");
        for (var i = 0; i < btns.length; i++) {
          if ((btns[i].textContent || "").indexOf(marker) === -1) continue;
          var r = btns[i].getBoundingClientRect();
          var sr = sessionPanel.getBoundingClientRect();
          // Visible = intersects the session panel's content area.
          if (r.width > 0 && r.height > 0 &&
              r.right > sr.left && r.left < sr.right &&
              r.bottom > sr.top && r.top < sr.bottom) {
            return btns[i];
          }
        }
        return null;
      }

      // Element's top-left offset relative to `ancestor` (sum of the
      // offsetParent chain — scroll containers are skipped, so the
      // result is scroll-independent; the caller subtracts planScroll).
      function offsetWithin(elm, ancestor) {
        var x = 0, y = 0, e = elm;
        while (e && e !== ancestor) {
          x += e.offsetLeft;
          y += e.offsetTop;
          e = e.offsetParent;
        }
        return { x: x, y: y };
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

      // Edge anchor on a rect: the midpoint of the side nearest the
      // target point (canvas coordinates throughout).
      function edgeAnchor(rect, tx, ty) {
        var cx = rect.x + rect.w / 2;
        var cy = rect.y + rect.h / 2;
        var dx = tx - cx, dy = ty - cy;
        var ax = Math.abs(dx), ay = Math.abs(dy);
        if (ax > ay) {
          return dx > 0
            ? { x: rect.x + rect.w, y: cy }
            : { x: rect.x, y: cy };
        }
        return dy > 0
          ? { x: cx, y: rect.y + rect.h }
          : { x: cx, y: rect.y };
      }

      // Cubic bezier with TWO independent control points, offset on
      // OPPOSITE sides of the travel line → an "S" shape with two
      // reverse arcs (user preference, 2025). cp1 leaves `from` pulled
      // toward `to` and bowed one way; cp2 arrives at `to` bowed the
      // other way; the curve crosses the straight line at its midpoint.
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

      // Node card CENTER in canvas coordinates: plan window pos (from
      // Elm) + the card's offset inside the plan panel (DOM, scroll-
      // independent) − the plan DAG scroller's offset (Elm via port).
      function nodeCenter(pos, planPanel, nodeId, scroll) {
        var node = connNodeEl(planPanel, nodeId);
        if (!node) return null;
        var off = offsetWithin(node, planPanel);
        var st = scroll || { top: 0, left: 0 };
        return {
          x: pos.x + off.x + node.offsetWidth / 2 - st.left,
          y: pos.y + off.y + node.offsetHeight / 2 - st.top,
        };
      }

      // Draw one chain segment. Returns the path `d` and the segment's
      // bounding box (canvas coords), or null when a participant is
      // missing (closed window / plan / node card).
      function segmentGeometry(seg, positions, scrolls) {
        var sRect = positions[seg.sessionId];
        var pRect = positions[seg.planId];
        if (!sRect || !pRect) return null;
        var sPanel = connSessionPanel(seg.sessionId);
        var pPanel = connPlanPanel(seg.planId);
        if (!sPanel || !pPanel) return null;

        if (seg.kind === "node") {
          var n = nodeCenter(pRect, pPanel, seg.nodeId, scrolls[seg.planId]);
          if (!n) return null;
          var from = edgeAnchor(sRect, n.x, n.y);
          return { from: from, to: n, z: pRect.z };
        }

        // Plan → owning session. Anchor the session end on its [Plan:
        // <planId>] button when visible, else the session edge nearest
        // the plan window.
        var scx = sRect.x + sRect.w / 2;
        var scy = sRect.y + sRect.h / 2;
        var from2 = edgeAnchor(pRect, scx, scy);
        var btn = connPlanButton(sPanel, seg.planId);
        var to;
        if (btn) {
          var boff = offsetWithin(btn, sPanel);
          to = {
            x: sRect.x + boff.x + btn.offsetWidth / 2,
            y: sRect.y + boff.y + btn.offsetHeight / 2,
          };
        } else {
          to = edgeAnchor(sRect, pRect.x + pRect.w / 2, pRect.y + pRect.h / 2);
        }
        return { from: from2, to: to, z: Math.max(pRect.z, sRect.z) };
      }

      function drawConnections() {
        var canvas = ensureCanvas();
        if (!canvas) return;
        var positions = posMap();
        var scrolls = scrollMap();
        var i;
        // Hide/update cached svgs, create new ones as needed.
        for (i = 0; i < payload.segments.length; i++) {
          var slot = ensureSegSvg(i);
          if (!slot) return;
          var seg = payload.segments[i];
          var g = segmentGeometry(seg, positions, scrolls);
          if (!g) {
            slot.svg.style.display = "none";
            continue;
          }
          // The svg covers the participants' bounding box; the curve's
          // bow may extend past it — overflow: visible draws it anyway.
          var x0 = Math.min(g.from.x, g.to.x);
          var y0 = Math.min(g.from.y, g.to.y);
          var x1 = Math.max(g.from.x, g.to.x);
          var y1 = Math.max(g.from.y, g.to.y);
          slot.svg.setAttribute("x", String(x0));
          slot.svg.setAttribute("y", String(y0));
          slot.svg.setAttribute("width", String(Math.max(1, x1 - x0)));
          slot.svg.setAttribute("height", String(Math.max(1, y1 - y0)));
          slot.svg.style.left = x0 + "px";
          slot.svg.style.top = y0 + "px";
          slot.svg.style.zIndex = String(g.z);
          slot.path.setAttribute("class",
            seg.kind === "node" ? "node-connection-curve" : "plan-connection-curve");
          // Stroke-width compensation: the canvas layer is scaled by
          // canvasScale, so a 3 screen-px stroke needs 3 / scale.
          slot.path.setAttribute("stroke-width", String(3 / (payload.canvasScale || 1)));
          slot.path.setAttribute("d", curvePath(
            { x: g.from.x - x0, y: g.from.y - y0 },
            { x: g.to.x - x0, y: g.to.y - y0 }
          ));
          slot.svg.style.display = "block";
        }
        // Extra cached svgs (chain shrank) → hide.
        for (i = payload.segments.length; i < segSvgs.length; i++) {
          segSvgs[i].svg.style.display = "none";
        }
      }

      on("setConnectionChain", function (data) {
        payload = data || payload;
        if (!payload.segments) payload.segments = [];
        if (!payload.positions) payload.positions = [];
        if (!payload.planScroll) payload.planScroll = [];
        if (typeof payload.canvasScale !== "number") payload.canvasScale = 1;
        // Discrete redraw only — no rAF loop. Pan/zoom need no redraw
        // (the svgs live inside .canvas, the transform moves them); the
        // discrete events that change canvas geometry (drag/resize/
        // scroll/zoom/chain) all re-emit this port.
        drawConnections();
      });
    }
  };
})();
