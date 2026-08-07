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

func TestHealsLegacyConfigSeeds(t *testing.T) {
	isolatedHome(t, func() {
		config, sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		// Simulate an install seeded before the empty-shell change: the
		// active preset holds "{}" + comment runtime.conf seeds and a
		// Placeholder model.conf; an existing session's config copy holds
		// a comment seed too. ensure() must REMOVE all of them (alayacore
		// recreates), while a real runtime.conf is kept.
		if err := os.WriteFile(filepath.Join(config, "runtime.conf"), []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
		placeholder := `name: "Placeholder"
protocol_type: "openai"
base_url: "https://api.openai.com/v1"
api_key: ""
model_name: "gpt-4o"
context_limit: 128000
max_tokens: 4096
`
		if err := os.WriteFile(filepath.Join(config, "model.conf"), []byte(placeholder), 0o644); err != nil {
			t.Fatal(err)
		}
		sconf := filepath.Join(sessions, "sess-1", "config")
		if err := os.MkdirAll(sconf, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sconf, "runtime.conf"), []byte(LegacyRuntimeConfComment), 0o644); err != nil {
			t.Fatal(err)
		}
		// A meaningful runtime.conf must survive the heal.
		other := filepath.Join(sessions, "sess-2", "config")
		if err := os.MkdirAll(other, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(other, "runtime.conf"), []byte("active_model: \"GPT-4o\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}

		if _, _, err := Ensure(); err != nil {
			t.Fatal(err)
		}

		if _, err := os.Stat(filepath.Join(config, "runtime.conf")); err == nil {
			t.Error("preset runtime.conf seed not removed")
		}
		if _, err := os.Stat(filepath.Join(config, "model.conf")); err == nil {
			t.Error("preset Placeholder model.conf not removed")
		}
		if _, err := os.Stat(filepath.Join(sconf, "runtime.conf")); err == nil {
			t.Error("session comment seed not removed")
		}
		kept, err := os.ReadFile(filepath.Join(other, "runtime.conf"))
		if err != nil {
			t.Fatal(err)
		}
		if string(kept) != "active_model: \"GPT-4o\"\n" {
			t.Errorf("real runtime.conf not kept: %q", string(kept))
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

		sessionDir, err := CreatePlanSessionDirFrom(sessions, "demo plan/x", "t1", "uuid-1", "")
		if err != nil {
			t.Fatal(err)
		}
		want := filepath.Join(sessions, "demo_plan_x", "t1", "uuid-1")
		if sessionDir != want {
			t.Fatalf("nested session dir = %q, want %q", sessionDir, want)
		}
		if _, err := os.Stat(filepath.Join(sessionDir, "config", "model.conf")); err != nil {
			t.Errorf("config not copied into nested dir: %v", err)
		}
		// Top level must NOT contain the session uuid (only the plan dir).
		if _, err := os.Stat(filepath.Join(sessions, "uuid-1")); err == nil {
			t.Error("plan child session must not live at the sessions top level")
		}
	})
}
