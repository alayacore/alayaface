// ─── Platform Abstraction Layer ──────────────────────────────────────
//
// Defines the interface between the UI and the desktop environment.
// Implementations: Tauri (desktop), web (no-op stubs), VS Code.
//
// This allows App.tsx to be portable without conditional imports.

export interface Platform {
  isMaximized(): Promise<boolean>;
  onResized(cb: () => void): Promise<() => void>;
  startDragging(): void;
  minimize(): void;
  toggleMaximize(): void;
  close(): void;
}
