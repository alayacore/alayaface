package handlers

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestPresetLifecycleRoundtrip(t *testing.T) {
	isolatedHome(t, func() {
		// First run seeds the built-in presets (Simple/Complex/Talk).
		rr := call(t, ListPresets, map[string]any{})
		var list []PresetInfo
		if err := json.Unmarshal(rr.Body.Bytes(), &list); err != nil {
			t.Fatal(err)
		}
		if len(list) != 3 {
			t.Fatalf("initial presets = %+v, want 3 seeds", list)
		}
		if !presetIn(list, "Simple") || !presetIn(list, "Complex") || !presetIn(list, "Talk") {
			t.Fatalf("seed presets wrong: %+v", list)
		}
		// All seeds are flagged built-in (not renameable).
		if !presetSeed(list, "Simple") || !presetSeed(list, "Complex") || !presetSeed(list, "Talk") {
			t.Fatalf("seed presets must be flagged is_seed: %+v", list)
		}

		// Renaming a built-in seed is rejected (the seeded plan contract
		// references the names; push-to-talk opens sessions by "Talk").
		if err := callErr(t, RenamePreset, map[string]any{"oldName": "Simple", "newName": "foo"}); err == nil {
			t.Error("expected error renaming the Simple seed")
		}
		if err := callErr(t, RenamePreset, map[string]any{"oldName": "Complex", "newName": "bar"}); err == nil {
			t.Error("expected error renaming the Complex seed")
		}
		if err := callErr(t, RenamePreset, map[string]any{"oldName": "Talk", "newName": "voice"}); err == nil {
			t.Error("expected error renaming the Talk seed")
		}

		// Create a second preset by copying Simple.
		call(t, CopyPreset, map[string]any{"source": "Simple", "name": "work"})
		list = mustListPresets(t)
		if len(list) != 4 {
			t.Fatalf("presets after copy = %+v, want 4", list)
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
		if len(list) != 3 {
			t.Errorf("after delete: %+v", list)
		}

		// Deleting a built-in seed is rejected (the seeded plan contract
		// references the names; push-to-talk opens sessions by "Talk").
		if err := callErr(t, DeletePreset, map[string]any{"name": "Simple"}); err == nil {
			t.Error("expected error deleting the Simple seed")
		}
		if err := callErr(t, DeletePreset, map[string]any{"name": "Complex"}); err == nil {
			t.Error("expected error deleting the Complex seed")
		}
		if err := callErr(t, DeletePreset, map[string]any{"name": "Talk"}); err == nil {
			t.Error("expected error deleting the Talk seed")
		}

		// The three seeds always remain.
		list = mustListPresets(t)
		if !presetIn(list, "Simple") || !presetIn(list, "Complex") || !presetIn(list, "Talk") {
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

func TestReorderPresets(t *testing.T) {
	isolatedHome(t, func() {
		// Seeds: Simple, Complex, Talk (alphabetical by default).
		call(t, CopyPreset, map[string]any{"source": "Simple", "name": "work"})
		list := mustListPresets(t)
		if got := presetNames(list); got != "Complex Simple Talk work" {
			t.Fatalf("default order = %q, want alphabetical", got)
		}

		// Drag-to-reorder: full ordered list persisted.
		call(t, ReorderPresets, map[string]any{"names": []string{"work", "Simple", "Complex"}})
		list = mustListPresets(t)
		if got := presetNames(list); got != "work Simple Complex Talk" {
			t.Fatalf("order after reorder = %q, want work Simple Complex Talk", got)
		}

		// Unknown names are ignored, missing presets appended in sorted
		// order — the file can never hide a preset.
		call(t, ReorderPresets, map[string]any{"names": []string{"nope", "Complex", "work"}})
		list = mustListPresets(t)
		if got := presetNames(list); got != "Complex work Simple Talk" {
			t.Fatalf("order after partial reorder = %q, want Complex work Simple Talk", got)
		}

		// Order survives a later list call (persisted to disk).
		list = mustListPresets(t)
		if got := presetNames(list); got != "Complex work Simple Talk" {
			t.Fatalf("persisted order = %q, want Complex work Simple Talk", got)
		}

		// A new preset lands at the end (not hidden).
		call(t, CopyPreset, map[string]any{"source": "Simple", "name": "aaa"})
		list = mustListPresets(t)
		if got := presetNames(list); got != "Complex work Simple Talk aaa" {
			t.Fatalf("order with new preset = %q, want Complex work Simple Talk aaa", got)
		}
	})
}

func presetNames(list []PresetInfo) string {
	names := make([]string, 0, len(list))
	for _, p := range list {
		names = append(names, p.Name)
	}
	return strings.Join(names, " ")
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
