// ─── TLV Protocol Core ───────────────────────────────────────────────
//
// Platform-agnostic protocol types and constants.
// No React or Tauri dependencies — usable in web, VS Code, or any TS env.

// ─── Tag Constants ───────────────────────────────────────────────────

export const TAG_USER_TEXT = "UT";
export const TAG_USER_IMAGE = "UI";
export const TAG_USER_VIDEO = "UV";
export const TAG_USER_AUDIO = "UA";
export const TAG_USER_DOC = "UD";
export const TAG_USER_END = "UE";

export const TAG_ASSISTANT_TEXT = "AT";
export const TAG_ASSISTANT_REASONING = "AR";
export const TAG_ASSISTANT_TOOL = "AF";
export const TAG_USER_TOOL_RESULT = "UF";
export const TAG_SYSTEM_MSG = "SM";

export const TAG_ASSISTANT_TEXT_DELTA = "At";
export const TAG_ASSISTANT_REASONING_DELTA = "Ar";
export const TAG_TOOL_ARG_DELTA = "Af";

export const USER_ECHO_TAGS = new Set(["UT", "UI", "UV", "UA", "UD"]);

export function isUserEchoTag(tag: string): boolean {
  return USER_ECHO_TAGS.has(tag);
}

// ─── Protocol Event Types ────────────────────────────────────────────

/** Emitted when a streaming delta frame (At, Ar) arrives. */
export interface DeltaEvent {
  session_id: string;
  history_id: string;
  content: string;
  tag: "At" | "Ar";
}

/** Emitted when any complete TLV frame arrives. */
export interface FrameEvent {
  session_id: string;
  tag: string;
  raw_value: string;
  history_id: string | null;
  content: string | null;
  json: Record<string, unknown> | null;
  user_content_type: string | null;
}

/** Emitted when session connection status changes. */
export interface StatusEvent {
  session_id: string;
  connected: boolean;
  message: string;
}

// ─── Delta Parsing ───────────────────────────────────────────────────

/** Parse \x00<id>\x00<content> from a raw frame value. */
export function parseDelta(value: string): { id: string; content: string } | null {
  if (value.length === 0 || value.charCodeAt(0) !== 0) return null;
  const null1 = value.indexOf("\0", 1);
  if (null1 === -1) return null;
  const id = value.slice(1, null1);
  if (!id) return null;
  return { id, content: value.slice(null1 + 1) };
}

/** Wrap content with NUL-delimited history ID prefix. */
export function wrapDelta(id: string, content: string): string {
  return `\x00${id}\x00${content}`;
}
