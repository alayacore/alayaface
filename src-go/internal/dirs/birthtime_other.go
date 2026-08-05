//go:build !linux && !darwin

package dirs

import (
	"os"
	"time"
)

// FileBirthTime returns the file's creation (birth) time, falling back
// to modification time where birth time is unavailable. Mirrors Rust's
// std::fs::Metadata::created() used by list_session_dirs.
func FileBirthTime(fi os.FileInfo) time.Time {
	return fi.ModTime()
}
