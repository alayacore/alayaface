// ─── useSessions Hook ────────────────────────────────────────────────
//
// Thin React hook that wires the platform-agnostic session core
// to the Tauri transport layer. For web/VS Code ports, swap the
// transport import.

import { useEffect, useRef, useReducer, useCallback } from "react";
import type { SessionState, StagedMedia } from "../core/session";
import { createSessionState } from "../core/session";
import { handleDeltaEvent, handleFrameEvent } from "../core/handlers";
import { TauriTransport } from "../transport/tauri";
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
  pendingUpdates: Map<string, Array<(s: SessionState) => SessionState>>;
}

function sessionReducer(state: SessionReducerState, action: SessionAction): SessionReducerState {
  switch (action.type) {
    case "UPDATE_SESSION": {
      const exists = state.sessions.some((s) => s.id === action.sessionId);
      if (!exists) {
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
  transport: Transport;
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

export function useSessions(): UseSessionsReturn {
  const [{ sessions, activeId }, dispatch] = useReducer(sessionReducer, {
    sessions: [],
    activeId: null,
    pendingUpdates: new Map(),
  });
  const [initializing, setInitializing] = useReducer((_: boolean) => false, true);
  const [initError, setInitError] = useReducer((_: string | null, err: string | null) => err, null);
  const transportRef = useRef<TauriTransport>(new TauriTransport());

  const activeSess = sessions.find((s) => s.id === activeId);

  // Connect transport and auto-create initial session
  useEffect(() => {
    let cancelled = false;
    let createdId: string | null = null;
    const transport = transportRef.current;

    // connect() is now synchronous — no more StrictMode race.
    // It registers React callbacks into the module-level subscriber sets.
    // Tauri event listeners were already registered at module import time.
    const unsubscribe = transport.connect({
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

    // Auto-create the initial session
    (async () => {
      try {
        const id = await transport.createSession();
        createdId = id;
        if (!cancelled) {
          dispatch({ type: "ADD_SESSION", session: createSessionState(id) });
        } else {
          try { await transport.closeSession(id); } catch { /* */ }
        }
      } catch (err) {
        if (!cancelled) {
          console.error("Failed to auto-create session:", err);
          setInitError(String(err));
        }
      } finally {
        if (!cancelled) setInitializing();
      }
    })();

    return () => {
      cancelled = true;
      unsubscribe(); // Just removes callbacks from subscriber sets
      if (createdId) {
        transport.closeSession(createdId).catch(() => {});
      }
    };
  }, []);

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
    transport: transportRef.current,
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
