// ─── Transport Layer Abstraction ─────────────────────────────────────
//
// Defines the interface between the session core and the platform layer.
// Implementations: Tauri (desktop), WebSocket (web), VS Code extension API.
//
// A transport is responsible for:
//   1. Connecting/disconnecting to the backend
//   2. Sending commands (user messages, model switches, etc.)
//   3. Receiving events (frame events, delta events, status changes)

import type { DeltaEvent, FrameEvent, StatusEvent } from "./protocol";
import type { MediaItem } from "./session";

/** Callbacks that the session core registers with the transport. */
export interface TransportCallbacks {
  onDelta: (ev: DeltaEvent) => void;
  onFrame: (ev: FrameEvent) => void;
  onStatus: (ev: StatusEvent) => void;
}

/** Abstract transport interface — implement for each platform. */
export interface Transport {
  /** Register callbacks for incoming events. Returns an unsubscribe
   *  function. Synchronous — no async registration race. */
  connect(cbs: TransportCallbacks): () => void;

  /** Initialize and connect. Returns the created session ID. */
  createSession(binaryPath?: string, configPath?: string): Promise<string>;

  /** Resume an existing session from disk. */
  resumeSession(sessionId: string, binaryPath?: string): Promise<string>;

  /** Close a session. */
  closeSession(sessionId: string): Promise<void>;

  /** Send a text+media prompt. */
  sendPrompt(sessionId: string, text: string, media: MediaItem[]): Promise<void>;

  /** Send a raw command (as UT+UE). */
  sendCommand(sessionId: string, command: string): Promise<void>;

  /** Send a model switch command. */
  setModel(sessionId: string, modelId: number): Promise<void>;

  /** Set reasoning level. */
  setReasoning(sessionId: string, level: number): Promise<void>;

  /** Set theme. */
  setTheme(sessionId: string, name: string): Promise<void>;

  /** Reload model config. */
  modelLoad(sessionId: string): Promise<void>;

  /** Sync model config. */
  modelSync(sessionId: string, config: string): Promise<void>;

  /** Set video config. */
  setVideoConfig(sessionId: string, fps: number, res: number): Promise<void>;

  /** Cancel current task. */
  cancel(sessionId: string): Promise<void>;

  /** Save session. */
  save(sessionId: string, filename?: string): Promise<void>;

  /** Fork session up to a history ID. */
  fork(sessionId: string, historyId: string, filename: string): Promise<void>;

  /** Fork into a new session. */
  forkSession(sourceSessionId: string, historyId: string, binaryPath?: string): Promise<string>;

  /** Reply to a tool confirmation. */
  confirmTool(sessionId: string, id: string, allowed: boolean): Promise<void>;

  /** Continue/retry last prompt. */
  continue_(sessionId: string): Promise<void>;

  /** Summarize conversation. */
  summarize(sessionId: string): Promise<void>;

  /** List active sessions. */
  listSessions(): Promise<string[]>;

  /** List session dirs on disk. */
  listSessionDirs(): Promise<Array<{ id: string; has_session_file: boolean; created_at: string }>>;

  /** Delete a session directory. */
  deleteSessionDir(sessionId: string): Promise<void>;

  /** Check if a session is connected. */
  isConnected(sessionId: string): Promise<boolean>;

  /** Get stderr log. */
  getStderrLog(sessionId: string): Promise<string[]>;

  /** List available models. */
  listModels(binaryPath?: string, configPath?: string): Promise<Record<string, unknown>[]>;

  // ─── File System (platform-specific) ──────────────────────────────

  /** List directory contents. */
  fsListDir(path: string): Promise<Array<{ name: string; isDir: boolean }>>;

  /** Get home directory path. */
  fsHomeDir(): Promise<string>;

  /** Resolve a path (~, ., ..) and return info. */
  fsResolvePath(path: string): Promise<{ resolved: string; exists: boolean; isDir: boolean }>;

  /** Read a file and return as data URI. */
  fsReadFileDataUri(path: string): Promise<string>;
}
