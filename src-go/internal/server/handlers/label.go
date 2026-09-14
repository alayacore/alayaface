package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf8"

	"alayaface/src-go/internal/dirs"
)

// Session label (G-series, docs/session-identity.md): the user-visible name of
// a session, stored as <sessionDir>/session.label.json.
//
// # The backend stores a document it does not model
//
// Same rule as ui.conf: the CLIENT owns the schema (`Session/Labels.elm`), so
// nothing here decodes the label into a struct and writes the struct back —
// that is the AGENTS.md trap where an unmodelled field is silently deleted on
// the next save. What IS policed is the structure that protects the file: the
// id must be one path component, the target must be a real top-level session,
// and `label` must be a string within `dirs.MaxLabelChars`.
//
// # Why a command of its own (SD-G16)
//
// The write could have ridden fs_write_file_text, and the design doc said it
// would. That port's reply is `{ok, error}` and nothing else — no path, no
// reqId — so a second writer's failure would be attributed to the first
// (today: a failed rename would clear the ACTIVE PLAN WINDOW's `saving` flag
// and file the error under the plan's error list). A name a user cannot see
// the failure of is a name that silently never saved, so this command answers
// with its own result.

// The two refusal messages the client shows verbatim. Twins in
// src-tauri/src/commands/label.rs, asserted by
// scripts/check-backend-parity.sh's error-string section and by the shared
// fixture's write_cases — a divergent string is invisible to a command-name
// check and user-visible on exactly one deployment.
const (
	labelErrBadID    = "Session id is not a single path component"
	labelErrNotTop   = "Not a top-level session"
	labelErrDocShape = "Session label document must be a JSON object"
	labelErrNoLabel  = "Session label document has no 'label'"
	labelErrType     = "Session label 'label' must be a string"
	labelErrTooLong  = "Session label is over the character limit"
)

// sessionLabelDir resolves the identity's ROOT directory — the label belongs to
// the session identity, not to whichever work copy is current (SD-G1), which
// is why a fork keeps its name with no inheritance code.
func sessionLabelDir(sessionID string) string {
	return filepath.Join(dirs.AlayafaceDir(), "sessions", sessionID)
}

// labelRejectReason refuses a document that could not be read back as a name,
// "" when it may be stored. It takes the RAW payload the client sent — the same
// bytes that will be stored — so the shape question it answers is asked exactly
// once, on the value that is actually written. `label` is the only key
// inspected; `v` and `auto` are the client's business (SD-G5) and an unmodelled
// key must never make a name fail to save.
//
// The shared fixture testdata/serialization/label_cases.json runs the same
// table against the Rust side, because "120 hanzi is 360 bytes" is exactly the
// sort of case one backend accepts while the other refuses.
func labelRejectReason(raw []byte) string {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(raw, &doc); err != nil || doc == nil {
		return labelErrDocShape
	}
	value, ok := doc["label"]
	if !ok {
		return labelErrNoLabel
	}
	var s *string
	if err := json.Unmarshal(value, &s); err != nil {
		return labelErrType
	}
	// A JSON `null` unmarshals into a nil *string WITHOUT an error (Go's
	// "null means leave it alone" rule), so the pointer has to be checked
	// separately — and serde_json's `Value::as_str()` returns None for null, so
	// without this line Go accepts what Rust refuses. The divergence is not
	// academic: Go would then read the null as a blank label and DELETE the
	// user's name, while Rust refuses the request. A malformed document must
	// never be able to clear a name; "clear it" has an explicit spelling, the
	// empty string, which both sides agree on.
	if s == nil {
		return labelErrType
	}
	if utf8.RuneCountInString(*s) > dirs.MaxLabelChars {
		return labelErrTooLong
	}
	return ""
}

// labelOf extracts `label` from a document labelRejectReason has already
// accepted. Callers must not use it before that check: a missing or mistyped
// key reads as "", which would then delete the file instead of refusing.
func labelOf(raw []byte) string {
	var doc struct {
		Label string `json:"label"`
	}
	_ = json.Unmarshal(raw, &doc)
	return doc.Label
}

// SyncSessionLabel stores the document, or removes the file when the label is
// blank (SD-G15's "no name" is the absence of a file, not a tombstone).
func SyncSessionLabel(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
		Document  string `json:"document"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	// The id arrives from the client and becomes a path component, so a
	// traversal must be refused rather than sanitised away (the same rule
	// delete_session_dir relies on for RemoveAll).
	if !dirs.SafePathComponent(args.SessionID) {
		return fmt.Errorf("%s", labelErrBadID)
	}
	dir := sessionLabelDir(args.SessionID)
	// A directory is not a session: require what list_session_dirs requires.
	// This also enforces SD-G15 — plan node sessions live deeper and cannot be
	// named even by a client that tried.
	if _, err := os.Stat(filepath.Join(dir, "session.alaya")); err != nil {
		return fmt.Errorf("%s", labelErrNotTop)
	}
	document := []byte(args.Document)
	if why := labelRejectReason(document); why != "" {
		return fmt.Errorf("%s", why)
	}
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	if strings.TrimSpace(labelOf(document)) == "" {
		if err := dirs.RemoveSessionLabel(dir); err != nil {
			return err
		}
		return writeResult(w, map[string]any{"ok": true, "removed": true})
	}
	// Stored VERBATIM: the client owns the document, and a re-marshal here would
	// let the two backends write different bytes for the same name (Go sorts map
	// keys, serde_json's Value keeps insertion order), which is a difference no
	// reader cares about and every diff tool would have to explain.
	if err := dirs.WriteSessionLabel(dir, document); err != nil {
		return err
	}
	return writeResult(w, map[string]any{"ok": true, "written": len(document)})
}
