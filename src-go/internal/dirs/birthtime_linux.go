//go:build linux

package dirs

import (
	"os"
	"syscall"
	"time"
)

// FileBirthTime returns the file's creation (birth) time, falling back
// to modification time where birth time is unavailable. Mirrors Rust's
// std::fs::Metadata::created() used by list_session_dirs.
func FileBirthTime(fi os.FileInfo) time.Time {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return time.Unix(st.Ctim.Sec, st.Ctim.Nsec)
	}
	return fi.ModTime()
}
