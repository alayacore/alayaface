package handlers

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestWaitForFileWaitsForStability: a file still being written in
// chunks must not be treated as stable after one 50ms tick — waitForFile
// must return only after the size has been unchanged for ~300ms, i.e.
// AFTER the final chunk landed. The old one-tick logic returned right
// after seeing chunk1's size and fork_session proceeded with a partial
// session file.
func TestWaitForFileWaitsForStability(t *testing.T) {
	path := filepath.Join(t.TempDir(), "fork.out")
	final := "chunk1-chunk2"
	if err := os.WriteFile(path, []byte("chunk1"), 0o644); err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)
	go func() { done <- waitForFile(path) }()

	// The second chunk lands while waitForFile is mid-polling (within
	// the first 300ms window).
	time.Sleep(120 * time.Millisecond)
	if err := os.WriteFile(path, []byte(final), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := <-done; err != nil {
		t.Fatalf("waitForFile: %v", err)
	}
	fi, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() != int64(len(final)) {
		t.Fatalf("waitForFile returned with a partially-written file: size=%d, want %d", fi.Size(), len(final))
	}
}
