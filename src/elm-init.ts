// ─── Elm App Initialization ──────────────────────────────────────────
//
// Loads the Elm runtime, subscribes to ports synchronously (before any
// await), then registers Tauri event listeners. This ordering is critical:
// Elm's init fires port messages immediately, so subscribers must be
// registered before returning control to the event loop.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getCurrentWindow } from "@tauri-apps/api/window";

// Load CSS — Vite processes these imports
import "./App.css";
import "./components/HomeScreen.css";

// Elm global (loaded via <script src="/elm.js"> in index.html)
declare const Elm: {
  Main: {
    init: (opts: { flags: unknown; node: HTMLElement }) => {
      ports: Record<string, { send: (v: unknown) => void; subscribe: (cb: (v: unknown) => void) => void }>;
    };
  };
};

function init() {
  const root = document.getElementById("root");
  if (!root) {
    console.error("No #root element");
    return;
  }

  // 1. Create Elm app (synchronous — init runs in same tick)
  const app = Elm.Main.init({ flags: null, node: root });

  // Helper: typed subscribe
  function on<T>(port: string, cb: (v: T) => void) {
    app.ports[port].subscribe((v: unknown) => cb(v as T));
  }

  // 2. Subscribe to all Elm ports SYNCHRONOUSLY (no await between)
  //    This ensures port messages from Elm's init() are not lost.

  on<{ toolConfirm?: string | null }>("createSession", ({ toolConfirm }) => {
    invoke("create_session", { binaryPath: "", configPath: "", toolConfirm: toolConfirm || null })
      .then((id) => app.ports.onSessionCreated.send(id));
  });

  on<{ sessionId: string }>("closeSession", ({ sessionId }) => {
    invoke("close_session", { sessionId });
  });

  on<{ sessionId: string; text: string; media: unknown[] }>("sendPrompt", ({ sessionId, text, media }) => {
    invoke("alayacore_send_prompt", { sessionId, text, media });
  });

  on<{ sessionId: string }>("cancelTask", ({ sessionId }) => {
    invoke("alayacore_cancel", { sessionId });
  });

  on<{ sessionId: string; modelId: number }>("setModel", ({ sessionId, modelId }) => {
    invoke("alayacore_model_set", { sessionId, modelId });
  });

  on<{ sessionId: string; id: string; allowed: boolean }>("confirmTool", ({ sessionId, id, allowed }) => {
    invoke("alayacore_confirm", { sessionId, id, allowed });
  });

  on<{ sessionId: string; command: string }>("sendCommand", ({ sessionId, command }) => {
    invoke("alayacore_send_message", { sessionId, text: command });
  });

  on<{ sourceSessionId: string; historyId: string }>("forkSession", ({ sourceSessionId, historyId }) => {
    invoke("fork_session", { sourceSessionId, historyId, binaryPath: "" })
      .then((id) => app.ports.onSessionCreated.send(id));
  });

  on<{ sessionId: string }>("resumeSession", ({ sessionId }) => {
    invoke("resume_session", { sessionId, binaryPath: "" });
  });

  on<object>("listSessionDirs", () => {
    invoke("list_session_dirs").then((dirs) => app.ports.onSessionDirs.send(dirs));
  });

  on<{ sessionId: string }>("deleteSessionDir", ({ sessionId }) => {
    invoke("delete_session_dir", { sessionId });
  });

  on<{ path: string }>("fsListDir", ({ path }) => {
    invoke("fs_list_dir", { path }).then((entries) => app.ports.onFsListDir.send(entries));
  });

  on<object>("fsHomeDir", () => {
    invoke("fs_home_dir").then((home) => app.ports.onFsHomeDir.send(home));
  });

  on<{ path: string }>("fsResolvePath", ({ path }) => {
    invoke("fs_resolve_path", { path }).then((resolved) => app.ports.onFsResolvePath.send(resolved));
  });

  on<{ path: string }>("fsReadFileDataUri", ({ path }) => {
    invoke("fs_read_file_data_uri", { path }).then((uri) => app.ports.onFsReadFileDataUri.send(uri));
  });

  on<{ url: string }>("openUrl", ({ url }) => { openUrl(url); });
  on<object>("minimizeWindow", () => { getCurrentWindow().minimize(); });
  on<object>("toggleMaximize", () => { getCurrentWindow().toggleMaximize(); });
  on<object>("closeWindow", () => { getCurrentWindow().close(); });
  on<object>("startDragging", () => { getCurrentWindow().startDragging(); });

  // Focus / Scroll
  on<object>("focusInput", () => {
    requestAnimationFrame(() => {
      const el = document.getElementById("msg-input") as HTMLTextAreaElement | null;
      el?.focus();
    });
  });
  on<object>("scrollToBottom", () => {
    window.scrollTo({ top: document.documentElement.scrollHeight, behavior: "auto" });
  });

  // Scroll position: send data TO Elm on every scroll
  const sendScroll = () => {
    app.ports.onScroll.send({
      scrollTop: window.scrollY,
      scrollHeight: document.documentElement.scrollHeight,
      clientHeight: window.innerHeight,
    });
  };
  sendScroll(); // initial position
  window.addEventListener("scroll", sendScroll, { passive: true });

  // 3. Register Tauri event listeners (async — ports already subscribed)
  Promise.all([
    listen("tlv-delta", (ev) => app.ports.onDelta.send(ev.payload)),
    listen("tlv-frame", (ev) => app.ports.onFrame.send(ev.payload)),
    listen("core-status", (ev) => app.ports.onStatus.send(ev.payload)),
  ]).catch((err) => console.error("Tauri listen failed:", err));
}

init();
