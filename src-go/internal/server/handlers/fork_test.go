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
// TestInheritedReasoningLevel pins the fork path's handling of a level read
// back from session.spawn.json. An explicit override is validated and
// REJECTED when out of range (same as create_session); an inherited value
// from a legacy or hand-edited spawn.json falls back to 1 rather than
// reaching alayacore as --reasoning-level=7.
func TestInheritedReasoningLevel(t *testing.T) {
	lvl := func(v int) *int { return &v }
	cases := []struct {
		name string
		in   *int
		want int
	}{
		{"absent (legacy session)", nil, 1},
		{"zero", lvl(0), 0},
		{"balanced", lvl(1), 1},
		{"max", lvl(2), 2},
		{"negative (corrupt file)", lvl(-1), 1},
		{"above range (corrupt file)", lvl(7), 1},
	}
	for _, tc := range cases {
		if got := inheritedReasoningLevel(tc.in); got != tc.want {
			t.Errorf("%s: inheritedReasoningLevel = %d, want %d", tc.name, got, tc.want)
		}
	}

	// The explicit override must fail loudly, not be re-centred.
	if _, err := NormalizeReasoningLevel(7); err == nil || err.Error() != "Reasoning level must be 0, 1 or 2" {
		t.Errorf("NormalizeReasoningLevel(7) = %v, want the range error", err)
	}
}

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
