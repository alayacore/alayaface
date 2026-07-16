// ─── Tauri Transport Implementation ──────────────────────────────────
//
// Architecture: Tauri event listeners are registered once during
// explicit app startup (initTauriTransport), before React mounts.
// React components subscribe/unsubscribe via synchronous callback
// Sets — no async registration window, no StrictMode races.
//
// For web/VS Code ports: replace this module with a different
// Transport implementation. initTauriTransport() would become
// initWebTransport() etc.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Transport, TransportCallbacks } from "../core/transport";
import type { DeltaEvent, FrameEvent, StatusEvent } from "../core/protocol";
import type { MediaItem } from "../core/session";

// ─── Module-level subscriber registry ──────────────────────────────
// Tauri "listen" fires into global dispatchers, which fan out to
// per-component callbacks. No per-component listen/unlisten.

type CallbackFn = (payload: any) => void;
const subscribers: Map<string, Set<CallbackFn>> = new Map();

function dispatch(event: string, payload: any): void {
  const set = subscribers.get(event);
  if (!set || set.size === 0) return;
  // Snapshot to avoid issues if a callback removes itself during iteration
  for (const fn of [...set]) {
    try { fn(payload); } catch (e) { console.error("[transport] subscriber error:", e); }
  }
}

function subscribe(event: string, fn: CallbackFn): () => void {
  let set = subscribers.get(event);
  if (!set) {
    set = new Set();
    subscribers.set(event, set);
  }
  set.add(fn);
  return () => { set?.delete(fn); };
}

// ─── App startup: call once from main.tsx before React.render ─────

let initialized = false;

export async function initTauriTransport(): Promise<void> {
  if (initialized) return;
  initialized = true;

  await listen<DeltaEvent>("tlv-delta", (ev) => dispatch("delta", ev.payload));
  await listen<FrameEvent>("tlv-frame", (ev) => dispatch("frame", ev.payload));
  await listen<StatusEvent>("core-status", (ev) => dispatch("status", ev.payload));
}

// ─── Transport class (implementes core/transport.ts interface) ─────

export class TauriTransport implements Transport {
  /** Register component callbacks. Synchronous — always safe to call
   *  from useEffect. Returns unsubscribe function for cleanup. */
  connect(cbs: TransportCallbacks): () => void {
    const unsubs = [
      subscribe("delta", (p: DeltaEvent) => cbs.onDelta(p)),
      subscribe("frame", (p: FrameEvent) => cbs.onFrame(p)),
      subscribe("status", (p: StatusEvent) => cbs.onStatus(p)),
    ];
    return () => { for (const fn of unsubs) fn(); };
  }

  // ─── Session Lifecycle ─────────────────────────────────────────────

  async createSession(binaryPath?: string, configPath?: string): Promise<string> {
    return invoke("create_session", {
      binaryPath: binaryPath || "",
      configPath: configPath || "",
    });
  }

  async resumeSession(sessionId: string, binaryPath?: string): Promise<string> {
    return invoke("resume_session", {
      sessionId,
      binaryPath: binaryPath || "",
    });
  }

  async closeSession(sessionId: string): Promise<void> {
    return invoke("close_session", { sessionId });
  }

  // ─── I/O ───────────────────────────────────────────────────────────

  async sendPrompt(sessionId: string, text: string, media: MediaItem[]): Promise<void> {
    return invoke("alayacore_send_prompt", { sessionId, text, media });
  }

  async sendCommand(sessionId: string, command: string): Promise<void> {
    return invoke("alayacore_send_message", { sessionId, text: command });
  }

  async setModel(sessionId: string, modelId: number): Promise<void> {
    return invoke("alayacore_model_set", { sessionId, modelId });
  }

  async setReasoning(sessionId: string, level: number): Promise<void> {
    return invoke("alayacore_reason", { sessionId, level });
  }

  async setTheme(sessionId: string, name: string): Promise<void> {
    return invoke("alayacore_theme_set", { sessionId, name });
  }

  async modelLoad(sessionId: string): Promise<void> {
    return invoke("alayacore_model_load", { sessionId });
  }

  async modelSync(sessionId: string, config: string): Promise<void> {
    return invoke("alayacore_model_sync", { sessionId, config });
  }

  async setVideoConfig(sessionId: string, fps: number, res: number): Promise<void> {
    return invoke("alayacore_video_config", { sessionId, fps, res });
  }

  async cancel(sessionId: string): Promise<void> {
    return invoke("alayacore_cancel", { sessionId });
  }

  async save(sessionId: string, filename?: string): Promise<void> {
    return invoke("alayacore_save", { sessionId, filename: filename || "" });
  }

  async fork(sessionId: string, historyId: string, filename: string): Promise<void> {
    return invoke("alayacore_fork", { sessionId, historyId, filename });
  }

  async forkSession(sourceSessionId: string, historyId: string, binaryPath?: string): Promise<string> {
    return invoke("fork_session", {
      sourceSessionId,
      historyId,
      binaryPath: binaryPath || "",
    });
  }

  async confirmTool(sessionId: string, id: string, allowed: boolean): Promise<void> {
    return invoke("alayacore_confirm", { sessionId, id, allowed });
  }

  async continue_(sessionId: string): Promise<void> {
    return invoke("alayacore_continue", { sessionId });
  }

  async summarize(sessionId: string): Promise<void> {
    return invoke("alayacore_summarize", { sessionId });
  }

  // ─── Queries ───────────────────────────────────────────────────────

  async listSessions(): Promise<string[]> {
    return invoke("list_sessions");
  }

  async listSessionDirs(): Promise<Array<{ id: string; has_session_file: boolean; created_at: string }>> {
    return invoke("list_session_dirs");
  }

  async deleteSessionDir(sessionId: string): Promise<void> {
    return invoke("delete_session_dir", { sessionId });
  }

  async isConnected(sessionId: string): Promise<boolean> {
    return invoke("session_connected", { sessionId });
  }

  async getStderrLog(sessionId: string): Promise<string[]> {
    return invoke("get_stderr_log", { sessionId });
  }

  async listModels(binaryPath?: string, configPath?: string): Promise<Record<string, unknown>[]> {
    return invoke("list_models", {
      binaryPath: binaryPath || "",
      configPath: configPath || "",
    });
  }
}
