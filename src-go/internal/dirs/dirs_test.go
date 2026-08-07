package dirs

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// isolatedHome points HOME at a fresh temp dir for the duration of f.
// Tests that mutate HOME must go through this helper (no t.Parallel).
func isolatedHome(t *testing.T, f func()) {
	t.Helper()
	tmp := t.TempDir()
	t.Setenv("HOME", tmp)
	f()
}

func TestPresetNameValidation(t *testing.T) {
	cases := []struct {
		name string
		ok   bool
	}{
		{"Default", true},
		{"work-a_b2", true},
		{"", false},
		{"a/b", false},
		{"..", false},
		{"with space", false},
		{string(make([]rune, 65)), false},
	}
	for _, c := range cases {
		if got := ValidPresetName(c.name); got != c.ok {
			t.Errorf("ValidPresetName(%q) = %v, want %v", c.name, got, c.ok)
		}
	}
}

func TestEnsureSeedsDefaults(t *testing.T) {
	isolatedHome(t, func() {
		config, _, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		// Presets are EMPTY shells: alayacore auto-creates model.conf /
		// runtime.conf / themes on first use. Seeding an empty model.conf
		// even produced "API key is required" noise (fake Placeholder
		// model), and a "{}" runtime.conf made alayacore emit a parse
		// error on every startup.
		if _, err := os.Stat(filepath.Join(config, "model.conf")); err == nil {
			t.Error("model.conf must not be pre-seeded")
		}
		if _, err := os.Stat(filepath.Join(config, "runtime.conf")); err == nil {
			t.Error("runtime.conf must not be pre-seeded")
		}
		active, err := ReadActivePreset()
		if err != nil {
			t.Fatal(err)
		}
		if active != "Default" {
			t.Errorf("active preset = %q, want Default", active)
		}
		// Only the Safe preset carries AlayaFace-owned settings.conf.
		if _, err := os.Stat(filepath.Join(config, "settings.conf")); err == nil {
			t.Error("Default preset must not carry settings.conf")
		}
		safeSettings, err := os.ReadFile(filepath.Join(PresetsRoot(), "Safe", "settings.conf"))
		if err != nil {
			t.Fatalf("Safe settings.conf missing: %v", err)
		}
		if !strings.Contains(string(safeSettings), "read_file,write_file,edit_file,search_content") {
			t.Errorf("Safe settings.conf wrong: %s", safeSettings)
		}
	})
}

func TestSessionDirCopyExcludesSettingsConf(t *testing.T) {
	isolatedHome(t, func() {
		config, sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		// Copying an EXISTING preset is the meaningful path: files in the
		// source are copied, settings.conf (AlayaFace-owned) is not.
		if err := os.WriteFile(filepath.Join(config, "model.conf"), []byte("name: \"Real\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(config, "settings.conf"), []byte(`{"tool_confirm":"x"}`), 0o644); err != nil {
			t.Fatal(err)
		}

		sessionDir, err := CreateSessionDir(sessions, "abc")
		if err != nil {
			t.Fatal(err)
		}
		copied, err := os.ReadFile(filepath.Join(sessionDir, "config", "model.conf"))
		if err != nil {
			t.Errorf("model.conf not copied: %v", err)
		}
		if string(copied) != "name: \"Real\"\n" {
			t.Errorf("model.conf copy wrong: %q", string(copied))
		}
		if _, err := os.Stat(filepath.Join(sessionDir, "config", "settings.conf")); err == nil {
			t.Error("settings.conf should NOT be copied into sessions")
		}
	})
}

func TestSanitizeDirComponent(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"demo-1", "demo-1"},
		{"task 1", "task_1"},
		{"a/b", "a_b"},
		{"..", "__"},
		{".", "_"},
		{"", "p"},
		{"deep/node.id", "deep_node_id"},
		{"weird~chars!?", "weird_chars__"},
	}
	for _, c := range cases {
		if got := SanitizeDirComponent(c.in); got != c.want {
			t.Errorf("SanitizeDirComponent(%q) = %q, want %q", c.in, got, c.want)
		}
	}
	// Deterministic: create and resume must agree on the mapping.
	if SanitizeDirComponent("a/b") != SanitizeDirComponent("a_b") {
		t.Error("sanitize must be deterministic")
	}
}

func TestCreatePlanSessionDirFromNests(t *testing.T) {
	isolatedHome(t, func() {
		config, sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(config, "model.conf"), []byte("name: \"Real\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}

		sessionDir, err := CreatePlanSessionDirFrom(sessions, "sess-1", "demo plan/x", "t1", "uuid-1", "")
		if err != nil {
			t.Fatal(err)
		}
		want := filepath.Join(sessions, "sess-1", "plans", "demo_plan_x", "t1", "uuid-1")
		if sessionDir != want {
			t.Fatalf("nested session dir = %q, want %q", sessionDir, want)
		}
		if _, err := os.Stat(filepath.Join(sessionDir, "config", "model.conf")); err != nil {
			t.Errorf("config not copied into nested dir: %v", err)
		}
		// Top level must NOT contain the session uuid (only the session
		// dirs, each holding plans/ inside).
		if _, err := os.Stat(filepath.Join(sessions, "uuid-1")); err == nil {
			t.Error("plan child session must not live at the sessions top level")
		}
		if _, err := os.Stat(filepath.Join(sessions, "demo_plan_x")); err == nil {
			t.Error("plan dir must not live at the sessions top level (must be under its session)")
		}
	})
}
