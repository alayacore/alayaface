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
		{"Simple", true},
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
		_, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		// Presets are EMPTY shells: alayacore auto-creates model.conf /
		// runtime.conf / themes on first use. Seeding an empty model.conf
		// even produced "API key is required" noise (fake Placeholder
		// model), and a "{}" runtime.conf made alayacore emit a parse
		// error on every startup.
		for _, name := range SeedPresets {
			dir := PresetDir(name)
			if _, err := os.Stat(dir); err != nil {
				t.Fatalf("seed preset %s missing: %v", name, err)
			}
			if _, err := os.Stat(filepath.Join(dir, "model.conf")); err == nil {
				t.Errorf("%s: model.conf must not be pre-seeded", name)
			}
			if _, err := os.Stat(filepath.Join(dir, "runtime.conf")); err == nil {
				t.Errorf("%s: runtime.conf must not be pre-seeded", name)
			}
			// All seed presets carry AlayaFace-owned settings.conf.
			settings, err := os.ReadFile(filepath.Join(dir, "settings.conf"))
			if err != nil {
				t.Fatalf("%s settings.conf missing: %v", name, err)
			}
			text := string(settings)
			if !strings.Contains(text, "system_prompt") {
				t.Errorf("%s settings.conf lacks system_prompt: %s", name, text)
			}
			// Simple/Complex carry the plan-mode contract and name both
			// presets; Talk is the voice-first push-to-talk preset —
			// deliberately short and plan-free (speech turns must never
			// trigger planning).
			if name != "Talk" {
				if !strings.Contains(text, "alayaface-plan") {
					t.Errorf("%s system_prompt lacks the plan contract: %s", name, text)
				}
				if !strings.Contains(text, "Simple") || !strings.Contains(text, "Complex") {
					t.Errorf("%s system_prompt must name both presets: %s", name, text)
				}
			} else {
				if strings.Contains(text, "alayaface-plan") {
					t.Errorf("Talk system_prompt must NOT carry the plan contract: %s", text)
				}
				if !strings.Contains(text, "Talk") {
					t.Errorf("Talk system_prompt must identify itself: %s", text)
				}
			}
		}
		// No active-preset marker anymore.
		if _, err := os.Stat(filepath.Join(AlayafaceDir(), "active-preset")); err == nil {
			t.Error("active-preset marker must not exist")
		}
	})
}

