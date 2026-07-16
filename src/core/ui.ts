// ─── UI-specific state helpers ───────────────────────────────────────
//
// These operate on UI state fields within SessionState.
// Separated from protocol handlers to keep concerns clean.

import type { SessionState } from "./session";

/** Toggle a message's collapsed state in the per-session set. */
export function toggleCollapsedMsg(s: SessionState, msgId: string): SessionState {
  const next = new Set(s.collapsedMsgIds);
  if (next.has(msgId)) {
    next.delete(msgId);
  } else {
    next.add(msgId);
  }
  return { ...s, collapsedMsgIds: next };
}

/** Set a set of message IDs as collapsed (idempotent). */
export function setCollapsedMsgs(s: SessionState, ids: Set<string>): SessionState {
  const next = new Set(s.collapsedMsgIds);
  let changed = false;
  for (const id of ids) {
    if (!next.has(id)) {
      next.add(id);
      changed = true;
    }
  }
  return changed ? { ...s, collapsedMsgIds: next } : s;
}
