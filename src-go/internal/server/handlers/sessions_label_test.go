package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"alayaface/src-go/internal/dirs"
)

// G0 (docs/session-identity.md): list_session_dirs carries each session's
// label, so the Session Manager can name sessions that are NOT open without
// one fs read per session directory. Two halves, both user-visible: a named
// session is listed with its name, and a name that cannot be trusted (SD-G9)
// is listed as "" — the session still appears, because an unreadable name must
// never hide a session. Mirrors Rust's list_session_dirs_carries_label.

func TestListSessionDirsCarriesLabel(t *testing.T) {
	isolatedHome(t, func() {
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		sessions := filepath.Join(dirs.AlayafaceDir(), "sessions")
		// Chinese in a test string is the sanctioned exception: this is the
		// fixture proving a non-ASCII name survives the listing (AGENTS.md).
		cases := []struct {
			id   string
			body string // "" = write no label file at all
			want string
		}{
			{"named-sess", `{"v":1,"label":"重构 parser","auto":false}`, "重构 parser"},
			{"broken-sess", "not json", ""},
			{"plain-sess", "", ""},
		}
		for _, c := range cases {
			dir := filepath.Join(sessions, c.id)
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			// Without session.alaya the dir is not a top-level session at all
			// (plan node sessions live deeper), so it must stay out of the list.
			if err := os.WriteFile(filepath.Join(dir, "session.alaya"), []byte("[]"), 0o644); err != nil {
				t.Fatal(err)
			}
			if c.body != "" {
				if err := os.WriteFile(dirs.LabelFile(dir), []byte(c.body), 0o644); err != nil {
					t.Fatal(err)
				}
			}
		}

		rr := call(t, ListSessionDirs, map[string]any{})
		var list []struct {
			ID    string `json:"id"`
			Label string `json:"label"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
			t.Fatalf("decode reply: %v (%s)", err, rr.Body.String())
		}
		byID := map[string]string{}
		for _, item := range list {
			byID[item.ID] = item.Label
		}
		for _, c := range cases {
			got, ok := byID[c.id]
			if !ok {
				t.Errorf("%s missing from the listing (%s)", c.id, rr.Body.String())
				continue
			}
			if got != c.want {
				t.Errorf("%s label = %q, want %q", c.id, got, c.want)
			}
		}
		if len(list) != len(cases) {
			t.Errorf("listing has %d entries, want %d — an unreadable name must not hide a session: %s",
				len(list), len(cases), rr.Body.String())
		}
	})
}

// The reply key is spelled the way the client decodes it, in both backends.
// check-backend-parity.sh compares command NAMES, not payload keys, so this is
// the seam where Rust `label` and Go `label` could drift — and a drifted key
// reads as "no name" forever, silently, on one deployment only.
func TestSessionDirInfoLabelKey(t *testing.T) {
	b, err := json.Marshal(SessionDirInfo{ID: "s", CreatedAt: "0", Preset: "Default", Label: "x"})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"id":"s","created_at":"0","preset":"Default","label":"x"}`
	if string(b) != want {
		t.Errorf("reply shape =\n%s\nwant\n%s", b, want)
	}
}
