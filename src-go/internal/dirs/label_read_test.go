package dirs

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// G0 truth table (docs/session-identity.md): reading session.label.json must
// produce the SAME answer on both backends, so both run the shared fixture
// testdata/serialization/label_cases.json — the Rust side
// (src-tauri/src/dirs.rs, session_label_read_matches_shared_fixture) reads
// the same file the way spawn_cases.json is shared.
//
// Why a shared table rather than two suites: every divergence this feature
// can have lives in exactly the places each language would excuse on its own
// terms — bytes vs characters for the cap, null vs missing key, a UTF-8 BOM,
// trailing data, whether trimming rewrites the value. A per-language test
// asserts what that language's decoder happens to do; the fixture asserts what
// the user gets, which must not depend on which backend serves them.

type labelFixture struct {
	Cases []labelCase `json:"cases"`
}

type labelCase struct {
	Name string `json:"name"`
	// Input is the exact bytes of the file, or nil meaning "no file at all"
	// (the case for every session created before this feature).
	Input    *string `json:"input"`
	Expected string  `json:"expected"`
}

func loadLabelFixture(t *testing.T) labelFixture {
	t.Helper()
	path := filepath.Join("..", "..", "..", "testdata", "serialization", "label_cases.json")
	text, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fx labelFixture
	if err := json.Unmarshal(text, &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("label fixture has no cases")
	}
	return fx
}

func TestReadSessionLabelMatchesSharedFixture(t *testing.T) {
	fx := loadLabelFixture(t)
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			dir := t.TempDir()
			if c.Input != nil {
				if err := os.WriteFile(LabelFile(dir), []byte(*c.Input), 0o644); err != nil {
					t.Fatalf("write label: %v", err)
				}
			}
			if got := ReadSessionLabel(dir); got != c.Expected {
				t.Errorf("label = %q, want %q (input: %v)", got, c.Expected, c.Input)
			}
		})
	}
}

// The cap is the number the parity script compares across Rust / Go / Elm;
// this pins the Go side to what the design states (SD-G10) so a rename cannot
// silently change its meaning.
func TestMaxLabelCharsIsTheParityScalar(t *testing.T) {
	if MaxLabelChars != 120 {
		t.Errorf("MaxLabelChars = %d, want 120 (docs/session-identity.md SD-G10)", MaxLabelChars)
	}
}

// The file name is part of the contract with the client (which is the only
// writer): a rename here would orphan every label already on disk.
func TestLabelFileLocation(t *testing.T) {
	got, want := LabelFile(filepath.Join("/tmp", "sess-1")), filepath.Join("/tmp/sess-1", "session.label.json")
	if got != want {
		t.Errorf("LabelFile = %s, want %s", got, want)
	}
}
