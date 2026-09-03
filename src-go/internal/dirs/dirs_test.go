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

func TestEnsureDeletedSeedNotResurrected(t *testing.T) {
	isolatedHome(t, func() {
		// Fresh install: everything seeded on first run.
		if _, err := Ensure(); err != nil {
			t.Fatal(err)
		}
		for _, name := range SeedPresets {
			if _, err := os.Stat(PresetDir(name)); err != nil {
				t.Errorf("fresh install missing seed %s: %v", name, err)
			}
		}
		// Deleting a seed must NOT resurrect it on the next Ensure —
		// seeding only ever runs on an empty presets root.
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

func TestConfigPathOverride(t *testing.T) {
	// Process-global state — no t.Parallel.
	prev := ConfigPath()
	t.Cleanup(func() { SetConfigPath(prev) })

	isolatedHome(t, func() {
		// Default: still $HOME/.alayaface when no override is set.
		old := ConfigPath()
		SetConfigPath("")
		t.Cleanup(func() { SetConfigPath(old) })

		wantDefault := filepath.Join(os.Getenv("HOME"), ".alayaface")
		if got := AlayafaceDir(); got != wantDefault {
			t.Errorf("AlayafaceDir() = %q, want %q", got, wantDefault)
		}

		// Absolute override replaces the default entirely.
		override := t.TempDir()
		SetConfigPath(override)
		if got := AlayafaceDir(); got != override {
			t.Errorf("AlayafaceDir() with override = %q, want %q", got, override)
		}
		// Every helper routes through the override.
		if got := PresetsRoot(); got != filepath.Join(override, "presets") {
			t.Errorf("PresetsRoot() = %q, want %q", got, filepath.Join(override, "presets"))
		}
		if got := GlobalConfigFile(); got != filepath.Join(override, "global.conf") {
			t.Errorf("GlobalConfigFile() = %q, want %q", got, filepath.Join(override, "global.conf"))
		}
		if got := AsrConfigFile(); got != filepath.Join(override, "asr.conf") {
			t.Errorf("AsrConfigFile() = %q, want %q", got, filepath.Join(override, "asr.conf"))
		}

		// "~" expands against $HOME.
		SetConfigPath("~")
		if got := AlayafaceDir(); got != os.Getenv("HOME") {
			t.Errorf("AlayafaceDir() with \"~\" = %q, want %q", got, os.Getenv("HOME"))
		}
		SetConfigPath("~/nested/config")
		if got := AlayafaceDir(); got != filepath.Join(os.Getenv("HOME"), "nested", "config") {
			t.Errorf("AlayafaceDir() with \"~/nested/config\" = %q, want %q", got, filepath.Join(os.Getenv("HOME"), "nested", "config"))
		}

		// Empty override restores the $HOME/.alayaface default.
		SetConfigPath("")
		if got := AlayafaceDir(); got != wantDefault {
			t.Errorf("AlayafaceDir() after clearing override = %q, want %q", got, wantDefault)
		}
	})
}

func TestEnsureUsesConfigPathOverride(t *testing.T) {
	// Ensure() must create the directory structure under the override,
	// not under $HOME/.alayaface — the override is the whole point of
	// the flag.
	prev := ConfigPath()
	t.Cleanup(func() { SetConfigPath(prev) })

	isolatedHome(t, func() {
		override := t.TempDir()
		// Make sure the temp dir is NOT under $HOME so a regression that
		// silently fell back to the default would be visible.
		override, err := filepath.Abs(override)
		if err != nil {
			t.Fatal(err)
		}

		old := ConfigPath()
		SetConfigPath(override)
		t.Cleanup(func() { SetConfigPath(old) })

		if _, err := Ensure(); err != nil {
			t.Fatal(err)
		}
		for _, name := range SeedPresets {
			if _, err := os.Stat(filepath.Join(override, "presets", name)); err != nil {
				t.Errorf("seed preset %s not created under override: %v", name, err)
			}
		}
		// And nothing leaked into the default location.
		defaultBase := filepath.Join(os.Getenv("HOME"), ".alayaface")
		if _, err := os.Stat(defaultBase); err == nil {
			t.Errorf("default base %q must NOT exist when override is set", defaultBase)
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

// TestSessionPathValidatesAndContains pins the guards on the ONE path rule
// shared by create and resume/delete/fork. A client supplies sessionId,
// originSessionDir, planId and nodeId, and delete_session_dir feeds the result
// to os.RemoveAll — so a traversal must be refused, not silently folded away.
func TestSessionPathValidatesAndContains(t *testing.T) {
	root := filepath.Join(string(filepath.Separator), "cfg", "sessions")

	// A plain session: root/<id>, whatever the origin says.
	plain, err := SessionPath(root, "", "", "", "abc")
	if err != nil || plain != filepath.Join(root, "abc") {
		t.Fatalf("plain = %q, %v", plain, err)
	}

	// A traversal in the session id is rejected outright (this used to
	// resolve to the sessions root itself, which RemoveAll would empty).
	for _, bad := range []string{"..", ".", "a/b", `a\b`, ""} {
		if _, err := SessionPath(root, "", "plan", "node", bad); err == nil {
			t.Errorf("SessionPath accepted session id %q", bad)
		}
		if _, err := SessionPath(root, "", "", "", bad); err == nil {
			t.Errorf("SessionPath accepted plain session id %q", bad)
		}
	}

	// A nested origin that escapes the store is rejected.
	if _, err := SessionPath(root, "/etc", "plan", "node", "abc"); err == nil {
		t.Error("SessionPath accepted an origin directory outside the sessions root")
	}

	// A real origin directory stays inside and keeps its shape.
	nested, err := SessionPath(root, filepath.Join(root, "sess-1"), "demo plan/x", "t1", "abc")
	if err != nil {
		t.Fatalf("nested: %v", err)
	}
	if want := filepath.Join(root, "sess-1", "plans", "demo_plan_x", "t1", "abc"); nested != want {
		t.Errorf("nested = %q, want %q", nested, want)
	}

	// A BARE origin id resolves against the root — the rule Rust previously
	// lacked (its create_session_dir_nested ignored the sessions root
	// entirely), which put the same plan node session in different places.
	bare, err := SessionPath(root, "sess-1", "p", "n", "abc")
	if err != nil {
		t.Fatalf("bare: %v", err)
	}
	if want := filepath.Join(root, "sess-1", "plans", "p", "n", "abc"); bare != want {
		t.Errorf("bare origin id = %q, want %q", bare, want)
	}
}

func TestSafePathComponent(t *testing.T) {
	for _, ok := range []string{"abc", "a-b_c", "3f2a...", "with space.txt", "sess.1"} {
		if !SafePathComponent(ok) {
			t.Errorf("SafePathComponent(%q) = false, want true (single component)", ok)
		}
	}
	for _, bad := range []string{"", ".", "..", "a/b", `a\b`, "a\x00b"} {
		if SafePathComponent(bad) {
			t.Errorf("SafePathComponent(%q) = true, want false", bad)
		}
	}
}
