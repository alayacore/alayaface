package handlers

import (
	"encoding/json"
	"testing"
)

func TestPresetLifecycleRoundtrip(t *testing.T) {
	isolatedHome(t, func() {
		// First run seeds the built-in presets (Default/Fast/Deep/Data/Safe)
		// and marks Default active.
		rr := call(t, ListPresets, map[string]any{})
		var list []PresetInfo
		if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
			t.Fatal(err)
		}
		if len(list) != 5 {
			t.Fatalf("initial presets = %+v, want 5 seeds", list)
		}
		if !presetIn(list, "Default", true) || !presetIn(list, "Safe", false) {
			t.Fatalf("seed presets wrong: %+v", list)
		}

		// Create a second preset by copying Default.
		call(t, CopyPreset, map[string]any{"source": "Default", "name": "work"})
		list = mustListPresets(t)
		if len(list) != 6 {
			t.Fatalf("presets after copy = %+v, want 6", list)
		}
		if !presetIn(list, "work", false) {
			t.Errorf("work preset missing or wrongly active: %+v", list)
		}

		// Copying a nonexistent source or an existing target is rejected.
		if err := callErr(t, CopyPreset, map[string]any{"source": "nope", "name": "x"}); err == nil {
			t.Error("expected error copying nonexistent source")
		}
		if err := callErr(t, CopyPreset, map[string]any{"source": "Default", "name": "Default"}); err == nil {
			t.Error("expected error copying onto existing name")
		}

		// Switch active.
		call(t, SetActivePreset, map[string]any{"name": "work"})
		list = mustListPresets(t)
		if !presetIn(list, "work", true) || !presetIn(list, "Default", false) {
			t.Errorf("after switch: %+v", list)
		}

		// Renaming the active preset moves the marker too.
		call(t, RenamePreset, map[string]any{"oldName": "work", "newName": "work2"})
		list = mustListPresets(t)
		if !presetIn(list, "work2", true) {
			t.Errorf("after rename: %+v", list)
		}

		// Cannot delete the active preset.
		if err := callErr(t, DeletePreset, map[string]any{"name": "work2"}); err == nil {
			t.Error("expected error deleting active preset")
		}

		// Cannot delete the last remaining preset.
		call(t, SetActivePreset, map[string]any{"name": "Default"})
		if err := callErr(t, DeletePreset, map[string]any{"name": "Default"}); err == nil {
			t.Error("expected error deleting last preset")
		}

		// Deleting a non-active preset works.
		call(t, DeletePreset, map[string]any{"name": "work2"})
		list = mustListPresets(t)
		if len(list) != 5 || !presetIn(list, "Default", true) {
			t.Errorf("after delete: %+v", list)
		}
	})
}

func TestInvalidNamesRejected(t *testing.T) {
	isolatedHome(t, func() {
		for _, name := range []string{"a/b", "..", "has space", ""} {
			if err := callErr(t, CopyPreset, map[string]any{"source": "Default", "name": name}); err == nil {
				t.Errorf("expected error copying to name %q", name)
			}
		}
	})
}

func mustListPresets(t *testing.T) []PresetInfo {
	t.Helper()
	rr := call(t, ListPresets, map[string]any{})
	var list []PresetInfo
	if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
		t.Fatal(err)
	}
	return list
}

func presetIn(list []PresetInfo, name string, active bool) bool {
	for _, p := range list {
		if p.Name == name {
			return p.IsActive == active
		}
	}
	return false
}
