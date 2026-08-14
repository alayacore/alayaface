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
      var el = document.querySelector("#msg-input-" + data.sessionId);
      if (el) {
        var panel = el.closest(".session-panel") || el.closest(".chat-area");
        if (panel) {
          var container = panel.querySelector(".messages");
          if (container) { container.scrollTop = container.scrollHeight; }
        }
      }
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

    // ─── Voice input recording ─────────────────────────────────────
    // Web-API mic capture (getUserMedia → AudioContext → ScriptProcessor
    // → mono Float32 samples). Works identically in the browser (Go
    // backend host) and the Tauri webview; on stop the samples are
    // encoded as 16-bit PCM WAV and sent to asr_transcribe on the
    // backend (local and remote ASR are OpenAI-compatible endpoints —
    // they only differ by URL). Transcription is per-session (one active
    // recorder per session id); Elm keeps voiceActive/asrBusy state and
    // serializes the toggle.

    var voiceRecorders = {}; // sessionId → { ctx, processor, source, samples, stream }
    // Set when voiceStop arrives while getUserMedia is still pending:
    // the .then in voiceStart checks it and never starts recording.
    var voiceCancelled = {};

    function voiceFail(sid, message) {
      cleanupVoice(sid);
      delete voiceCancelled[sid];
      app.ports.onVoiceError.send({ sessionId: sid, message: message });
    }

    function cleanupVoice(sid) {
      var rec = voiceRecorders[sid];
      if (rec) {
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
        delete voiceRecorders[sid];
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

    on("voiceStart", function (data) {
      var sid = data.sessionId;
      if (voiceRecorders[sid]) return; // already recording this session
      if (!window.isSecureContext) {
        // navigator.mediaDevices only exists on HTTPS or localhost. The
        // Go backend is often reached over a LAN IP (http://192.168.x.x)
        // — that page is NOT a secure context, so the mic is unavailable.
        console.warn("[voice] insecure context: " + window.location.href);
        voiceFail(sid, "Microphone access requires a secure context — open the app via http://localhost:PORT or https:// (LAN IP pages cannot use the mic)");
        return;
      }
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        voiceFail(sid, "Microphone access is not supported in this browser/webview");
        return;
      }
      navigator.mediaDevices.getUserMedia({ audio: true })
        .then(function (stream) {
          if (voiceCancelled[sid]) {
            // The user clicked stop before the mic came up; release
            // the stream and never start recording.
            delete voiceCancelled[sid];
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
          };
          source.connect(processor);
          processor.connect(ctx.destination); // keep the graph running
          voiceRecorders[sid] = {
            ctx: ctx, processor: processor, source: source, samples: samples, stream: stream,
          };
        })
        .catch(function (err) {
          voiceFail(sid, "Microphone error: " + ((err && err.message) ? err.message : err));
        });
    });

    on("voiceStop", function (data) {
      var sid = data.sessionId;
      var rec = voiceRecorders[sid];
      if (!rec) {
        // Stop before the mic finished coming up: mark the pending
        // start as cancelled (voiceStart's .then releases the stream).
        if (!voiceCancelled[sid]) {
          voiceCancelled[sid] = true;
          app.ports.onAsrResult.send({ sessionId: sid, ok: false, text: "", error: "Not recording" });
        }
        return;
      }
      delete voiceCancelled[sid];
      var samples = rec.samples || [];
      var sampleRate = rec.ctx && rec.ctx.sampleRate ? rec.ctx.sampleRate : 16000;
      console.log("[voice] stop sid=" + sid + " samples=" + samples.length +
        " rate=" + sampleRate + " ctxState=" + (rec.ctx ? rec.ctx.state : "n/a"));
      cleanupVoice(sid);
      var wav = wavFromSamples(samples, sampleRate);
      if (wav.size < 1000) {
        app.ports.onAsrResult.send({ sessionId: sid, ok: false, text: "", error: "No speech detected" });
        return;
      }
      blobToBase64(wav, function (b64) {
        transport.invoke("asr_transcribe", { sessionId: sid, audioBase64: b64 })
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
