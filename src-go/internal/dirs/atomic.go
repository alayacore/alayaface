package dirs

import (
	"fmt"
	"os"
	"path/filepath"
)

// WriteFileAtomic persists text to path via a UNIQUE temporary file in the
// same directory, then a rename (so a reader never sees a half-written
// config, and a crash cannot leave the real file truncated).
//
// The temp name has to be unique per write. Every config writer used to
// build one itself — `path + ".tmp"`, `"settings.conf.tmp"`,
// `"mcp.conf.tmp"`, `"session.spawn.json.tmp"` — and this backend serves
// several clients at once (LAN / SSH-forwarded tabs). Two concurrent syncs
// of the same file wrote the SAME temp: the bytes interleaved and the first
// rename published a corrupt config while the loser failed with ENOENT. The
// Go backend is explicitly multi-client (that is why sessions carry an
// Owner and close_all_sessions is per-client), so "only one writer at a
// time" is not a safe assumption.
//
// Mirrors Rust's dirs::write_file_atomic.
func WriteFileAtomic(path string, text []byte) error {
	return WriteFileAtomicMode(path, text, 0o644)
}

// WriteFileAtomicMode is WriteFileAtomic with an explicit mode.
//
// A config file that holds a secret is 0600 in AlayaCore (`model.conf` can be
// the only copy of an API key — agent.writeConfigFile writes it 0600), and
// this backend must not widen that. Everything AlayaFace owns (ui.conf,
// settings.conf, mcp.conf, the preset order) keeps the 0644 default.
func WriteFileAtomicMode(path string, text []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	tmp, err := os.CreateTemp(dir, filepath.Base(path)+".tmp-")
	if err != nil {
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	name := tmp.Name()
	// Best-effort cleanup; a no-op once the rename moved the file away.
	defer os.Remove(name)

	if _, err := tmp.Write(text); err != nil {
		tmp.Close()
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	if err := tmp.Sync(); err != nil {
		tmp.Close()
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	if err := tmp.Close(); err != nil {
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	// os.CreateTemp makes it 0600; config files that AlayaFace owns are 0644.
	// Callers that write a core-owned file pass the core's mode (model.conf is
	// 0600 because it can hold an API key).
	if err := os.Chmod(name, mode); err != nil {
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	if err := os.Rename(name, path); err != nil {
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	return nil
}
