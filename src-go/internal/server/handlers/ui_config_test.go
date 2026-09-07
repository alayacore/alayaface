package handlers

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"alayaface/src-go/internal/dirs"
)

// ui.conf — the F3 layout store (window rects, canvas transform, solo window).
// The Rust twin is src-tauri/src/commands/ui_config.rs, and the accept/refuse
// table below is the SAME file on both sides
// (testdata/serialization/ui_cases.json), because the drift that matters is "one
// backend accepts a document the other destroys".
//
// The handlers deliberately do NOT model the layout document: sync replaces the
// file, so a modelled schema would delete any key this build has never heard of
// — the model.conf trap. Only structure is validated here.

func TestUiConfigRoundTripKeepsUnknownKeys(t *testing.T) {
	isolatedHome(t, func() {
		doc := map[string]any{
			"version":      1,
			"soloWin":      "sess-1",
			"canvasOffset": map[string]any{"x": 10, "y": 20},
			"canvasScale":  1.5,
			"windows":      map[string]any{"sess-1": map[string]any{"x": 1, "y": 2, "w": 560, "h": 640, "t": 7}},
			// A field this build does not know. If the backend modelled the
			// schema, this line would be gone after the replace.
			"futureField": map[string]any{"not": "understood", "here": true},
		}
		raw, err := json.Marshal(doc)
		if err != nil {
			t.Fatal(err)
		}
		if err := callErr(t, SyncUiConfig, map[string]any{"config": string(raw)}); err != nil {
			t.Fatalf("sync: %v", err)
		}

		rr := call(t, GetUiConfig, map[string]any{})
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out["ok"] != true {
			t.Errorf("ok = %v, want true", out["ok"])
		}
		if v, _ := out["version"].(float64); v != 1 {
			t.Errorf("version = %v, want 1", out["version"])
		}
		stored, err := json.Marshal(out["config"])
		if err != nil {
			t.Fatalf("config is not an object: %v", err)
		}
		var back map[string]json.RawMessage
		if err := json.Unmarshal(stored, &back); err != nil {
			t.Fatalf("stored config unreadable: %v (%s)", err, stored)
		}
		for _, key := range []string{"futureField", "soloWin", "windows", "canvasOffset", "canvasScale"} {
			if _, ok := back[key]; !ok {
				t.Errorf("%s was DELETED by the replace: %s", key, stored)
			}
		}
	})
}

