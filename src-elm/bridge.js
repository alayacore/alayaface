// ─── Elm-Tauri Bridge ────────────────────────────────────────────────
//
// Connects Elm Ports to Tauri's invoke() and listen() APIs.
// This module is loaded after elm.js and wires up all communication.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import { getCurrentWindow } from "@tauri-apps/api/window";

export function initBridge(app) {
  // ─── Inbound: Tauri events → Elm subscriptions ──────────────────

  listen("tlv-delta", (ev) => {
    app.ports.onDelta.send(ev.payload);
  });

  listen("tlv-frame", (ev) => {
    app.ports.onFrame.send(ev.payload);
  });

  listen("core-status", (ev) => {
    app.ports.onStatus.send(ev.payload);
  });

  // ─── Outbound: Elm commands → Tauri invoke ──────────────────────

  app.ports.createSession.subscribe(({ toolConfirm }) => {
    invoke("create_session", {
      binaryPath: "",
      configPath: "",
      toolConfirm: toolConfirm || null,
    }).then((id) => app.ports.onSessionCreated.send(id));
  });

  app.ports.closeSession.subscribe(({ sessionId }) => {
    invoke("close_session", { sessionId }).then(() => {
      app.ports.onSessionClosed.send(sessionId);
    });
  });

  app.ports.sendPrompt.subscribe(({ sessionId, text, media }) => {
    invoke("alayacore_send_prompt", { sessionId, text, media });
  });

  app.ports.cancelTask.subscribe(({ sessionId }) => {
    invoke("alayacore_cancel", { sessionId });
  });

  app.ports.setModel.subscribe(({ sessionId, modelId }) => {
    invoke("alayacore_model_set", { sessionId, modelId });
  });

  app.ports.confirmTool.subscribe(({ sessionId, id, allowed }) => {
    invoke("alayacore_confirm", { sessionId, id, allowed });
  });

  app.ports.sendCommand.subscribe(({ sessionId, command }) => {
    invoke("alayacore_send_message", { sessionId, text: command });
  });

  app.ports.forkSession.subscribe(({ sourceSessionId, historyId }) => {
    invoke("fork_session", {
      sourceSessionId,
      historyId,
      binaryPath: "",
    }).then((id) => app.ports.onSessionCreated.send(id));
  });

  app.ports.resumeSession.subscribe(({ sessionId }) => {
    invoke("resume_session", { sessionId, binaryPath: "" });
  });

  app.ports.listSessionDirs.subscribe(() => {
    invoke("list_session_dirs").then((dirs) => {
      app.ports.onSessionDirs.send(dirs);
    });
  });

  app.ports.deleteSessionDir.subscribe(({ sessionId }) => {
    invoke("delete_session_dir", { sessionId });
  });

  app.ports.isSessionConnected.subscribe(({ sessionId }) => {
    invoke("session_connected", { sessionId });
  });

  app.ports.listModels.subscribe(() => {
    invoke("list_models", { binaryPath: "", configPath: "" });
  });

  // ─── File System ────────────────────────────────────────────────

  app.ports.fsListDir.subscribe(({ path }) => {
    invoke("fs_list_dir", { path }).then((entries) => {
      app.ports.onFsListDir.send(entries);
    });
  });

  app.ports.fsHomeDir.subscribe(() => {
    invoke("fs_home_dir").then((home) => {
      app.ports.onFsHomeDir.send(home);
    });
  });

  app.ports.fsResolvePath.subscribe(({ path }) => {
    invoke("fs_resolve_path", { path }).then((resolved) => {
      app.ports.onFsResolvePath.send(resolved);
    });
  });

  app.ports.fsReadFileDataUri.subscribe(({ path }) => {
    invoke("fs_read_file_data_uri", { path }).then((uri) => {
      app.ports.onFsReadFileDataUri.send(uri);
    });
  });

  // ─── Window Operations ──────────────────────────────────────────

  app.ports.openUrl.subscribe(({ url }) => {
    openUrl(url);
  });

  app.ports.minimizeWindow.subscribe(() => {
    getCurrentWindow().minimize();
  });

  app.ports.toggleMaximize.subscribe(() => {
    getCurrentWindow().toggleMaximize();
  });

  app.ports.closeWindow.subscribe(() => {
    getCurrentWindow().close();
  });

  app.ports.startDragging.subscribe(() => {
    getCurrentWindow().startDragging();
  });
}
