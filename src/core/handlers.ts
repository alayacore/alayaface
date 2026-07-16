// ─── Session Event Handlers ──────────────────────────────────────────
//
// Pure functions that process protocol events and produce state updates.
// No React or Tauri dependencies — usable in any TS environment.

import type { DeltaEvent, FrameEvent } from "./protocol";
import { isUserEchoTag } from "./protocol";
import type { SessionState, Message, MediaItem, PendingConfirm } from "./session";
import { echoTagToMediaType } from "./session";

// ─── Type for updater functions used by the reducer ────────────────

export type SessionUpdater = (s: SessionState) => SessionState;

// ─── Delta Event Handler (At/Ar) ────────────────────────────────────

export function handleDeltaEvent(s: SessionState, ev: DeltaEvent): SessionState {
  const { history_id, content, tag } = ev;
  if (tag !== "At" && tag !== "Ar") return s;
  const role = tag === "At" ? "assistant" as const : "reasoning" as const;

  const existing = s.historyContents.get(history_id);
  const newHistoryContents = new Map(s.historyContents);
  const newMsgs = [...s.messages];

  if (existing !== undefined) {
    const newContent = existing + content;
    newHistoryContents.set(history_id, newContent);
    const idx = newMsgs.findIndex((m) => m.history_id === history_id && m.role === role);
    if (idx >= 0) {
      newMsgs[idx] = { ...newMsgs[idx], content: newContent };
    }
  } else {
    newHistoryContents.set(history_id, content);
    newMsgs.push({ id: `hist-${history_id}-${Date.now()}`, role, content, history_id });
  }

  return { ...s, historyContents: newHistoryContents, messages: newMsgs, sendPending: false };
}

// ─── Frame Event Handler ────────────────────────────────────────────

export function handleFrameEvent(s: SessionState, ev: FrameEvent): SessionState {
  const { tag, json, history_id, content } = ev;

  // User echo frames (UT/UI/UV/UA/UD on stdout)
  if (isUserEchoTag(tag)) {
    return handleUserEchoFrame(s, tag, history_id, content);
  }

  // At/Ar are streaming deltas — handled via tlv-delta, NOT via tlv-frame.
  // (Rust reader intentionally skips tlv-frame emission for these tags.)
  // AT/AR — complete/authoritative frames
  if (tag === "AT" || tag === "AR") {
    return handleCompleteFrame(s, tag, history_id, content);
  }

  // SM system messages
  if (tag === "SM" && json) {
    return handleSystemMsg(s, json as { type?: string; data?: Record<string, unknown> });
  }

  // AF tool call lifecycle
  if (tag === "AF" && json) {
    return handleToolCallFrame(s, json, history_id);
  }

  // UF tool result
  if (tag === "UF" && json) {
    return handleToolResultFrame(s, json, history_id);
  }

  // Af tool argument delta
  if (tag === "Af" && json) {
    return handleToolDeltaFrame(s, json);
  }

  return s;
}

// ─── User Echo Frame Handler ────────────────────────────────────────

function handleUserEchoFrame(
  s: SessionState,
  tag: string,
  history_id: string | null,
  content: string | null,
): SessionState {
  const mediaType = echoTagToMediaType(tag);
  const textContent = tag === "UT" ? (content || "") : "";

  if (history_id && s.processedEchoIds.has(history_id)) return s;

  const newEchoIds = history_id
    ? new Set(s.processedEchoIds).add(history_id)
    : s.processedEchoIds;
  const lastMsg = s.messages.length > 0 ? s.messages[s.messages.length - 1] : null;
  const sameTurn = lastMsg?.role === "user";

  if (sameTurn) {
    return appendToLastUserMessage(s, tag, textContent, mediaType, content, history_id, newEchoIds);
  }

  const newMsg: Message = {
    id: `user-${history_id || Date.now()}`,
    role: "user",
    content: textContent,
    media: mediaType && content ? [{ media_type: mediaType, uri: content }] : undefined,
    history_id: history_id || undefined,
  };
  return {
    ...s,
    messages: [...s.messages, newMsg],
    processedEchoIds: newEchoIds,
    sendPending: false,
  };
}

