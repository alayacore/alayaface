// ─── useSessions Hook ────────────────────────────────────────────────
//
// Thin React hook that wires the platform-agnostic session core
// to the provided Transport implementation. For web/VS Code ports,
// inject a different transport.

import { useEffect, useRef, useReducer, useCallback, useState } from "react";
import type { SessionState, StagedMedia } from "../core/session";
import { createSessionState } from "../core/session";
import { handleDeltaEvent, handleFrameEvent } from "../core/handlers";
import type { Transport } from "../core/transport";
import type { DeltaEvent, FrameEvent, StatusEvent } from "../core/protocol";

// ─── Reducer ─────────────────────────────────────────────────────────

export type SessionAction =
  | { type: "UPDATE_SESSION"; sessionId: string; updater: (s: SessionState) => SessionState }
  | { type: "REMOVE_SESSION"; sessionId: string }
  | { type: "ADD_SESSION"; session: SessionState }
  | { type: "SET_ACTIVE"; sessionId: string | null };

interface SessionReducerState {
  sessions: SessionState[];
  activeId: string | null;
  /** Buffer for events that arrive before ADD_SESSION resolves. */
  pendingUpdates: Map<string, Array<(s: SessionState) => SessionState>>;
}

function sessionReducer(state: SessionReducerState, action: SessionAction): SessionReducerState {
  switch (action.type) {
    case "UPDATE_SESSION": {
      const exists = state.sessions.some((s) => s.id === action.sessionId);
      if (!exists) {
        // Session not yet created — buffer the update
        const pending = new Map(state.pendingUpdates);
        const arr = pending.get(action.sessionId) || [];
        pending.set(action.sessionId, [...arr, action.updater]);
        return { ...state, pendingUpdates: pending };
      }
      return {
        ...state,
        sessions: state.sessions.map((s) =>
          s.id === action.sessionId ? action.updater(s) : s,
        ),
      };
    }
    case "REMOVE_SESSION": {
      const remaining = state.sessions.filter((s) => s.id !== action.sessionId);
      const pending = new Map(state.pendingUpdates);
      pending.delete(action.sessionId);
      return {
        ...state,
        sessions: remaining,
        pendingUpdates: pending,
        activeId:
          state.activeId === action.sessionId
            ? remaining.length > 0
              ? remaining[remaining.length - 1].id
              : null
            : state.activeId,
      };
    }
    case "ADD_SESSION": {
      // Flush any buffered updates onto the new session
      const pending = new Map(state.pendingUpdates);
      const updates = pending.get(action.session.id) || [];
      pending.delete(action.session.id);
      const session = updates.reduce((s, fn) => fn(s), action.session);
      return {
        ...state,
        sessions: [...state.sessions, session],
        pendingUpdates: pending,
        activeId: action.session.id,
      };
    }
    case "SET_ACTIVE":
      return { ...state, activeId: action.sessionId };
  }
  return state;
}

// ─── Hook ────────────────────────────────────────────────────────────

export interface UseSessionsReturn {
  sessions: SessionState[];
  activeId: string | null;
  activeSess: SessionState | undefined;
  dispatch: React.Dispatch<SessionAction>;
  initializing: boolean;
  initError: string | null;
  handleCreateSession: () => Promise<void>;
  handleCloseSession: (id: string) => Promise<void>;
  switchSession: (id: string) => void;
  setInput: (val: string) => void;
  confirmUrl: (url: string, type: string) => void;
  removeStaged: (id: string) => void;
}

export function useSessions(transport: Transport): UseSessionsReturn {
  const [{ sessions, activeId }, dispatch] = useReducer(sessionReducer, {
    sessions: [],
    activeId: null,
    pendingUpdates: new Map(),
  });
  const [initializing, setInitializing] = useState(true);
  const [initError, setInitError] = useState<string | null>(null);
  const transportRef = useRef(transport);

  const activeSess = sessions.find((s) => s.id === activeId);

  // Connect transport and auto-create initial session
  useEffect(() => {
    let cancelled = false;
    let createdId: string | null = null;
    const t = transportRef.current;

    // connect() is synchronous — no StrictMode race.
    // Registers React callbacks into module-level subscriber sets.
    const unsubscribe = t.connect({
      onDelta: (ev: DeltaEvent) => {
        dispatch({ type: "UPDATE_SESSION", sessionId: ev.session_id, updater: (s) => handleDeltaEvent(s, ev) });
      },
      onFrame: (ev: FrameEvent) => {
        dispatch({ type: "UPDATE_SESSION", sessionId: ev.session_id, updater: (s) => handleFrameEvent(s, ev) });
      },
      onStatus: (ev: StatusEvent) => {
        dispatch({
          type: "UPDATE_SESSION",
          sessionId: ev.session_id,
          updater: (s) => ({ ...s, connected: ev.connected, statusMsg: ev.message }),
        });
      },
    });

    // Auto-create initial session
    (async () => {
      try {
        const id = await t.createSession(undefined, undefined, "execute_command");
        createdId = id;
        if (!cancelled) {
          dispatch({ type: "ADD_SESSION", session: createSessionState(id) });
        } else {
          try { await t.closeSession(id); } catch { /* */ }
        }
      } catch (err) {
        if (!cancelled) {
          console.error("Failed to auto-create session:", err);
          setInitError(String(err));
        }
      } finally {
        if (!cancelled) setInitializing(false);
      }
    })();

    return () => {
      cancelled = true;
      unsubscribe(); // Removes callbacks from subscriber sets
      if (createdId) {
        t.closeSession(createdId).catch(() => {});
      }
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  // ─── Actions ───────────────────────────────────────────────────────

  const handleCreateSession = useCallback(async () => {
    try {
      const id = await transportRef.current.createSession();
      dispatch({ type: "ADD_SESSION", session: createSessionState(id) });
    } catch (err) {
      console.error("Failed to create session:", err);
      setInitError(String(err));
    }
  }, []);

  const handleCloseSession = useCallback(async (id: string) => {
    try {
      await transportRef.current.closeSession(id);
    } catch { /* ignore */ }
    dispatch({ type: "REMOVE_SESSION", sessionId: id });
  }, []);

  const switchSession = useCallback((id: string) => {
    dispatch({ type: "SET_ACTIVE", sessionId: id });
  }, []);

  const setInput = useCallback(
    (val: string) => {
      if (!activeId) return;
      dispatch({
        type: "UPDATE_SESSION",
        sessionId: activeId,
        updater: (s) => ({ ...s, input: val }),
      });
    },
    [activeId],
  );

  const confirmUrl = useCallback(
    (url: string, type: string) => {
      if (!activeId) return;
      const newItem: StagedMedia = {
        id: crypto.randomUUID(),
        media_type: type as StagedMedia["media_type"],
        uri: url,
        name: url,
      };
      dispatch({
        type: "UPDATE_SESSION",
        sessionId: activeId,
        updater: (s) => ({ ...s, staged: [...s.staged, newItem] }),
      });
    },
    [activeId],
  );

  const removeStaged = useCallback(
    (id: string) => {
      if (!activeId) return;
      dispatch({
        type: "UPDATE_SESSION",
        sessionId: activeId,
        updater: (s) => ({ ...s, staged: s.staged.filter((m) => m.id !== id) }),
      });
    },
    [activeId],
  );

  return {
    sessions,
    activeId,
    activeSess,
    dispatch,
    initializing,
    initError,
    handleCreateSession,
    handleCloseSession,
    switchSession,
    setInput,
    confirmUrl,
    removeStaged,
  };
}
