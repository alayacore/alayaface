// ─── Overlay scrollbar (P37), canvas zoom, cursor/scroll ports ───────
//
// DOM-side concerns of the former bridge.js (M4/D5): the custom overlay
// scrollbar for .messages containers (native scrollbar hidden via CSS),
// canvas zoom on wheel over the empty background (windows scroll
// natively), and the cursor/scroll ports
// that need direct DOM access. Exposes window.AlayaOverlay.init(app,
// root) — called by transport.js after the Elm app is created.

(function () {
  "use strict";

  window.AlayaOverlay = {
    init: function (app, root) {
      // Typed subscribe with safety check (mirrors transport.js's on()).
      function on(port, cb) {
        var p = app.ports[port];
        if (!p) { console.warn("[overlay] port not found:", port); return; }
        if (!p.subscribe) { console.warn("[overlay] port has no subscribe:", port); return; }
        p.subscribe(function (v) { cb(v); });
      }

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
      // The track lives in the NON-scrolling .chat-area wrapper (an
      // absolute child of the scrolling .messages itself would scroll
      // away with the content — the thumb vanished the moment the user
      // scrolled down). Pin it to the messages area every update using
      // LAYOUT offsets (offsetTop/offsetLeft/client* are unscaled by the
      // canvas transform, unlike getBoundingClientRect).
      var host = sb.parentElement;
      if (host && host !== el) {
        sb.style.top = (el.offsetTop + 12) + "px";
        sb.style.bottom = (host.clientHeight - el.offsetTop - el.offsetHeight + 12) + "px";
        sb.style.right = (host.clientWidth - el.offsetLeft - el.offsetWidth + 4) + "px";
      }
      var trackH = sb.clientHeight || Math.max(1, el.clientHeight - 24);
      var thumbH = Math.max(24, trackH * trackH / el.scrollHeight);
      var maxTop = Math.max(0, trackH - thumbH);
      var range = el.scrollHeight - el.clientHeight;
      var ratio = range > 0 ? el.scrollTop / range : 0;
      thumb.style.height = thumbH + "px";
      thumb.style.transform = "translateY(" + (ratio * maxTop) + "px)";
    }

    // The custom overlay thumb is mouse-oriented (drag / track-click).
    // On touch / pen-first devices (hover: none) native scroll works
    // and the thumb would be an unusable artifact — skip it there
    // (touch & pointer design D7).
    var HOVER_DEVICE = window.matchMedia
      ? window.matchMedia("(hover: hover)").matches
      : true;

    function attachOverlayScrollbar(el) {
      if (!HOVER_DEVICE) return;
      if (el._overlaySb) return;
      var sb = document.createElement("div");
      sb.className = "overlay-scrollbar";
      var thumb = document.createElement("div");
      thumb.className = "overlay-scrollbar-thumb";
      sb.appendChild(thumb);
      // Append to the NON-scrolling .chat-area wrapper, not to the
      // scrolling .messages: absolute children of a scroll container
      // scroll away with the content, so the thumb would leave the
      // viewport whenever the user scrolls down. updateOverlayScrollbar
      // pins the track to the messages area (inline top/bottom/right).
      var host = el.parentElement && el.parentElement.classList.contains("chat-area")
        ? el.parentElement
        : el;
      host.appendChild(sb);
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

    // 4b. Canvas zoom: wheel on the EMPTY canvas background zooms the
    //     infinite canvas centered on the cursor; wheel inside a WINDOW
    //     (session or plan panel) is left native — .messages, the plan
    //     DAG canvas and the plan info window scroll normally instead
    //     of zooming (P37: "only non-window parts zoom").
    //     Non-passive listener so we can preventDefault() — without it,
    //     Ctrl+wheel (pinch) would trigger the webview's page zoom and
    //     plain wheel over the background could scroll the page.
    document.addEventListener("wheel", function (e) {
      var t = e.target;
      if (!t || typeof t.closest !== "function") return;
      if (!t.closest(".main-content")) return;  // overlays don't zoom
      if (t.closest(".session-panel")) return;  // windows scroll natively
      if (t.closest(".plan-panel")) return;     // plan DAG / info scroll natively
      if (t.closest(".messages")) return;       // let messages scroll natively
      if (e.defaultPrevented) return;
      e.preventDefault();
      app.ports.onCanvasWheel.send({
        deltaY: e.deltaY * (e.deltaMode === 1 ? 16 : 1), // normalize line-mode
        clientX: e.clientX,
        clientY: e.clientY,
      });
    }, { passive: false });
    }
  };
})();