function appendToLastUserMessage(
  s: SessionState,
  tag: string,
  textContent: string,
  mediaType: MediaItem["media_type"] | null,
  content: string | null,
  history_id: string | null,
  newEchoIds: Set<string>,
): SessionState {
  const newMsgs = [...s.messages];
  const last = newMsgs[newMsgs.length - 1];

  if (tag === "UT") {
    const sep = last.content ? "\n\n" : "";
    newMsgs[newMsgs.length - 1] = {
      ...last,
      content: last.content + sep + textContent,
      history_id: history_id || last.history_id,
    };
  } else if (mediaType && content) {
    const existingMedia = last.media || [];
    newMsgs[newMsgs.length - 1] = {
      ...last,
      media: [...existingMedia, { media_type: mediaType, uri: content }],
      history_id: history_id || last.history_id,
    };
  }

  return { ...s, messages: newMsgs, processedEchoIds: newEchoIds, sendPending: false };
}

// ─── Complete Frame Handler (AT/AR) ─────────────────────────────────

function handleCompleteFrame(
  s: SessionState,
  tag: string,
  history_id: string | null,
  content: string | null,
): SessionState {
  const role = tag === "AT" ? "assistant" as const : "reasoning" as const;

  if (!content || content.length === 0) {
    // Delta mode terminator — just mark sendPending false
    return { ...s, sendPending: false };
  }

  // Replay or --no-delta: content is the complete text
  const newHistoryContents = new Map(s.historyContents);
  const newMsgs = [...s.messages];

  if (history_id) {
    newHistoryContents.set(history_id, content);
    const idx = newMsgs.findIndex((m) => m.history_id === history_id && m.role === role);
    if (idx >= 0) {
      newMsgs[idx] = { ...newMsgs[idx], content };
    } else {
      newMsgs.push({ id: `hist-${history_id}-${Date.now()}`, role, content, history_id });
    }
  } else {
    newMsgs.push({ id: `msg-${Date.now()}`, role, content });
  }

  return { ...s, historyContents: newHistoryContents, messages: newMsgs, sendPending: false };
}

// ─── System Message Handler (SM) ────────────────────────────────────
//
// Dispatcher that routes to per-type handlers.

export function handleSystemMsg(
  s: SessionState,
  sm: { type?: string; data?: Record<string, unknown> },
): SessionState {
  const d = sm.data || {};
  switch (sm.type) {
    case "version":     return handleSystemMsgVersion(s, d);
    case "task":        return handleSystemMsgTask(s, d);
    case "error":       return handleSystemMsgError(s, d);
    case "notify":      return handleSystemMsgNotify(s, d);
    case "model_list":  return handleSystemMsgModelList(s, d);
    case "model":       return handleSystemMsgModel(s, d);
    case "theme":       return handleSystemMsgTheme(s, d);
    case "theme_list":  return handleSystemMsgThemeList(s, d);
    case "reasoning":   return handleSystemMsgReasoning(s, d);
    case "video_config":return handleSystemMsgVideoConfig(s, d);
    case "tool_confirm":return handleSystemMsgToolConfirm(s, d);
    case "mcp":         return handleSystemMsgMcp(s, d);
    default:            return s;
  }
}

function handleSystemMsgVersion(s: SessionState, d: Record<string, unknown>): SessionState {
  const vd = d as { message_version?: number };
  return { ...s, messageVersion: vd.message_version };
}

function handleSystemMsgTask(s: SessionState, d: Record<string, unknown>): SessionState {
  const tokens = (d.context ?? d.tokens ?? d.context_tokens ?? d.usage) as number | undefined;
  const done = !(d.in_progress as boolean);
  const step = d.current_step as number | undefined;
  const maxSteps = d.max_steps as number | undefined;
  const taskError = d.task_error as boolean | undefined;

  let statusMsg: string;
  if (taskError) {
    statusMsg = "Task failed";
  } else if (done) {
    statusMsg = "Task complete";
  } else if (step !== undefined && maxSteps !== undefined) {
    statusMsg = `Step ${step}/${maxSteps}…`;
  } else {
    statusMsg = "Task in progress…";
  }

  return {
    ...s,
    taskRunning: !done && !taskError,
    taskCurrentStep: step ?? s.taskCurrentStep,
    taskMaxSteps: maxSteps ?? s.taskMaxSteps,
    contextTokens: tokens ?? s.contextTokens,
    statusMsg,
    sendPending: done || taskError ? false : s.sendPending,
  };
}

function handleSystemMsgError(s: SessionState, d: Record<string, unknown>): SessionState {
  const ed = d as { text?: string };
  return {
    ...s,
    notifications: [
      ...s.notifications,
      { id: `err-${Date.now()}`, type: "error" as const, text: ed.text || "Unknown error", timestamp: Date.now() },
    ],
  };
}

