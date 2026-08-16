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
    init: function (app, root, transport) {
      // Typed subscribe with safety check (mirrors transport.js's on()).
      function on(port, cb) {
        var p = app.ports[port];
        if (!p) { console.warn("[overlay] port not found:", port); return; }
        if (!p.subscribe) { console.warn("[overlay] port has no subscribe:", port); return; }
        p.subscribe(function (v) { cb(v); });
      }

    on("scrollToBottom", function (data) {
      // Elm 0.19 renders on the NEXT animation frame (Browser stepper),
      // but ports are delivered synchronously BEFORE that draw. Measuring
      // scrollHeight here would see the PREVIOUS content: scrollTop would
      // be set to the old bottom, the new message would render below the
      // fold, and (scrollTop unchanged) no scroll event would ever fire —
      // the page stays stuck until a LATER event re-runs this handler
      // with the now-updated DOM (e.g. a user echo only scrolls when the
      // next tool/reasoning frame arrives). Deferring to a rAF makes the
      // scroll run AFTER Elm's draw: Elm's draw rAF is registered first
      // within this task, so it fires first in the next frame.
      requestAnimationFrame(function () {
        var el = document.querySelector("#msg-input-" + data.sessionId);
        if (el) {
          var panel = el.closest(".session-panel") || el.closest(".chat-area");
          if (panel) {
            var container = panel.querySelector(".messages");
            if (container) { container.scrollTop = container.scrollHeight; }
          }
        }
      });
    });

    on("setCursorPos", function (data) {
      // The port command is delivered BEFORE Elm paints the new model,
      // so an immediate setSelectionRange is clobbered whenever the
      // textarea value changes in that same update (caret jumps to the
      // end). Apply immediately (legacy behavior) and re-apply when the
      // value settles to a new one (voice insert at the caret).
      setTimeout(function () {
        var el = document.getElementById(data.id);
        if (!el || !el.setSelectionRange) return;
        el.focus();
        // pos: null/undefined → move to the end of the value (legacy);
        // a number → place the caret exactly there (voice insert).
        var pos = (data.pos === undefined || data.pos === null)
          ? el.value.length
          : Math.max(0, Math.min(data.pos, el.value.length));
        el.setSelectionRange(pos, pos);
        var oldValue = el.value;
        var deadline = Date.now() + 400;
        (function reapply() {
          if (el.value !== oldValue) {
            // Elm re-rendered with the new value → caret was reset;
            // restore the requested position.
            el.setSelectionRange(pos, pos);
          } else if (Date.now() <= deadline) {
            setTimeout(reapply, 5);
          }
        })();
      }, 0);
    });

    // Voice input: read the textarea caret so Elm can insert the ASR
    // transcript exactly where the user's cursor currently is.
    on("getCursorPos", function (data) {
      var el = document.getElementById("msg-input-" + data.sessionId);
      var pos = 0;
      if (el && typeof el.selectionStart === "number") {
        pos = el.selectionStart;
      }
      app.ports.onCursorPos.send({ sessionId: data.sessionId, pos: pos });
    });

    // ─── Voice input recording (ASR + raw audio) ───────────────────
    // Web-API mic capture (getUserMedia → AudioContext → ScriptProcessor
    // → mono Float32 samples). Works identically in the browser (Go
    // backend host) and the Tauri webview. Two consumers share one
    // capture pipeline, distinguished by `kind`:
    //   - "asr": on stop the samples are encoded as 16-bit PCM WAV and
    //     sent to asr_transcribe on the backend (local and remote ASR
    //     are OpenAI-compatible endpoints — they only differ by URL).
    //   - "raw": on stop the WAV is sent straight to AlayaCore as a UA
    //     (user audio) frame — JS emits onRawAudioReady with the data
    //     URI and Elm stages + sends it as a user message.
    // Recording is per-session (one active recorder per session id) and
    // both kinds auto-stop after MAX_RECORD_MS (60s) — the bridge tells
    // Elm via onCaptureAutoStop so the button/input states reset, then
    // the same finish path runs as a manual stop.

    var MAX_RECORD_MS = 60000;
    var recorders = {}; // sessionId → { ctx, processor, source, samples, stream, kind, timer }
    // Set while getUserMedia is still pending: beginCapture returns
    // early for a session that is already starting, so a double-tap
    // while the mic is coming up cannot leak a second stream/context
    // (recorders[sid] is only set AFTER getUserMedia resolves).
    var starting = {};
    // Set when a stop arrives while getUserMedia is still pending: the
    // .then in beginCapture checks it and never starts recording.
    var stopCancelled = {};

    function recorderFail(sid, kind, message) {
      cleanupRecorder(sid);
      delete stopCancelled[sid];
      if (kind === "asr") {
        app.ports.onVoiceError.send({ sessionId: sid, message: message });
      } else {
        app.ports.onRawAudioError.send({ sessionId: sid, message: message });
      }
    }

    function cleanupRecorder(sid) {
      var rec = recorders[sid];
      if (rec) {
        if (rec.timer) { clearTimeout(rec.timer); }
        try {
          if (rec.processor) { rec.processor.disconnect(); }
          if (rec.source) { rec.source.disconnect(); }
        } catch (e) { /* ignore */ }
        try {
          if (rec.stream) {
            rec.stream.getTracks().forEach(function (t) { t.stop(); });
          }
        } catch (e) { /* ignore */ }
        try { if (rec.ctx && rec.ctx.close) { rec.ctx.close(); } } catch (e) { /* ignore */ }
        delete recorders[sid];
      }
    }

    // Encode mono Float32 samples (any rate) as 16-bit PCM WAV. The
    // sample rate is taken from the AudioContext actually created, so
    // the header is truthful even when the browser ignores the 16kHz
    // request (ASR endpoints resample internally).
    function wavFromSamples(samples, sampleRate) {
      var n = samples.length;
      var buf = new ArrayBuffer(44 + n * 2);
      var view = new DataView(buf);
      function writeString(offset, s) {
        for (var i = 0; i < s.length; i++) view.setUint8(offset + i, s.charCodeAt(i));
      }
      writeString(0, "RIFF");
      view.setUint32(4, 36 + n * 2, true);
      writeString(8, "WAVE");
      writeString(12, "fmt ");
      view.setUint32(16, 16, true);   // fmt chunk size
      view.setUint16(20, 1, true);    // PCM
      view.setUint16(22, 1, true);    // mono
      view.setUint32(24, sampleRate, true);
      view.setUint32(28, sampleRate * 2, true); // byte rate
      view.setUint16(32, 2, true);    // block align
      view.setUint16(34, 16, true);   // bits per sample
      writeString(36, "data");
      view.setUint32(40, n * 2, true);
      var o = 44;
      for (var i = 0; i < n; i++) {
        var s = Math.max(-1, Math.min(1, samples[i]));
        view.setInt16(o, s < 0 ? s * 0x8000 : s * 0x7FFF, true);
        o += 2;
      }
      return new Blob([buf], { type: "audio/wav" });
    }

    function blobToBase64(blob, cb) {
      var reader = new FileReader();
      reader.onloadend = function () {
        var dataUrl = reader.result || "";
        var idx = dataUrl.indexOf(",");
        cb(idx >= 0 ? dataUrl.slice(idx + 1) : "");
      };
      reader.readAsDataURL(blob);
    }

    function beginCapture(sid, kind) {
      if (recorders[sid] || starting[sid]) return; // already recording / mic coming up
      if (!window.isSecureContext) {
        // navigator.mediaDevices only exists on HTTPS or localhost. The
        // Go backend is often reached over a LAN IP (http://192.168.x.x)
        // — that page is NOT a secure context, so the mic is unavailable.
        console.warn("[capture] insecure context: " + window.location.href);
        recorderFail(sid, kind, "Microphone access requires a secure context — open the app via http://localhost:PORT or https:// (LAN IP pages cannot use the mic)");
        return;
      }
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        recorderFail(sid, kind, "Microphone access is not supported in this browser/webview");
        return;
      }
      starting[sid] = true;
      navigator.mediaDevices.getUserMedia({ audio: true })
        .then(function (stream) {
          delete starting[sid];
          if (stopCancelled[sid]) {
            // The user stopped before the mic came up; release the
            // stream and never start recording.
            delete stopCancelled[sid];
            try { stream.getTracks().forEach(function (t) { t.stop(); }); } catch (e) { /* ignore */ }
            return;
          }
          var Ctor = window.AudioContext || window.webkitAudioContext;
          var ctx = new Ctor({ sampleRate: 16000 }); // best effort; header uses the real rate
          // A context created outside a user gesture (port callback)
          // starts SUSPENDED in Chrome — onaudioprocess never fires and
          // no samples are collected. Resume it explicitly.
          if (ctx.state === "suspended") {
            ctx.resume().catch(function () { /* autoplay policy may reject; the error surfaces at stop */ });
          }
          var source = ctx.createMediaStreamSource(stream);
          // ScriptProcessor is deprecated but universally supported and
          // needs no separate worklet module (this app has no bundler).
          var processor = ctx.createScriptProcessor(4096, 1, 1);
          var samples = [];
          processor.onaudioprocess = function (e) {
            var data = e.inputBuffer.getChannelData(0);
            for (var i = 0; i < data.length; i++) samples.push(data[i]);
            // A ScriptProcessor's output buffer defaults to a pass-through
            // of its input — connected to ctx.destination, that would
            // monitor the live mic through the speakers (audible
            // self-monitoring, feedback risk). Zero it: the node stays
            // active (onaudioprocess keeps firing), only the audio is muted.
            e.outputBuffer.getChannelData(0).fill(0);
          };
          source.connect(processor);
          processor.connect(ctx.destination); // keep the graph running
          recorders[sid] = {
            ctx: ctx, processor: processor, source: source, samples: samples, stream: stream, kind: kind,
          };
          // 60s cap: auto-stop behaves exactly like a manual stop. Elm
          // must reset its recording state first (onCaptureAutoStop),
          // then the regular finish path reports the result.
          recorders[sid].timer = setTimeout(function () {
            app.ports.onCaptureAutoStop.send({ sessionId: sid, kind: kind });
            finishCapture(sid, kind);
          }, MAX_RECORD_MS);
        })
        .catch(function (err) {
          delete starting[sid];
          recorderFail(sid, kind, "Microphone error: " + ((err && err.message) ? err.message : err));
        });
    }

    function finishCapture(sid, kind) {
      var rec = recorders[sid];
      if (!rec) {
        // Stop before the mic finished coming up: mark the pending
        // start as cancelled (beginCapture's .then releases the stream).
        if (!stopCancelled[sid]) {
          stopCancelled[sid] = true;
          if (kind === "asr") {
            app.ports.onAsrResult.send({ sessionId: sid, ok: false, text: "", error: "Not recording" });
          } else {
            app.ports.onRawAudioError.send({ sessionId: sid, message: "Not recording" });
          }
        }
        return;
      }
      delete stopCancelled[sid];
      var samples = rec.samples || [];
      var sampleRate = rec.ctx && rec.ctx.sampleRate ? rec.ctx.sampleRate : 16000;
      console.log("[capture] stop sid=" + sid + " kind=" + kind + " samples=" + samples.length +
        " rate=" + sampleRate + " ctxState=" + (rec.ctx ? rec.ctx.state : "n/a"));
      cleanupRecorder(sid);
      var wav = wavFromSamples(samples, sampleRate);
      if (wav.size < 1000) {
        recorderFail(sid, kind, kind === "asr" ? "No speech detected" : "No audio detected");
        return;
      }
      blobToBase64(wav, function (b64) {
        if (kind === "raw") {
          // Raw audio input: hand the WAV data URI to Elm, which stages
          // it and sends it immediately as a UA frame (send_prompt).
          app.ports.onRawAudioReady.send({ sessionId: sid, uri: "data:audio/wav;base64," + b64 });
          return;
        }
        transport.invoke("asr_transcribe", { sessionId: sid, audioBase64: b64 }, 120000)
          .then(function (res) {
            app.ports.onAsrResult.send({
              sessionId: sid,
              ok: !!(res && res.ok),
              text: (res && res.text) || "",
              error: (res && res.error) || "",
            });
          })
          .catch(function (err) {
            app.ports.onAsrResult.send({
              sessionId: sid, ok: false, text: "",
              error: String((err && err.message) || err),
            });
          });
      });
    }

    on("voiceStart", function (data) { beginCapture(data.sessionId, "asr"); });
    on("voiceStop", function (data) { finishCapture(data.sessionId, "asr"); });
    on("rawAudioStart", function (data) { beginCapture(data.sessionId, "raw"); });
    on("rawAudioStop", function (data) { finishCapture(data.sessionId, "raw"); });

    on("scrollIntoView", function (id) {
      // Same stale-DOM deferral as scrollToBottom: the target element is
      // usually rendered by the SAME update that fired this port, so it
      // does not exist in the DOM yet — wait for Elm's rAF draw first.
      requestAnimationFrame(function () {
        var el = document.getElementById(id);
        if (el) { el.scrollIntoView({ block: "nearest" }); }
      });
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

    // Sticky message title rows: toggle .msg-header-pinned on every
    // expanded message header while its body box has scrolled underneath
    // it. The CSS background (opaque + hairline divider) only applies
    // while pinned — a transparent pinned row would show the body text
    // behind it, and an always-on background would look like a permanent
    // title bar instead of the standalone title row.
    function updateStickyHeaders() {
      document.querySelectorAll(".msg-header").forEach(function (h) {
        var msg = h.parentElement;
        var box = msg && msg.classList.contains("message") ? msg.querySelector(".msg-window") : null;
        var cr = box ? h.closest(".messages").getBoundingClientRect() : null;
        var hr = h.getBoundingClientRect();
        // Pinned iff the body box has actually slid UNDER the header
        // (box.top < header.bottom) WHILE the header itself is stuck at
        // the container top (|header.top - container.top| <= 1): a
        // message scrolled fully above the viewport also has box.top <
        // header.bottom, but its header is gone — not pinned. When the
        // message sits fully in view the box is exactly adjacent
        // (box.top == header.bottom) — that is NOT stuck either; the
        // 0.5px epsilon absorbs subpixel rounding. Collapsed messages
        // (no box) explicitly get the class REMOVED so a stale pin from
        // before the collapse cannot linger on the title row.
        var pinned = !!(box && cr &&
          box.getBoundingClientRect().top < hr.bottom - 0.5 &&
          hr.top >= cr.top - 1 && hr.top <= cr.top + 1);
        h.classList.toggle("msg-header-pinned", pinned);
      });
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
        el._sbResizeObs = new ResizeObserver(function () {
          updateOverlayScrollbar(el);
          updateStickyHeaders();
        });
        el._sbResizeObs.observe(el);
      }
      updateOverlayScrollbar(el);
    }

    sendScroll();
    updateStickyHeaders();
    // Listen for scroll on all present and future .messages containers
    function attachScroll() {
      document.querySelectorAll(".messages").forEach(function(el) {
        if (!el._scrollAttached) {
          el._scrollAttached = true;
          el.addEventListener("scroll", function() { sendScroll(el); updateStickyHeaders(); }, { passive: true });
        }
        attachOverlayScrollbar(el);
        updateOverlayScrollbar(el);
      });
    }
    attachScroll();
    // Check for new messages containers (e.g. new sessions) and keep
    // the overlay thumbs + sticky-header pins in sync as content is
    // added/removed (Elm replaces text nodes on every stream delta, so
    // this also re-pins headers while a body grows).
    var scrollObserver = new MutationObserver(function () {
      attachScroll();
      updateStickyHeaders();
      document.querySelectorAll(".messages").forEach(updateOverlayScrollbar);
    });
    scrollObserver.observe(root, { childList: true, subtree: true });

    // Collapse under a pinned sticky header: keep the SAME message at
    // the top. Before the click the header is stuck to the viewport top
    // (body scrolled under it); collapsing removes the body, the content
    // shrinks and the browser clamps scrollTop to the new maximum — the
    // view jumps to the conversation start and the collapsed row is
    // lost mid-conversation. After the (async, rAF) Elm re-render, scroll
    // the container so the collapsed row sits where the pinned header
    // was — flush with the container top. Expand needs no adjustment
    // (the box grows below the header; the top never moves).
    document.addEventListener("click", function (e) {
      var t = e.target;
      if (!t || typeof t.closest !== "function") return;
      var h = t.closest(".msg-header");
      if (!h) return;
      var msg = h.parentElement;
      if (!msg || !msg.classList.contains("message")) return;
      var wasExpanded = !!msg.querySelector(".msg-window");
      var wasPinned = h.classList.contains("msg-header-pinned");
      // Double rAF: the first frame may still run before Elm's draw
      // (our capture listener registered before Elm's onClick), so wait
      // one more frame to measure the settled collapsed layout.
      requestAnimationFrame(function () {
        requestAnimationFrame(function () {
          if (!wasExpanded || !wasPinned) return;
          var msg2 = h.parentElement;
          if (!msg2 || msg2.querySelector(".msg-window")) return; // not collapsed
          var container = msg2.closest(".messages");
          if (!container) return;
          container.scrollTop += h.getBoundingClientRect().top - container.getBoundingClientRect().top;
        });
      });
    }, true);

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
