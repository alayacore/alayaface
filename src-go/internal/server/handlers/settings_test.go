package handlers

import (
	"encoding/json"
	"testing"

	"alayaface/src-go/internal/dirs"
)

func TestNormalizeTrimsAndDropsEmpty(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"", ""},
		{"  ", ""},
		{" execute_command , search_files ,", "execute_command,search_files"},
	}
	for _, c := range cases {
		got, err := NormalizeToolConfirm(c.in)
		if err != nil {
			t.Fatalf("NormalizeToolConfirm(%q) error: %v", c.in, err)
		}
		if got != c.want {
			t.Errorf("NormalizeToolConfirm(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestNormalizeRejectsDuplicatesAndSpaces(t *testing.T) {
	for _, in := range []string{"a,a", "a b", "a\tb"} {
		if _, err := NormalizeToolConfirm(in); err == nil {
			t.Errorf("NormalizeToolConfirm(%q) should error", in)
		}
	}
}

func TestMissingFileYieldsDefaults(t *testing.T) {
	isolatedHome(t, func() {
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		settings, err := readPresetSettings("Simple")
		if err != nil {
			t.Fatal(err)
		}
		if settings.ToolConfirm != "" {
			t.Errorf("tool_confirm = %q, want empty", settings.ToolConfirm)
		}
		if settings.BuiltinTools != "" {
			t.Errorf("builtin_tools = %q, want empty", settings.BuiltinTools)
		}
		if settings.SystemPrompt == "" {
			t.Error("seed system_prompt must not be empty")
		}
	})
}

func TestSyncRoundtrips(t *testing.T) {
	isolatedHome(t, func() {
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		// Valid input with spaces/empty parts → normalized.
		rr := call(t, SyncGlobalSettings, map[string]any{
			"config": `{"tool_confirm":"execute_command, search_files "}`,
			"preset": "Simple",
		})
		if rr.Code != 200 {
			t.Fatalf("sync status = %d, body %s", rr.Code, rr.Body.String())
		}
		settings, err := readPresetSettings("Simple")
		if err != nil {
			t.Fatal(err)
		}
		if settings.ToolConfirm != "execute_command,search_files" {
			t.Errorf("tool_confirm = %q, want execute_command,search_files", settings.ToolConfirm)
		}

		// Invalid input must be rejected and must not clobber the file.
		if err := callErr(t, SyncGlobalSettings, map[string]any{
			"config": `{"tool_confirm":"a a"}`,
			"preset": "Simple",
		}); err == nil {
			t.Error("expected error for tool id with space")
		}
		settings, err = readPresetSettings("Simple")
		if err != nil {
			t.Fatal(err)
		}
		if settings.ToolConfirm != "execute_command,search_files" {
			t.Errorf("file was clobbered: tool_confirm = %q", settings.ToolConfirm)
		}

		// System prompt round-trips verbatim (free text, not normalized).
		call(t, SyncGlobalSettings, map[string]any{
			"config": `{"system_prompt":"line1\nline2 with \"quotes\""}`,
			"preset": "Simple",
		})
		settings, err = readPresetSettings("Simple")
		if err != nil {
			t.Fatal(err)
		}
		if settings.SystemPrompt != "line1\nline2 with \"quotes\"" {
			t.Errorf("system_prompt = %q, want verbatim round-trip", settings.SystemPrompt)
		}
	})
}

func TestGetGlobalSettingsJSONShape(t *testing.T) {
	isolatedHome(t, func() {
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		rr := call(t, GetGlobalSettings, map[string]any{"preset": "Simple"})
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if _, ok := out["tool_confirm"]; !ok {
			t.Errorf("missing tool_confirm key, got %v", out)
		}
		if _, ok := out["system_prompt"]; !ok {
			t.Errorf("missing system_prompt key, got %v", out)
		}
	})
}

func TestBuiltinToolsRoundtrips(t *testing.T) {
	isolatedHome(t, func() {
		// Seed the built-in presets first.
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		// Both seed presets have empty tool lists (no Safe-style
		// restriction preset anymore).
		for _, name := range []string{"Simple", "Complex"} {
			rr := call(t, GetGlobalSettings, map[string]any{"preset": name})
			var out map[string]string
			if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
			if out["builtin_tools"] != "" {
				t.Fatalf("%s builtin_tools = %q, want empty", name, out["builtin_tools"])
			}
			if out["system_prompt"] == "" {
				t.Fatalf("%s system_prompt missing", name)
			}
		}

		// Sync a subset per-preset and read it back.
		call(t, SyncGlobalSettings, map[string]any{
			"config": `{"builtin_tools":"read_file,write_file"}`,
			"preset": "Complex",
		})
		rr := call(t, GetGlobalSettings, map[string]any{"preset": "Complex"})
		var data map[string]string
		if err := json.Unmarshal(rr.Body.Bytes(), &data); err != nil {
			t.Fatal(err)
		}
		if data["builtin_tools"] != "read_file,write_file" {
			t.Fatalf("Complex builtin_tools = %q", data["builtin_tools"])
		}
	})

	// Effective helpers read a NAMED preset; empty preset is rejected.
	isolatedHome(t, func() {
		if _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		if eff, err := effectiveToolConfirm("Simple"); err != nil || eff != "" {
			t.Errorf("effectiveToolConfirm(Simple) = %q, %v", eff, err)
		}
		if _, err := effectiveToolConfirm(""); err == nil {
			t.Error("effectiveToolConfirm(\"\") must be rejected")
		}
		if sp, err := effectiveSystemPrompt("Complex"); err != nil || sp == "" {
			t.Errorf("effectiveSystemPrompt(Complex) = %q, %v", sp, err)
		}
	})
}
