package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"alayaface/src-go/internal/dirs"
)

// The write half of the G-series label contract. Rust's twin is
// src-tauri/src/commands/label.rs::tests — same fixture, same messages, same
// store-verbatim rule.

func TestLabelWriteTableMatchesSharedFixture(t *testing.T) {
	type writeCase struct {
		Name     string          `json:"name"`
		Document json.RawMessage `json:"document"`
		Expected string          `json:"expected"`
	}
	var fx struct {
		WriteCases []writeCase `json:"write_cases"`
	}
	path := filepath.Join("..", "..", "..", "..", "testdata", "serialization", "label_cases.json")
	text, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	if err := json.Unmarshal(text, &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if len(fx.WriteCases) == 0 {
		t.Fatal("write_cases is empty")
	}
	for _, c := range fx.WriteCases {
		t.Run(c.Name, func(t *testing.T) {
			got := labelRejectReason([]byte(c.Document))
			if got == "" {
				got = "ok"
			}
			if got != c.Expected {
				t.Errorf("verdict = %q, want %q (document: %s)", got, c.Expected, c.Document)
			}
		})
	}
}

// namedSessionDir creates a top-level session the way create_session would
// (a directory holding session.alaya), and returns its path.
func namedSessionDir(t *testing.T, id string) string {
	t.Helper()
	dir := filepath.Join(dirs.AlayafaceDir(), "sessions", id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "session.alaya"), []byte("[]"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func labelDoc(t *testing.T, label string) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"v": 1, "label": label, "auto": false})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestSyncSessionLabelStoresVerbatimAndRemovesOnBlank(t *testing.T) {
	isolatedHome(t, func() {
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		dir := namedSessionDir(t, "s-1")

		doc := labelDoc(t, "重构 parser")
		rr := call(t, SyncSessionLabel, map[string]any{"sessionId": "s-1", "document": doc})
		if !strings.Contains(rr.Body.String(), `"ok":true`) {
			t.Fatalf("store failed: %s", rr.Body.String())
		}
		onDisk, err := os.ReadFile(dirs.LabelFile(dir))
		if err != nil {
			t.Fatalf("label not written: %v", err)
		}
		if string(onDisk) != doc {
			t.Errorf("stored = %s, want verbatim %s", onDisk, doc)
		}
		// The listing must now show the name (the read half, G0).
		if got := dirs.ReadSessionLabel(dir); got != "重构 parser" {
			t.Errorf("ReadSessionLabel = %q, want %q", got, "重构 parser")
		}

		// Blank clears the name by removing the file — no tombstone.
		call(t, SyncSessionLabel, map[string]any{"sessionId": "s-1", "document": labelDoc(t, "   ")})
		if _, err := os.Stat(dirs.LabelFile(dir)); !os.IsNotExist(err) {
			t.Errorf("blank label must remove the file, stat said: %v", err)
		}

		// Removing twice is fine: the writer is idempotent, because the client
		// may commit the same blank twice.
		call(t, SyncSessionLabel, map[string]any{"sessionId": "s-1", "document": labelDoc(t, "")})
	})
}

func TestSyncSessionLabelRefuses(t *testing.T) {
	isolatedHome(t, func() {
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		namedSessionDir(t, "s-1")

		cases := []struct {
			name string
			id   string
			doc  string
			want string
		}{
			{"traversal-parent", "../escape", labelDoc(t, "x"), labelErrBadID},
			{"nested-id", "a/b", labelDoc(t, "x"), labelErrBadID},
			{"empty-id", "", labelDoc(t, "x"), labelErrBadID},
			{"unknown-session", "nope", labelDoc(t, "x"), labelErrNotTop},
			{"not-an-object", "s-1", "[1,2]", labelErrDocShape},
			{"missing-label-key", "s-1", `{"v":1}`, labelErrNoLabel},
			{"label-not-a-string", "s-1", `{"label":42}`, labelErrType},
			{"over-cap", "s-1", labelDoc(t, strings.Repeat("中", 121)), labelErrTooLong},
		}
		for _, c := range cases {
			t.Run(c.name, func(t *testing.T) {
				err := callErr(t, SyncSessionLabel, map[string]any{"sessionId": c.id, "document": c.doc})
				if err == nil || err.Error() != c.want {
					t.Errorf("error = %v, want %q", err, c.want)
				}
			})
		}

		// A refusal must not have touched the store.
		if _, err := os.Stat(filepath.Join(dirs.AlayafaceDir(), "escape")); !os.IsNotExist(err) {
			t.Error("a refused write created a directory outside the sessions root")
		}
	})
}
