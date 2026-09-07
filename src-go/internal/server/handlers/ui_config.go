package handlers

import (
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"os"
	"strings"

	"alayaface/src-go/internal/dirs"
)

// UI layout store (~/.alayaface/ui.conf): every window's rect, the canvas
// pan/zoom and which window was solo, so the board comes back where the user
// left it (F3).
//
// # The backends are storage, not schema
//
// SyncUiConfig REPLACES the file, so a backend that decoded it into a struct
// would drop every key it does not model — the model.conf trap in AGENTS.md,
// where an unmodelled field is silently deleted on the next save and the
// symptom shows up two hops away. Neither backend models the document: the
// stored JSON is handed back as-is and the incoming JSON is written as-is.
// The schema lives in exactly one module: src-elm/src/App/UiConfig.elm.
//
// What IS policed here is the structure that protects the file, with the two
// constants the client mirrors (scripts/check-backend-parity.sh asserts both):
//   - DefaultUiConfVersion: the version reported for an absent document.
//   - MaxStoredWindows: the bound on "windows". Choosing which entries to evict
//     is the client's job (only it knows which windows are open), so an
//     oversized document is refused rather than trimmed by guesswork.
//
// Reading never fails: a missing, empty, non-object or unparseable ui.conf
// means "no document" and the client uses its defaults. Layout is the least
// critical conf file the app has. Writing does fail on a payload that is not a
// layout document — refusing beats destroying the last good file.

// DefaultUiConfVersion is the layout-document version this build reports for an
// absent file. Client twin: UiConfig.version. Rust twin:
// DEFAULT_UI_CONF_VERSION.
const DefaultUiConfVersion = 1

// MaxStoredWindows bounds the "windows" object. Client twin:
// UiConfig.maxStoredWindows. Rust twin: MAX_STORED_WINDOWS.
const MaxStoredWindows = 200

// readUiConfig returns the stored document, or nil for "no usable document"
// (absent, empty, unparseable, or not a JSON object). A parse failure is
// logged, not returned: ui.conf is non-critical (contrast readGlobalConfig,
// where corruption IS reported).
func readUiConfig() json.RawMessage {
	text, err := os.ReadFile(dirs.UiConfigFile())
	if err != nil {
		return nil
	}
	if strings.TrimSpace(string(text)) == "" {
		return nil
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(text, &doc); err != nil {
		fmt.Printf("[ui.conf] ignored (not critical, layout falls back to defaults): %v\n", err)
		return nil
	}
	// A JSON `null` body decodes into a nil map above; it is not a document
	// either. Re-marshal so the caller gets the bytes back verbatim.
	out, err := json.Marshal(doc)
	if err != nil || doc == nil {
		return nil
	}
	return out
}

// uiConfigRejectReason reports whether a document may replace the stored one,
// or "" when it is accepted. Structure only — see the header for why nothing
// deeper is checked here.
//
// The shared fixture testdata/serialization/ui_cases.json runs this same table
// against the Rust side, because "1.0 as a version" is exactly the sort of case
// one backend accepts while the other refuses.
func uiConfigRejectReason(doc map[string]json.RawMessage) string {
	if v, ok := doc["version"]; ok {
		var n float64
		if err := json.Unmarshal(v, &n); err != nil {
			return "UI config 'version' must be an integer"
		}
		// json numbers decode as float64, so integrality is an explicit check:
		// 1.0 passes, 1.5 does not, matching serde_json's as_i64.
		if n != math.Trunc(n) {
			return "UI config 'version' must be an integer"
		}
		if n < 1 {
			return "UI config 'version' must be >= 1"
		}
	}
	if w, ok := doc["windows"]; ok {
		var windows map[string]json.RawMessage
		if err := json.Unmarshal(w, &windows); err != nil || windows == nil {
			return "UI config 'windows' must be an object"
		}
		if len(windows) > MaxStoredWindows {
			return fmt.Sprintf("UI config holds %d windows, over the %d limit", len(windows), MaxStoredWindows)
		}
	}
	return ""
}

// GetUiConfig returns the stored layout: {ok, version, config, error}.
// `config` is the stored document verbatim, or null when there is none — the
// client treats that as "use defaults".
func GetUiConfig(h *Handler, w http.ResponseWriter, r *http.Request) error {
	doc := readUiConfig()
	resp := map[string]any{
		"ok":      true,
		"version": DefaultUiConfVersion,
		"config":  nil,
		"error":   "",
	}
	if doc != nil {
		var parsed map[string]json.RawMessage
		resp["config"] = json.RawMessage(doc)
		if err := json.Unmarshal(doc, &parsed); err == nil {
			if v, ok := parsed["version"]; ok {
				var n float64
				if json.Unmarshal(v, &n) == nil && n == math.Trunc(n) {
					resp["version"] = int64(n)
				}
			}
		}
	}
	return writeJSON(w, resp)
}

// SyncUiConfig replaces the stored layout with the whole document it is given.
// Atomic write (unique temp name); a payload that is not a layout document is
// refused rather than written.
func SyncUiConfig(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Config string `json:"config"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal([]byte(args.Config), &doc); err != nil {
		return fmt.Errorf("Invalid UI config JSON: %w", err)
	}
	if doc == nil {
		// `null` unmarshals into a nil map without an error; it is not a
		// document, and writing it would erase the layout.
		return fmt.Errorf("Invalid UI config JSON: expected a JSON object")
	}
	if why := uiConfigRejectReason(doc); why != "" {
		return fmt.Errorf("%s", why)
	}
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	text, err := json.MarshalIndent(doc, "", "  ")
	if err != nil {
		return err
	}
	if err := dirs.WriteFileAtomic(dirs.UiConfigFile(), text); err != nil {
		return err
	}
	return writeResult(w, map[string]any{"ok": true, "written": len(text)})
}
