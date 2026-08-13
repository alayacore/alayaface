package handlers

import (
	"encoding/json"
	"testing"
)

func TestPresetLifecycleRoundtrip(t *testing.T) {
	isolatedHome(t, func() {
		// First run seeds the built-in presets (Simple/Complex).
		rr := call(t, ListPresets, map[string]any{})
		var list []PresetInfo
		if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
			t.Fatal(err)
		}
		if len(list) != 2 {
			t.Fatalf("initial presets = %+v, want 2 seeds", list)
		}
		if !presetIn(list, "Simple") || !presetIn(list, "Complex") {
			t.Fatalf("seed presets wrong: %+v", list)
		}
		// Both seeds are flagged built-in (not renameable).
		if !presetSeed(list, "Simple") || !presetSeed(list, "Complex") {
			t.Fatalf("seed presets must be flagged is_seed: %+v", list)
		}

		// Renaming a built-in seed is rejected (the seeded plan contract
		// references the names).
		if err := callErr(t, RenamePreset, map[string]any{"oldName": "Simple", "newName": "foo"}); err == nil {
			t.Error("expected error renaming the Simple seed")
		}
		if err := callErr(t, RenamePreset, map[string]any{"oldName": "Complex", "newName": "bar"}); err == nil {
			t.Error("expected error renaming the Complex seed")
		}

		// Create a second preset by copying Simple.
		call(t, CopyPreset, map[string]any{"source": "Simple", "name": "work"})
		list = mustListPresets(t)
		if len(list) != 3 {
			t.Fatalf("presets after copy = %+v, want 3", list)
		}
		if !presetIn(list, "work") {
			t.Errorf("work preset missing: %+v", list)
		}
		// A copy is NOT a seed → renameable.
		if presetSeed(list, "work") {
			t.Errorf("copy must not be flagged is_seed: %+v", list)
		}
		call(t, RenamePreset, map[string]any{"oldName": "work", "newName": "work2"})
		list = mustListPresets(t)
		if !presetIn(list, "work2") || presetIn(list, "work") {
			t.Errorf("after rename: %+v", list)
		}

		// Copying a nonexistent source or an existing target is rejected.
		if err := callErr(t, CopyPreset, map[string]any{"source": "nope", "name": "x"}); err == nil {
			t.Error("expected error copying nonexistent source")
		}
		if err := callErr(t, CopyPreset, map[string]any{"source": "Simple", "name": "Simple"}); err == nil {
			t.Error("expected error copying onto existing name")
		}

		// Deleting a non-seed preset works.
		call(t, DeletePreset, map[string]any{"name": "work2"})
		list = mustListPresets(t)
		if len(list) != 2 {
			t.Errorf("after delete: %+v", list)
		}

		// Deleting a built-in seed is rejected (the seeded plan contract
		// references the names).
		if err := callErr(t, DeletePreset, map[string]any{"name": "Simple"}); err == nil {
			t.Error("expected error deleting the Simple seed")
		}
		if err := callErr(t, DeletePreset, map[string]any{"name": "Complex"}); err == nil {
			t.Error("expected error deleting the Complex seed")
		}

		// The two seeds always remain.
		list = mustListPresets(t)
		if !presetIn(list, "Simple") || !presetIn(list, "Complex") {
			t.Errorf("seeds must remain: %+v", list)
		}
	})
}

func TestInvalidNamesRejected(t *testing.T) {
	isolatedHome(t, func() {
		for _, name := range []string{"a/b", "..", "has space", ""} {
			if err := callErr(t, CopyPreset, map[string]any{"source": "Simple", "name": name}); err == nil {
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

func presetIn(list []PresetInfo, name string) bool {
	for _, p := range list {
		if p.Name == name {
			return true
		}
	}
	return false
}

func presetSeed(list []PresetInfo, name string) bool {
	for _, p := range list {
		if p.Name == name {
			return p.IsSeed
		}
	}
	return false
}