function handleSystemMsgNotify(s: SessionState, d: Record<string, unknown>): SessionState {
  const nd = d as { text?: string };
  return {
    ...s,
    notifications: [
      ...s.notifications,
      { id: `notify-${Date.now()}`, type: "notify" as const, text: nd.text || "", timestamp: Date.now() },
    ],
  };
}

function handleSystemMsgModelList(s: SessionState, d: Record<string, unknown>): SessionState {
  const ml = d as { models?: { id?: number; name?: string }[] };
  if (!ml.models) return s;
  return {
    ...s,
    models: ml.models
      .filter((m) => m.id !== undefined && m.name)
      .map((m) => ({ id: m.id!, name: m.name! })),
  };
}

function handleSystemMsgModel(s: SessionState, d: Record<string, unknown>): SessionState {
  const tokens = (d.context_tokens ?? d.context ?? d.tokens) as number | undefined;
  return {
    ...s,
    activeModelId: (d.active_id as number) ?? s.activeModelId,
    activeModelName: (d.active_name as string) ?? s.activeModelName,
    contextLimit: (d.context_limit as number) ?? s.contextLimit,
    contextTokens: tokens ?? s.contextTokens,
  };
}

function handleSystemMsgTheme(s: SessionState, d: Record<string, unknown>): SessionState {
  const td = d as { name?: string };
  return { ...s, activeTheme: td.name || s.activeTheme };
}

function handleSystemMsgThemeList(s: SessionState, d: Record<string, unknown>): SessionState {
  const tld = d as { themes?: Array<{ name: string; theme?: Record<string, string> }> };
  if (tld.themes) return { ...s, themes: tld.themes };
  return s;
}

function handleSystemMsgReasoning(s: SessionState, d: Record<string, unknown>): SessionState {
  const rd = d as { level?: number };
  return { ...s, reasoningLevel: rd.level ?? s.reasoningLevel };
}

function handleSystemMsgVideoConfig(s: SessionState, d: Record<string, unknown>): SessionState {
  const vd = d as { fps?: number; res?: number };
  return { ...s, videoFps: vd.fps ?? s.videoFps, videoRes: vd.res ?? s.videoRes };
}

function handleSystemMsgToolConfirm(s: SessionState, d: Record<string, unknown>): SessionState {
  const cd = d as { id?: string };
  if (!cd.id) return s;
  // Find tool info from existing tool calls
  const tc = s.toolCalls.get(cd.id);
  const item: PendingConfirm = {
    id: cd.id,
    toolName: tc?.name,
    toolInput: tc?.input ? JSON.stringify(tc.input, null, 2) : undefined,
  };
  return {
    ...s,
    pendingConfirm: [...s.pendingConfirm, item],
  };
}

function handleSystemMsgMcp(s: SessionState, d: Record<string, unknown>): SessionState {
  const md = d as { status?: string; server?: string; url?: string; error?: string };

  // Auth confirm → set pendingMcpAuth for interactive dialog
  if (md.status === "auth_confirm" && md.server) {
    return {
      ...s,
      pendingMcpAuth: { id: md.server, toolName: md.server, toolInput: md.url },
      mcpStatus: "auth_confirm",
    };
  }

  // Init progress → update mcpStatus, show notification as before
  const { text, type: notifType } = formatMcpNotification(md);
  const result: SessionState = {
    ...s,
    mcpStatus: md.status || s.mcpStatus,
    notifications: [
      ...s.notifications,
      { id: `mcp-${Date.now()}`, type: notifType, text, timestamp: Date.now() },
    ],
  };

  // Clear pendingMcpAuth on done/failed
  if (md.status === "done" || md.status === "failed") {
    result.pendingMcpAuth = null;
    result.mcpStatus = md.status === "done" ? null : s.mcpStatus;
  }

  return result;
}

function formatMcpNotification(md: {
  status?: string;
  server?: string;
  url?: string;
  error?: string;
}): { text: string; type: "notify" | "error" } {
  const server = md.server ? ` ${md.server}` : "";

  switch (md.status) {
    case "connecting":
      return { text: `🔄 Connecting to MCP${server}…`, type: "notify" };
    case "auth_confirm":
      return {
        text: md.url
          ? `🔐 MCP${server} requires authentication: ${md.url}`
          : `🔐 MCP${server} requires authentication`,
        type: "notify",
      };
    case "auth_running":
      return { text: `🔑 MCP${server} authentication in progress…`, type: "notify" };
    case "connected":
      return { text: `✅ Connected to MCP${server}`, type: "notify" };
    case "failed":
      return { text: `❌ MCP${server} failed: ${md.error || "unknown error"}`, type: "error" };
    case "done":
      return { text: `✅ MCP initialization complete`, type: "notify" };
    default:
      return { text: `ℹ MCP${server}: ${md.status}`, type: "notify" };
  }
}

