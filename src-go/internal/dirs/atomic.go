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
	// os.CreateTemp makes it 0600; config files are 0644 (the mode they had
	// when written with os.WriteFile directly).
	if err := os.Chmod(name, 0o644); err != nil {
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	if err := os.Rename(name, path); err != nil {
		return fmt.Errorf("Cannot write %s: %w", filepath.Base(path), err)
	}
	return nil
}
