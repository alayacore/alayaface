package handlers

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestFsReadFileSizes: oversized files must be rejected before being
// read into memory (sparse files via Truncate — no multi-MB writes).
func TestFsReadFileSizes(t *testing.T) {
	dir := t.TempDir()

	// Small files read fine.
	small := filepath.Join(dir, "small.txt")
	if err := os.WriteFile(small, []byte("hello"), 0o644); err != nil {
		t.Fatal(err)
	}
	rr := call(t, FsReadFileText, map[string]any{"path": small})
	if got := strings.TrimSpace(rr.Body.String()); got != `"hello"` {
		t.Fatalf("fs_read_file_text(small) = %s", rr.Body.String())
	}

	// Data URI over 64 MiB → clean error.
	bigURI := filepath.Join(dir, "big.bin")
	f, err := os.Create(bigURI)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(maxDataUriFileSize + 1); err != nil {
		t.Fatal(err)
	}
	_ = f.Close()
	err = callErr(t, FsReadFileDataUri, map[string]any{"path": bigURI})
	if err == nil || !strings.Contains(err.Error(), "file too large") {
		t.Fatalf("fs_read_file_data_uri(oversized) = %v, want 'file too large'", err)
	}

	// Text file over 16 MiB → clean error.
	bigText := filepath.Join(dir, "big.txt")
	f2, err := os.Create(bigText)
	if err != nil {
		t.Fatal(err)
	}
	if err := f2.Truncate(maxTextFileSize + 1); err != nil {
		t.Fatal(err)
	}
	_ = f2.Close()
	err = callErr(t, FsReadFileText, map[string]any{"path": bigText})
	if err == nil || !strings.Contains(err.Error(), "file too large") {
		t.Fatalf("fs_read_file_text(oversized) = %v, want 'file too large'", err)
	}
}
