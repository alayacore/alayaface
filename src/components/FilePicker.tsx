// ─── FilePicker Component ────────────────────────────────────────────
//
// Custom file picker overlay with:
//   - Path input (autocomplete, directory navigation)
//   - File list with fuzzy filtering
//   - URL mode toggle
//   - Keyboard navigation (up/down/enter/esc)
//
// Architecture follows alayacore's AttachmentWindow pattern:
// the input field serves dual purpose as search filter AND path navigator.
// - /, ~ prefixes trigger directory navigation
// - Last /-separated segment is the filter, everything before is the directory
// - Trailing / shows all files in that directory
// - Plain text filters current directory entries via fuzzy match

import { useState, useEffect, useRef, useCallback } from "react";
import { fuzzyScore } from "../core/fuzzy";
import type { Transport } from "../core/transport";

type FileMode = "local" | "url";

interface DirEntry {
  name: string;
  isDir: boolean;
}

interface FilePickerProps {
  transport: Transport;
  onAddFile: (path: string) => void;
  onAddUrl: (url: string) => void;
  onClose: () => void;
}

function FilePicker({ transport, onAddFile, onAddUrl, onClose }: FilePickerProps) {
  const [mode, setMode] = useState<FileMode>("local");
  const [input, setInput] = useState("");
  const [entries, setEntries] = useState<DirEntry[]>([]);
  const [currentDir, setCurrentDir] = useState("");
  const [baseDir, setBaseDir] = useState("");
  const [selectedIdx, setSelectedIdx] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);

  // ─── Load dir helper ───────────────────────────────────────────────

  const loadDir = useCallback(async (dir: string) => {
    setLoading(true);
    setError(null);
    try {
      const result = await transport.fsListDir(dir);
      setEntries(result);
      setCurrentDir(dir);
      setSelectedIdx(0);
    } catch (err) {
      setError(String(err));
      setEntries([]);
    } finally {
      setLoading(false);
    }
  }, [transport]);

  // ─── Initialize from home dir ──────────────────────────────────────

  useEffect(() => {
    (async () => {
      try {
        const home = await transport.fsHomeDir();
        setBaseDir(home);
        await loadDir(home);
      } catch (err) {
        setError(String(err));
        setLoading(false);
      }
    })();
  }, [loadDir, transport]);

  // ─── Focus input on mount ──────────────────────────────────────────

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  // ─── Fuzzy filtered list ───────────────────────────────────────────

  const filtered = getFiltered(entries, input, currentDir, baseDir);

  // ─── Navigation: enter on directory ───────────────────────────────

  const navigateDir = useCallback(async (dirName: string) => {
    const newDir = currentDir + "/" + dirName;
    try {
      const resolved = await transport.fsResolvePath(newDir);
      if (resolved.isDir) {
        await loadDir(resolved.resolved);
        setInput("");
      }
    } catch { /* */ }
  }, [currentDir, loadDir, transport]);

  // ─── Add selected file ────────────────────────────────────────────

  const addSelected = useCallback((entry: DirEntry) => {
    const fullPath = currentDir + "/" + entry.name;
    onAddFile(fullPath);
    onClose();
  }, [currentDir, onAddFile, onClose]);

  // ─── Path-based navigation (/, ~  patterns) ──────────────────────

  const navigateByPath = useCallback(async (search: string) => {
    // Determine directory and filter from the input
    let absDir: string;
    let filter: string;

    if (search.startsWith("~")) {
      const home = await transport.fsHomeDir();
      if (search === "~") {
        await loadDir(home);
        return "";
      }
      const rest = search.slice(1);
      if (rest.endsWith("/")) {
        absDir = home + "/" + rest;
        filter = "";
      } else {
        const lastSlash = rest.lastIndexOf("/");
        if (lastSlash >= 0) {
          absDir = home + "/" + rest.slice(0, lastSlash);
          filter = rest.slice(lastSlash + 1);
        } else {
          absDir = home;
          filter = rest;
        }
      }
    } else if (search.startsWith("/")) {
      if (search.endsWith("/")) {
        absDir = search;
        filter = "";
      } else {
        const lastSlash = search.lastIndexOf("/");
        if (lastSlash >= 0) {
          absDir = search.slice(0, lastSlash);
          filter = search.slice(lastSlash + 1);
        } else {
          absDir = "/";
          filter = search.slice(1);
        }
      }
    } else if (search.includes("/") || search === "..") {
      const home = await transport.fsHomeDir();
      const currentBase = baseDir || home;
      if (search === "..") {
        absDir = currentBase + "/..";
        filter = "";
      } else if (search.endsWith("/")) {
        absDir = currentBase + "/" + search;
        filter = "";
      } else {
        const lastSlash = search.lastIndexOf("/");
        if (lastSlash >= 0) {
          absDir = currentBase + "/" + search.slice(0, lastSlash);
          filter = search.slice(lastSlash + 1);
        } else {
          return search; // normal filter
        }
      }
    } else {
      return search; // normal filter
    }

    // Resolve and navigate
    try {
      const resolved = await transport.fsResolvePath(absDir);
      if (resolved.exists && resolved.isDir) {
        await loadDir(resolved.resolved);
        return filter || "";
      }
    } catch { /* */ }
    return search;
  }, [baseDir, loadDir, transport]);

  // ─── Input change handler ──────────────────────────────────────────

  const handleInputChange = useCallback(async (value: string) => {
    setInput(value);

    if (mode === "url") return;

    // Try path navigation
    const filter = await navigateByPath(value);
    if (filter !== value) {
      // Path navigation succeeded, filter state already updated by loadDir
      return;
    }
  }, [mode, navigateByPath]);

  // ─── Keyboard handler ──────────────────────────────────────────────

  const handleKeyDown = useCallback(async (e: React.KeyboardEvent) => {
    if (e.key === "Escape") {
      onClose();
      return;
    }

    // Ctrl+A toggle mode
    if ((e.ctrlKey || e.metaKey) && e.key === "a") {
      e.preventDefault();
      setMode((m) => m === "local" ? "url" : "local");
      setInput("");
      return;
    }

    if (mode === "url") {
      if (e.key === "Enter") {
        e.preventDefault();
        const url = input.trim();
        if (url) {
          onAddUrl(url);
          onClose();
        }
      }
      return;
    }

    // Local mode navigation
    const list = filtered;
    switch (e.key) {
      case "ArrowDown":
      case "j":
        e.preventDefault();
        setSelectedIdx((i) => Math.min(i + 1, list.length - 1));
        break;
      case "ArrowUp":
      case "k":
        e.preventDefault();
        setSelectedIdx((i) => Math.max(i - 1, 0));
        break;
      case "Enter":
        e.preventDefault();
        if (list.length === 0) return;
        const entry = list[selectedIdx];
        if (entry.isDir) {
          await navigateDir(entry.name);
        } else {
          addSelected(entry);
        }
        break;
    }
  }, [filtered, mode, input, selectedIdx, onClose, onAddUrl, navigateDir, addSelected]);

  // ─── Scroll selected into view ─────────────────────────────────────

  useEffect(() => {
    const el = listRef.current?.children[selectedIdx] as HTMLElement | undefined;
    el?.scrollIntoView({ block: "nearest" });
  }, [selectedIdx]);

  // ─── Render ────────────────────────────────────────────────────────

  return (
    <div className="modal-overlay fp-overlay" onClick={onClose}>
      <div className="fp-dialog" onClick={(e) => e.stopPropagation()}>
        {/* Header */}
        <div className="fp-header">
          <span className="fp-title">Attach File</span>
          <button className="fp-close" onClick={onClose}>✕</button>
        </div>

        {/* Mode indicator */}
        <div className="fp-mode-bar">
          <span className={`fp-mode-tab ${mode === "local" ? "fp-mode-active" : ""}`}
                onClick={() => { setMode("local"); setInput(""); }}>
            📁 Local
          </span>
          <span className={`fp-mode-tab ${mode === "url" ? "fp-mode-active" : ""}`}
                onClick={() => { setMode("url"); setInput(""); }}>
            🔗 URL
          </span>
          <span className="fp-mode-hint">(Ctrl+A to switch)</span>
        </div>

        {/* Path/URL input */}
        <div className="fp-input-row">
          <span className="fp-input-prefix">{mode === "local" ? "📁" : "🔗"}</span>
          <input
            ref={inputRef}
            className="fp-input"
            type="text"
            value={input}
            onChange={(e) => handleInputChange(e.target.value)}
            onKeyDown={handleKeyDown}
            placeholder={mode === "local" ? "Search files…  (~, /, .. for navigation)" : "https://example.com/image.jpg"}
          />
        </div>

        {/* URL mode: hint */}
        {mode === "url" && (
          <div className="fp-url-hint">
            Enter a URL and press Enter to attach.
          </div>
        )}

        {/* Local mode: directory path + file list */}
        {mode === "local" && (
          <>
            <div className="fp-dir-path">{currentDir}</div>

            {loading ? (
              <div className="fp-loading">Loading…</div>
            ) : error ? (
              <div className="fp-error">⚠ {error}</div>
            ) : filtered.length === 0 ? (
              <div className="fp-empty">No files match</div>
            ) : (
              <div className="fp-list" ref={listRef}>
                {filtered.map((entry, i) => (
                  <div
                    key={entry.name}
                    className={`fp-item ${i === selectedIdx ? "fp-item-selected" : ""}`}
                    onClick={() => {
                      if (entry.isDir) {
                        navigateDir(entry.name);
                      } else {
                        addSelected(entry);
                      }
                    }}
                    onMouseEnter={() => setSelectedIdx(i)}
                  >
                    <span className="fp-item-icon">{entry.isDir ? "📁" : "📄"}</span>
                    <span className="fp-item-name">{entry.name}</span>
                    {entry.isDir && <span className="fp-item-dir-slash">/</span>}
                  </div>
                ))}
              </div>
            )}

            {/* Help bar */}
            <div className="fp-help">
              {mode === "local" && (
                <span>
                  Type to filter · j/k or ↑/↓: navigate · Enter: select · Esc: close
                </span>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// ─── Filter helper ────────────────────────────────────────────────────

function getFiltered(
  entries: DirEntry[],
  input: string,
  _currentDir: string,
  _baseDir: string,
): DirEntry[] {
  if (input === "" || input.startsWith("/") || input.startsWith("~") || input.includes("/") || input === "..") {
    return entries; // show all when in path navigation mode
  }

  const term = input.toLowerCase().trim();
  if (!term) return entries;

  // Score and sort by match quality
  const scored = entries
    .map((e) => ({
      entry: e,
      score: fuzzyScore(term, e.name.toLowerCase()),
    }))
    .filter((s) => s.score > 0);

  scored.sort((a, b) => b.score - a.score);
  return scored.map((s) => s.entry);
}

export default FilePicker;
