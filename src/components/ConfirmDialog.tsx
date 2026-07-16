// ─── ConfirmDialog Component ─────────────────────────────────────────
//
// Modal overlay for tool confirmations and MCP auth requests.
// Renders a centered dialog with tool name, input preview, and
// confirm/deny buttons.

import { useEffect, useRef } from "react";
import type { SessionState } from "../core/session";

interface ConfirmDialogProps {
  session: SessionState;
  kind: "tool" | "mcp_auth";
  onConfirm: (id: string) => void;
  onDeny: (id: string) => void;
  onCancelAll: (() => void) | null; // Ctrl+G equivalent for MCP
  onClose: () => void;
}

function ConfirmDialog({
  session,
  kind,
  onConfirm,
  onDeny,
  onCancelAll,
  onClose,
}: ConfirmDialogProps) {
  const pending = kind === "tool" ? session.pendingConfirm : session.pendingMcpAuth;
  const ref = useRef<HTMLDivElement>(null);

  // Focus trap + keyboard
  useEffect(() => {
    ref.current?.focus();
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        onClose();
        return;
      }
      if (kind === "mcp_auth" && e.key === "g" && (e.ctrlKey || e.metaKey)) {
        e.preventDefault();
        onCancelAll?.();
        return;
      }
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [kind, onClose, onCancelAll]);

  if (!pending) return null;

  const title =
    kind === "tool"
      ? `Allow "${pending.toolName || "Tool"}" to run?`
      : `Authorize MCP server "${pending.toolName}"?`;

  return (
    <div className="modal-overlay confirm-overlay" onClick={onClose}>
      <div
        className="confirm-dialog"
        ref={ref}
        tabIndex={-1}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="confirm-title">{title}</div>

        {pending.toolInput && (
          <div className="confirm-input">
            <pre>{pending.toolInput}</pre>
          </div>
        )}

        <div className="confirm-buttons">
          <button
            className="confirm-btn confirm-btn-allow"
            onClick={() => onConfirm(pending.id)}
          >
            {kind === "mcp_auth" ? "🔑 Authorize" : "✓ Allow"}
          </button>
          <button
            className="confirm-btn confirm-btn-deny"
            onClick={() => onDeny(pending.id)}
          >
            ✕ Deny
          </button>
          {onCancelAll && (
            <button
              className="confirm-btn confirm-btn-cancel-all"
              onClick={onCancelAll}
              title="Cancel all MCP initialization (Ctrl+G)"
            >
              ✕ Cancel All
            </button>
          )}
        </div>
        <div className="confirm-hint">
          {kind === "mcp_auth"
            ? "A browser window will open for OAuth authorization."
            : "Allows the agent to execute this tool."}
        </div>
      </div>
    </div>
  );
}

export default ConfirmDialog;
