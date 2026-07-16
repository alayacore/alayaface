import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { initTauriTransport } from "./transport/tauri";

// Initialize Tauri event listeners before React mounts.
// This happens once, before any effects run, so StrictMode
// double-mount doesn't cause duplicate listeners.
initTauriTransport()
  .then(() => {
    ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
      <React.StrictMode>
        <App />
      </React.StrictMode>,
    );
  })
  .catch((err) => {
    console.error("Failed to init Tauri transport:", err);
    // Still render so the user sees an error state
    ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
      <React.StrictMode>
        <App />
      </React.StrictMode>,
    );
  });
