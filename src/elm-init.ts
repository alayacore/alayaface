// ─── Elm App Initialization ──────────────────────────────────────────
//
// Replaces React main.tsx. Loads the compiled Elm runtime and connects
// it to Tauri's invoke/listen APIs via the bridge.
//
// For web/VS Code ports: replace bridge import with platform-specific
// connection layer.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getCurrentWindow } from "@tauri-apps/api/window";

// Elm is loaded as a global via <script src="/elm.js">
declare const Elm: {
  Main: {
    init: (opts: { flags: unknown; node: HTMLElement }) => {
      ports: Record<string, { send: (v: unknown) => void; subscribe: (cb: (v: unknown) => void) => void }>;
    };
  };
};

async function init() {
  const root = document.getElementById("root");
  if (!root) throw new Error("No #root element");

  // Initialize Elm app
  const app = Elm.Main.init({ flags: null, node: root });

  // Initialize Tauri event listeners
  await listen("tlv-delta", (ev) => app.ports.onDelta.send(ev.payload));
  await listen("tlv-frame", (ev) => app.ports.onFrame.send(ev.payload));
  await listen("core-status", (ev) => app.ports.onStatus.send(ev.payload));

  // Helper: typed subscribe
  function on<T>(port: string, cb: (v: T) => void) {
    app.ports[port].subscribe((v: unknown) => cb(v as T));
  }

  // ─── Outbound: Elm commands → Tauri invoke ──────────────────────

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

  // ─── File System ────────────────────────────────────────────────

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

  // ─── Window Operations ──────────────────────────────────────────

  on<{ url: string }>("openUrl", ({ url }) => { openUrl(url); });
  on<object>("minimizeWindow", () => { getCurrentWindow().minimize(); });
  on<object>("toggleMaximize", () => { getCurrentWindow().toggleMaximize(); });
  on<object>("closeWindow", () => { getCurrentWindow().close(); });
  on<object>("startDragging", () => { getCurrentWindow().startDragging(); });
}

// Error boundary — render error state if init fails
init().catch((err) => {
  console.error("Failed to initialize Elm app:", err);
  const root = document.getElementById("root");
  if (root) {
    root.innerHTML = `
      <div style="display:flex;flex-direction:column;align-items:center;justify-content:center;height:100vh;background:#0f0f1a;color:#ef4444;font-family:sans-serif;">
        <h2>⚠ Failed to start</h2>
        <pre style="color:#aaa;font-size:14px;">${String(err)}</pre>
      </div>
    `;
  }
});
