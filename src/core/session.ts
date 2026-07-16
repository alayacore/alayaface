// ─── Session Domain Types ────────────────────────────────────────────
//
// Pure data types representing session state, messages, tools, etc.
// No React or Tauri dependencies.

// ─── Media Types ─────────────────────────────────────────────────────

export interface MediaItem {
  media_type: "image" | "audio" | "video" | "document";
  uri: string;
  name?: string;
}

export interface StagedMedia extends MediaItem {
  id: string;
}

// ─── Message Types ───────────────────────────────────────────────────

export interface Message {
  id: string;
  role: "user" | "assistant" | "tool" | "system" | "reasoning";
  content: string;
  tool_id?: string;
  tool_name?: string;
  is_error?: boolean;
  history_id?: string;
  media?: MediaItem[];
}

export interface ToolCall {
  id: string;
  name: string;
  input?: Record<string, unknown>;
  output?: string;
  is_error?: boolean;
  started: boolean;
  input_received: boolean;
  /** Accumulated raw JSON delta from Af frames (replaces _delta hacks). */
  accumulatedDelta?: string;
}

export interface NotificationItem {
  id: string;
  type: "notify" | "error";
  text: string;
  timestamp: number;
}

export interface PendingUserPart {
  id: string;
  historyId: string;
  tag: string;
  content: string;
  media_type?: "image" | "audio" | "video" | "document";
}

// ─── Pending Confirm ─────────────────────────────────────────────────

/** Pending tool confirmation from alayacore (SM type "tool_confirm"). */
export interface PendingConfirm {
  id: string;
  toolName?: string;
  toolInput?: string;
}

// ─── Session State ───────────────────────────────────────────────────

export interface SessionState {
  id: string;
  connected: boolean;
  statusMsg: string;
  messages: Message[];
  staged: StagedMedia[];
  models: { id: number; name: string }[];
  activeModelId: number | null;
  activeModelName: string;
  taskRunning: boolean;
  taskCurrentStep: number;
  taskMaxSteps: number;
  contextTokens: number;
  contextLimit: number;
  historyContents: Map<string, string>;
  historyRoles: Map<string, "assistant" | "reasoning">;
  toolCalls: Map<string, ToolCall>;
  stderrLines: string[];
  notifications: NotificationItem[];
  input: string;
  pendingUserParts: PendingUserPart[];
  sendPending: boolean;
  processedEchoIds: Set<string>;
  messageVersion?: number;
  reasoningLevel?: number;
  activeTheme?: string;
  themes?: Array<{ name: string; theme?: Record<string, string> }>;
  videoFps?: number;
  videoRes?: number;
  /** Per-session collapsed message IDs (for tool/reasoning folding). */
  collapsedMsgIds: Set<string>;
  /** Pending tool confirmations queue (concurrent multi-tool support). */
  pendingConfirm: PendingConfirm[];
  /** Pending MCP auth confirmation (null if none). */
  pendingMcpAuth: PendingConfirm | null;
  /** MCP initialization status (null if idle, string otherwise). */
  mcpStatus: string | null;
}

// ─── Factory ─────────────────────────────────────────────────────────

export function createSessionState(id: string): SessionState {
  return {
    id,
    connected: true,
    statusMsg: "Connected",
    messages: [],
    staged: [],
    models: [],
    activeModelId: null,
    activeModelName: "",
    taskRunning: false,
    taskCurrentStep: 0,
    taskMaxSteps: 0,
    contextTokens: 0,
    contextLimit: 0,
    historyContents: new Map(),
    historyRoles: new Map(),
    toolCalls: new Map(),
    stderrLines: [],
    notifications: [],
    input: "",
    pendingUserParts: [],
    sendPending: false,
    processedEchoIds: new Set(),
    collapsedMsgIds: new Set(),
    pendingConfirm: [],
    pendingMcpAuth: null,
    mcpStatus: null,
  };
}

// ─── User Echo Helpers ───────────────────────────────────────────────

import { isUserEchoTag } from "./protocol";

export function echoTagToMediaType(tag: string): MediaItem["media_type"] | null {
  switch (tag) {
    case "UI": return "image";
    case "UV": return "video";
    case "UA": return "audio";
    case "UD": return "document";
    default: return null;
  }
}

export function echoTagToLabel(tag: string): string {
  switch (tag) {
    case "UT": return "text";
    case "UI": return "📎 Image";
    case "UV": return "🎬 Video";
    case "UA": return "🎵 Audio";
    case "UD": return "📄 Document";
    default: return tag;
  }
}

export { isUserEchoTag };