// ─── Tool Call Frame Handler (AF) ───────────────────────────────────

function handleToolCallFrame(
  s: SessionState,
  json: Record<string, unknown>,
  history_id: string | null,
): SessionState {
  const td = json as { id?: string; name?: string; input?: Record<string, unknown> };
  const toolId = td.id || "";
  const newToolCalls = new Map(s.toolCalls);
  const newMsgs = [...s.messages];

  if (td.name) {
    newToolCalls.set(toolId, { id: toolId, name: td.name, started: true, input_received: false });
    newMsgs.push({
      id: `tool-${toolId}`,
      role: "tool" as const,
      content: `🔧 **${td.name}**`,
      tool_id: toolId,
      tool_name: td.name,
      history_id: history_id || undefined,
    });
  }

  if (td.input) {
    const tc = newToolCalls.get(toolId);
    if (tc) {
      tc.input = td.input;
      tc.input_received = true;
    }
    const idx = newMsgs.findIndex((m) => m.tool_id === toolId);
    if (idx >= 0) {
      newMsgs[idx] = {
        ...newMsgs[idx],
        content: `🔧 **${newMsgs[idx].tool_name || "Tool"}**\n\`\`\`json\n${JSON.stringify(td.input, null, 2)}\n\`\`\``,
      };
    }
  }

  return { ...s, toolCalls: newToolCalls, messages: newMsgs };
}

// ─── Tool Result Frame Handler (UF) ─────────────────────────────────

function handleToolResultFrame(
  s: SessionState,
  json: Record<string, unknown>,
  history_id: string | null,
): SessionState {
  const rd = json as { id?: string; is_error?: boolean; output?: unknown };
  const toolId = rd.id || "";
  const isError = rd.is_error || false;
  let outStr = "";

  if (rd.output) {
    if (Array.isArray(rd.output)) {
      outStr = rd.output
        .map((i: Record<string, unknown>) => i.text || i.uri || JSON.stringify(i))
        .join("\n");
    } else {
      outStr = JSON.stringify(rd.output, null, 2);
    }
  }
  if (outStr.length > 500) outStr = outStr.slice(0, 500) + "\n… (truncated)";

  const tc = s.toolCalls.get(toolId);
  const toolName = tc?.name || "Tool";
  const newMsgs = [...s.messages];
  const idx = newMsgs.findIndex((m) => m.tool_id === toolId);

  if (idx >= 0) {
    const prefix = isError ? `❌ **${toolName}** (error)` : `✅ **${toolName}**`;

    // Use stored tc.input (parsed JSON from AF input frame) — clean, no _delta
    const hasCleanInput = tc?.input_received && tc?.input !== undefined;
    const inputStr = hasCleanInput
      ? JSON.stringify(tc!.input, null, 2)
      : "";

    const newContent = inputStr && inputStr !== "{}"
      ? `${prefix}\n\nInput:\n\`\`\`json\n${inputStr}\n\`\`\`\n\nOutput:\n\`\`\`\n${outStr}\n\`\`\``
      : `${prefix}\n\`\`\`\n${outStr}\n\`\`\``;

    newMsgs[idx] = {
      ...newMsgs[idx],
      content: newContent,
      is_error: isError,
      history_id: history_id || newMsgs[idx].history_id,
    };
  }

  return { ...s, messages: newMsgs };
}

// ─── Tool Delta Frame Handler (Af) ──────────────────────────────────

function handleToolDeltaFrame(
  s: SessionState,
  json: Record<string, unknown>,
): SessionState {
  const td = json as { id?: string; delta?: string };
  const toolId = td.id || "";
  const delta = td.delta || "";
  if (!toolId || !delta) return s;

  const newToolCalls = new Map(s.toolCalls);
  const tc = newToolCalls.get(toolId);
  if (!tc) return s;

  // Accumulate raw JSON delta string on dedicated field
  const accumulated = (tc.accumulatedDelta || "") + delta;
  tc.accumulatedDelta = accumulated;
  newToolCalls.set(toolId, tc);

  const newMsgs = [...s.messages];
  const idx = newMsgs.findIndex((m) => m.tool_id === toolId);
  if (idx >= 0) {
    newMsgs[idx] = {
      ...newMsgs[idx],
      content: `🔧 **${tc.name || "Tool"}**\n\`\`\`json\n${accumulated}\n\`\`\``,
    };
  }

  return { ...s, toolCalls: newToolCalls, messages: newMsgs };
}
