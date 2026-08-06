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
		settings, err := readGlobalSettings()
		if err != nil {
			t.Fatal(err)
		}
		if settings.ToolConfirm != "" {
			t.Errorf("tool_confirm = %q, want empty", settings.ToolConfirm)
		}
	})
}

func TestSyncRoundtrips(t *testing.T) {
	isolatedHome(t, func() {
		// Valid input with spaces/empty parts → normalized.
		rr := call(t, SyncGlobalSettings, map[string]any{
			"config": `{"tool_confirm":"execute_command, search_files "}`,
			"preset": "",
		})
		if rr.Code != 200 {
			t.Fatalf("sync status = %d, body %s", rr.Code, rr.Body.String())
		}
		settings, err := readGlobalSettings()
		if err != nil {
			t.Fatal(err)
		}
		if settings.ToolConfirm != "execute_command,search_files" {
			t.Errorf("tool_confirm = %q, want execute_command,search_files", settings.ToolConfirm)
		}

		// Invalid input must be rejected and must not clobber the file.
		if err := callErr(t, SyncGlobalSettings, map[string]any{
			"config": `{"tool_confirm":"a a"}`,
			"preset": "",
		}); err == nil {
			t.Error("expected error for tool id with space")
		}
		settings, err = readGlobalSettings()
		if err != nil {
			t.Fatal(err)
		}
		if settings.ToolConfirm != "execute_command,search_files" {
			t.Errorf("file was clobbered: tool_confirm = %q", settings.ToolConfirm)
		}
	})
}

func TestGetGlobalSettingsJSONShape(t *testing.T) {
	isolatedHome(t, func() {
		rr := call(t, GetGlobalSettings, map[string]any{"preset": ""})
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if _, ok := out["tool_confirm"]; !ok {
			t.Errorf("missing tool_confirm key, got %v", out)
		}
	})
}

func TestBuiltinToolsRoundtrips(t *testing.T) {
	isolatedHome(t, func() {
		// Seed the built-in presets first.
		if _, _, err := dirs.Ensure(); err != nil {
			t.Fatal(err)
		}
		// Safe seed preset carries builtin_tools (parity with Rust).
		rr := call(t, GetGlobalSettings, map[string]any{"preset": "Safe"})
		var safe map[string]string
		if err := json.Unmarshal(rr.Body.Bytes(), &safe); err != nil {
			t.Fatal(err)
		}
		if safe["builtin_tools"] != "read_file,write_file,edit_file,search_content" {
			t.Fatalf("Safe builtin_tools = %q", safe["builtin_tools"])
		}

		// Default is empty (all tools).
		rr = call(t, GetGlobalSettings, map[string]any{"preset": ""})
		var def map[string]string
		if err := json.Unmarshal(rr.Body.Bytes(), &def); err != nil {
			t.Fatal(err)
		}
		if def["builtin_tools"] != "" {
			t.Fatalf("Default builtin_tools = %q, want empty", def["builtin_tools"])
		}

		// Sync a subset per-preset and read it back.
		call(t, SyncGlobalSettings, map[string]any{
			"config": `{"builtin_tools":"read_file,write_file"}`,
			"preset": "Data",
		})
		rr = call(t, GetGlobalSettings, map[string]any{"preset": "Data"})
		var data map[string]string
		if err := json.Unmarshal(rr.Body.Bytes(), &data); err != nil {
			t.Fatal(err)
		}
		if data["builtin_tools"] != "read_file,write_file" {
			t.Fatalf("Data builtin_tools = %q", data["builtin_tools"])
		}
	})
}