func TestEnsureLegacyUpgradeSeedsTalk(t *testing.T) {
	isolatedHome(t, func() {
		// Legacy v1 install: Simple/Complex exist, NO seed_version file.
		// The upgrade must adopt v1 (without resurrecting a v1 seed the
		// user deleted) and add the v2 Talk preset.
		if err := os.MkdirAll(PresetDir("Simple"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(PresetDir("Complex"), 0o755); err != nil {
			t.Fatal(err)
		}
		if _, err := Ensure(); err != nil {
			t.Fatal(err)
		}
		// Talk (introduced in v2) must have been added.
		if _, err := os.Stat(PresetDir("Talk")); err != nil {
			t.Errorf("legacy upgrade must seed Talk: %v", err)
		}
		// The version file lands at the latest version.
		b, err := os.ReadFile(filepath.Join(AlayafaceDir(), seedVersionFile))
		if err != nil {
			t.Fatal(err)
		}
		if string(b) != "2" {
			t.Fatalf("seed_version = %q, want 2", b)
		}
	})
}

func TestEnsureSeedVersionTracksDeletes(t *testing.T) {
	isolatedHome(t, func() {
		// Fresh install: everything seeded, version file at the latest.
		if _, err := Ensure(); err != nil {
			t.Fatal(err)
		}
		for _, name := range SeedPresets {
			if _, err := os.Stat(PresetDir(name)); err != nil {
				t.Errorf("fresh install missing seed %s: %v", name, err)
			}
		}
		// Deleting a seed must NOT resurrect it on the next Ensure —
		// the version file already covers the version that introduced it.
		if err := os.RemoveAll(PresetDir("Talk")); err != nil {
			t.Fatal(err)
		}
		if _, err := Ensure(); err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(PresetDir("Talk")); err == nil {
			t.Error("deleted Talk must not be resurrected")
		}
	})
}

func TestResolveConfigDirRequiresPreset(t *testing.T) {
	isolatedHome(t, func() {
		if _, err := Ensure(); err != nil {
			t.Fatal(err)
		}
		if _, err := ResolveConfigDir(""); err == nil {
			t.Error("empty preset must be rejected")
		}
		if _, err := ResolveConfigDir("nope"); err == nil {
			t.Error("unknown preset must be rejected")
		}
		if dir, err := ResolveConfigDir("Simple"); err != nil || dir != PresetDir("Simple") {
			t.Errorf("ResolveConfigDir(Simple) = %q, %v", dir, err)
		}
	})
}

func TestCreateSessionDirFromRequiresPreset(t *testing.T) {
	isolatedHome(t, func() {
		sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		if _, err := CreateSessionDirFrom(sessions, "abc", ""); err == nil {
			t.Error("empty preset must be rejected")
		}
		if _, err := CreateSessionDirFrom(sessions, "abc", "nope"); err == nil {
			t.Error("unknown preset must be rejected")
		}
	})
}

func TestSessionDirCopyExcludesSettingsConf(t *testing.T) {
	isolatedHome(t, func() {
		sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		config := PresetDir("Simple")
		// Copying an EXISTING preset is the meaningful path: files in the
		// source are copied, settings.conf (AlayaFace-owned) is not.
		if err := os.WriteFile(filepath.Join(config, "model.conf"), []byte("name: \"Real\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(config, "settings.conf"), []byte(`{"tool_confirm":"x"}`), 0o644); err != nil {
			t.Fatal(err)
		}

		sessionDir, err := CreateSessionDirFrom(sessions, "abc", "Simple")
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
		sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(PresetDir("Simple"), "model.conf"), []byte("name: \"Real\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}

		sessionDir, err := CreatePlanSessionDirFrom(sessions, filepath.Join(sessions, "sess-1"), "demo plan/x", "t1", "uuid-1", "Simple")
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

func TestSpawnArgsRoundtrip(t *testing.T) {
	isolatedHome(t, func() {
		dir := t.TempDir()

		// Full envelope: no-tools restriction + runner tool-confirm +
		// preset system prompt + work dir + preset name.
		bt := ""
		full := SpawnArgs{ToolConfirm: "allow", BuiltinTools: &bt, SystemPrompt: "planner-hint", WorkDir: "/tmp/plan-work", Preset: "Complex"}
		if err := WriteSpawnArgs(dir, full); err != nil {
			t.Fatal(err)
		}
		got := ReadSpawnArgs(dir)
		if got.ToolConfirm != "allow" || got.SystemPrompt != "planner-hint" || got.WorkDir != "/tmp/plan-work" || got.Preset != "Complex" {
			t.Errorf("roundtrip = %+v, want the full envelope", got)
		}
		if got.BuiltinTools == nil || *got.BuiltinTools != "" {
			t.Errorf("builtin_tools = %v, want explicit empty (NO tools)", got.BuiltinTools)
		}

		// Nil builtin_tools (don't pass the flag = all tools).
		nilBt := SpawnArgs{ToolConfirm: "", SystemPrompt: ""}
		if err := WriteSpawnArgs(dir, nilBt); err != nil {
			t.Fatal(err)
		}
		got = ReadSpawnArgs(dir)
		if got.BuiltinTools != nil {
			t.Errorf("builtin_tools = %v, want nil (unset)", got.BuiltinTools)
		}

		// A relative work dir is defensively dropped (it would resolve
		// against the backend cwd, not the session).
		rel := SpawnArgs{WorkDir: "relative/dir"}
		if err := WriteSpawnArgs(dir, rel); err != nil {
			t.Fatal(err)
		}
		if got := ReadSpawnArgs(dir); got.WorkDir != "" {
			t.Errorf("relative work dir = %q, want dropped", got.WorkDir)
		}
	})

	// Missing file → zero values (legacy sessions resume unrestricted).
	if got := ReadSpawnArgs(t.TempDir()); got.ToolConfirm != "" || got.BuiltinTools != nil {
		t.Errorf("missing file = %+v, want zero values", got)
	}
}