func TestUiConfigAbsentAndCorruptAreNotFatal(t *testing.T) {
	isolatedHome(t, func() {
		seedPresets(t) // creates ~/.alayaface, which the junk write needs
		rr := call(t, GetUiConfig, map[string]any{})
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out["config"] != nil {
			t.Errorf("absent file must report config null, got %v", out["config"])
		}
		if v, _ := out["version"].(float64); v != DefaultUiConfVersion {
			t.Errorf("absent file version = %v, want %d", out["version"], DefaultUiConfVersion)
		}

		// A corrupt file is logged and ignored: layout is non-critical, unlike
		// global.conf whose parse error IS reported to the user.
		if err := os.WriteFile(dirs.UiConfigFile(), []byte("{ this is not json"), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := readUiConfig(); got != nil {
			t.Errorf("corrupt file must read as no document, got %s", got)
		}
		rr = call(t, GetUiConfig, map[string]any{})
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out["ok"] != true || out["config"] != nil {
			t.Errorf("get on a corrupt file = %v, want ok/null", out)
		}
		// …and a later save still works (the junk file is replaced).
		if err := callErr(t, SyncUiConfig, map[string]any{"config": `{"version":1}`}); err != nil {
			t.Fatalf("sync over a corrupt file: %v", err)
		}
		if readUiConfig() == nil {
			t.Error("the recovery write did not land")
		}
	})
}

func TestUiConfigValidationMatchesSharedFixture(t *testing.T) {
	var fx struct {
		Cases []struct {
			Name   string          `json:"name"`
			Input  json.RawMessage `json:"input"`
			Accept bool            `json:"accept"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(readFixture(t, "ui_cases.json"), &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if len(fx.Cases) < 8 {
		t.Fatalf("fixture too small (%d) — a rename? fix the fixture, do not delete the check", len(fx.Cases))
	}
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			var doc map[string]json.RawMessage
			if err := json.Unmarshal(c.Input, &doc); err != nil {
				t.Fatalf("fixture input must be an object: %v", err)
			}
			why := uiConfigRejectReason(doc)
			if c.Accept && why != "" {
				t.Errorf("must be accepted, refused: %s", why)
			}
			if !c.Accept && why == "" {
				t.Error("must be refused but was accepted")
			}
		})
	}
}

func TestUiConfigBodiesAreRefusedBeforeTheyCanDestroyTheFile(t *testing.T) {
	isolatedHome(t, func() {
		for _, junk := range []string{"[1,2,3]", `"windows"`, "42", "null", "not json"} {
			if err := callErr(t, SyncUiConfig, map[string]any{"config": junk}); err == nil {
				t.Errorf("must refuse %s", junk)
			}
		}
		if _, err := os.Stat(dirs.UiConfigFile()); !os.IsNotExist(err) {
			t.Errorf("a refused write must leave no file behind (err=%v)", err)
		}
	})
}

func TestUiConfigWindowCountCap(t *testing.T) {
	isolatedHome(t, func() {
		windows := map[string]any{}
		for i := 0; i <= MaxStoredWindows; i++ {
			windows[fmt.Sprintf("w%d", i)] = map[string]any{"x": 0, "y": 0, "w": 560, "h": 640, "t": i}
		}
		over, _ := json.Marshal(map[string]any{"version": 1, "windows": windows})
		err := callErr(t, SyncUiConfig, map[string]any{"config": string(over)})
		if err == nil {
			t.Fatalf("a document with %d windows must be refused", len(windows))
		}
		if !strings.Contains(err.Error(), "over the") {
			t.Errorf("unexpected refusal: %v", err)
		}
		delete(windows, fmt.Sprintf("w%d", MaxStoredWindows))
		atCap, _ := json.Marshal(map[string]any{"version": 1, "windows": windows})
		if err := callErr(t, SyncUiConfig, map[string]any{"config": string(atCap)}); err != nil {
			t.Errorf("exactly at the cap must write: %v", err)
		}
	})
}

func TestUiConfigFollowsConfigPathOverride(t *testing.T) {
	tmp := t.TempDir()
	profiles := []string{filepath.Join(tmp, "a"), filepath.Join(tmp, "b")}
	t.Cleanup(func() { dirs.SetConfigPath("") })

	// ui.conf belongs to the profile, not to $HOME: two --config-path values
	// must not see each other's layout (the isolation the other confs test).
	dirs.SetConfigPath(profiles[0])
	if err := callErr(t, SyncUiConfig, map[string]any{"config": `{"version":1,"soloWin":"x"}`}); err != nil {
		t.Fatalf("sync: %v", err)
	}
	if _, err := os.Stat(filepath.Join(profiles[0], "ui.conf")); err != nil {
		t.Fatalf("ui.conf must live under the profile dir: %v", err)
	}
	dirs.SetConfigPath(profiles[1])
	if got := readUiConfig(); got != nil {
		t.Errorf("the second profile must start empty, got %s", got)
	}
}

func TestUiConfigWritesLeaveNoTempFiles(t *testing.T) {
	isolatedHome(t, func() {
		for _, payload := range []string{`{"version":1,"canvasScale":0.75}`, `{"version":1,"canvasScale":1.25}`} {
			if err := callErr(t, SyncUiConfig, map[string]any{"config": payload}); err != nil {
				t.Fatalf("sync: %v", err)
			}
		}
		entries, err := os.ReadDir(filepath.Dir(dirs.UiConfigFile()))
		if err != nil {
			t.Fatal(err)
		}
		for _, e := range entries {
			if strings.Contains(e.Name(), ".tmp") {
				t.Errorf("temp file left behind: %s", e.Name())
			}
		}
		if got := readUiConfig(); !strings.Contains(string(got), "1.25") {
			t.Errorf("last write did not win: %s", got)
		}
	})
}
