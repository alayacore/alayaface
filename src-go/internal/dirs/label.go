package dirs

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"
)

// Session label (G-series, docs/session-identity.md).
//
// <sessionDir>/session.label.json holds the session's user-visible name —
// the thing a window title and a Session Manager row show instead of a UUID
// prefix. The CLIENT owns the document (src-elm/src/Session/Labels.elm, G1):
// it is the only writer, going through fs_write_file_text the same way
// session.refs.json does. The backend's whole job here is to READ it for
// list_session_dirs, so that the manager can name sessions that are not open
// without the client issuing one read per session directory.
//
// Two consequences worth knowing before changing anything below:
//
//   - Do NOT write this file from the backend. The file lives in the
//     identity's ROOT directory, and a fork replaces the work copy rather
//     than the identity, which is what makes a name survive a fork with no
//     inheritance code. A second writer would need compare-and-swap to be
//     safe and would break that property.
//   - Reading is lenient and DROPS (SD-G9): a name that cannot be trusted is
//     no name, and the fallback chain (label → "Session <n>" → id prefix)
//     decides what the user sees. Never clamp, never repair, never trim the
//     value that gets returned — trimming here only decides *presence*.
//     Normalisation belongs to the writer alone; a reader that fixes up
//     values is a second writer with a different idea of the name.

// MaxLabelChars is the upper bound on a label, in CHARACTERS (runes), not
// bytes. Twins: MAX_LABEL_CHARS (Rust) and maxLabelChars
// (Session/Labels.elm, added in G1), compared by
// scripts/check-backend-parity.sh. The unit matters: a 120-hanzi label is
// 360 bytes, so a backend that counted bytes would drop names the other one
// keeps — and the user would see the same session named differently depending
// on which backend serves it.
const MaxLabelChars = 120

// LabelFile is the label document inside a session directory.
func LabelFile(sessionDir string) string {
	return filepath.Join(sessionDir, "session.label.json")
}

// ReadSessionLabel returns the session's label, or "" when there is none the
// UI may show. Every failure mode is a "" and not an error: list_session_dirs
// must keep listing the session (a session that cannot be named is still a
// session), and a corrupt file must not turn into a red banner.
//
// Only `label` is decoded. `v` is deliberately NOT checked (a document from a
// future client still reads, exactly like ui.conf's), and `auto` is not
// modelled at all — a field this build has never heard of must not make the
// name disappear, and must not make it fail to parse.
func ReadSessionLabel(sessionDir string) string {
	text, err := os.ReadFile(LabelFile(sessionDir))
	if err != nil {
		return ""
	}
	var doc struct {
		Label string `json:"label"`
	}
	if err := json.Unmarshal(text, &doc); err != nil {
		return ""
	}
	if strings.TrimSpace(doc.Label) == "" {
		return ""
	}
	if utf8.RuneCountInString(doc.Label) > MaxLabelChars {
		return ""
	}
	return doc.Label
}

// WriteSessionLabel stores the client's label document verbatim, atomically
// (tmp + rename). Atomicity is not a detail here: a torn write leaves a file
// that parses as nothing, and SD-G9 turns that into "no name" with no trace.
// The document is NOT re-modelled — the client owns the schema, exactly like
// ui.conf; the caller has already checked its shape.
func WriteSessionLabel(sessionDir string, text []byte) error {
	return WriteFileAtomic(LabelFile(sessionDir), text)
}

// RemoveSessionLabel clears a name. An empty label means "no name", not a
// tombstone, so the file goes away and every reader falls back by itself. A
// missing file is success: the writer is idempotent, because the client may
// commit the same blank twice.
func RemoveSessionLabel(sessionDir string) error {
	err := os.Remove(LabelFile(sessionDir))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}
