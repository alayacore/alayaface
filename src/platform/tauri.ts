// ─── Tauri Platform Implementation ──────────────────────────────────
//
// Bridges desktop window operations via Tauri's window API.

import { getCurrentWindow } from "@tauri-apps/api/window";
import type { Platform } from "../core/platform";

export const tauriPlatform: Platform = {
  async isMaximized(): Promise<boolean> {
    return getCurrentWindow().isMaximized();
  },

  async onResized(cb: () => void): Promise<() => void> {
    return getCurrentWindow().onResized(cb);
  },

  startDragging(): void {
    getCurrentWindow().startDragging();
  },

  minimize(): void {
    getCurrentWindow().minimize();
  },

  toggleMaximize(): void {
    getCurrentWindow().toggleMaximize();
  },

  close(): void {
    getCurrentWindow().close();
  },
};
