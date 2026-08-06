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
		if _, err := os.Stat(filepath.Join(config, "model.conf")); err != nil {
			t.Errorf("model.conf missing: %v", err)
		}
		if _, err := os.Stat(filepath.Join(config, "runtime.conf")); err != nil {
			t.Errorf("runtime.conf missing: %v", err)
		}
		// runtime.conf must be alayacore key:value format (comment lines
		// are skipped), never a JSON "{}" — alayacore emits a parse error
		// on every startup for the latter.
		rc, err := os.ReadFile(filepath.Join(config, "runtime.conf"))
		if err != nil {
			t.Fatal(err)
		}
		if strings.TrimSpace(string(rc)) == "{}" {
			t.Error("runtime.conf must not be a JSON empty object")
		}
		if fi, err := os.Stat(filepath.Join(config, "themes")); err != nil || !fi.IsDir() {
			t.Errorf("themes dir missing: %v", err)
		}
		active, err := ReadActivePreset()
		if err != nil {
			t.Fatal(err)
		}
		if active != "Default" {
			t.Errorf("active preset = %q, want Default", active)
		}
	})
}

func TestHealsBrokenRuntimeConf(t *testing.T) {
	isolatedHome(t, func() {
		config, sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		// Simulate an install seeded before the format fix: the active
		// preset and an existing session's config copy both hold "{}".
		if err := os.WriteFile(filepath.Join(config, "runtime.conf"), []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}
		sconf := filepath.Join(sessions, "sess-1", "config")
		if err := os.MkdirAll(sconf, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(sconf, "runtime.conf"), []byte("{}"), 0o644); err != nil {
			t.Fatal(err)
		}

		if _, _, err := Ensure(); err != nil {
			t.Fatal(err)
		}

		rc, err := os.ReadFile(filepath.Join(config, "runtime.conf"))
		if err != nil {
			t.Fatal(err)
		}
		if strings.TrimSpace(string(rc)) == "{}" || !strings.HasPrefix(string(rc), "#") {
			t.Errorf("preset runtime.conf not healed: %q", string(rc))
		}
		src, err := os.ReadFile(filepath.Join(sconf, "runtime.conf"))
		if err != nil {
			t.Fatal(err)
		}
		if strings.TrimSpace(string(src)) == "{}" {
			t.Errorf("session runtime.conf not healed: %q", string(src))
		}
	})
}

func TestSessionDirCopyExcludesSettingsConf(t *testing.T) {
	isolatedHome(t, func() {
		config, sessions, err := Ensure()
		if err != nil {
			t.Fatal(err)
		}
		// Put a settings.conf in the active preset; it must not be copied.
		if err := os.WriteFile(filepath.Join(config, "settings.conf"), []byte(`{"tool_confirm":"x"}`), 0o644); err != nil {
			t.Fatal(err)
		}

		sessionDir, err := CreateSessionDir(sessions, "abc")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := os.Stat(filepath.Join(sessionDir, "config", "model.conf")); err != nil {
			t.Errorf("model.conf not copied: %v", err)
		}
		if _, err := os.Stat(filepath.Join(sessionDir, "config", "settings.conf")); err == nil {
			t.Error("settings.conf should NOT be copied into sessions")
		}
	})
}
