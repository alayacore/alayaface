package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// M1 truth table (D3): settings.conf / global.conf / mcp.conf
// parse+write must match the shared fixtures under
// testdata/serialization/ — the same fixtures the Rust side
// (src-tauri/src/commands/{settings,global_config,mcp}.rs) is tested
// against. Locks normalization, field order, quoting and the conf block
// layout across both backends. See REFACTOR.md M1.

func fixturePath(name string) string {
	return filepath.Join("..", "..", "..", "..", "testdata", "serialization", name)
}

func readFixture(t *testing.T, name string) []byte {
	t.Helper()
	text, err := os.ReadFile(fixturePath(name))
	if err != nil {
		t.Fatalf("read fixture %s: %v", name, err)
	}
	return text
}

// ─── settings.conf (GlobalSettings) ────────────────────────────────

type settingsCase struct {
	Name     string `json:"name"`
	Input    struct {
		ToolConfirm  string `json:"tool_confirm"`
		BuiltinTools string `json:"builtin_tools"`
	} `json:"input"`
	Normalized struct {
		ToolConfirm  string `json:"tool_confirm"`
		BuiltinTools string `json:"builtin_tools"`
	} `json:"normalized"`
	ExpectedFile string `json:"expected_file"`
}

func TestSettingsSerializationMatchesSharedFixture(t *testing.T) {
	var fx struct {
		Cases []settingsCase `json:"cases"`
	}
	if err := json.Unmarshal(readFixture(t, "settings_cases.json"), &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			tc, err := NormalizeToolConfirm(c.Input.ToolConfirm)
			if err != nil {
				t.Fatalf("normalize tool_confirm: %v", err)
			}
			bt, err := NormalizeToolConfirm(c.Input.BuiltinTools)
			if err != nil {
				t.Fatalf("normalize builtin_tools: %v", err)
			}
			if tc != c.Normalized.ToolConfirm || bt != c.Normalized.BuiltinTools {
				t.Errorf("normalized mismatch: got (%q, %q), want (%q, %q)",
					tc, bt, c.Normalized.ToolConfirm, c.Normalized.BuiltinTools)
			}
			settings := GlobalSettings{ToolConfirm: tc, BuiltinTools: bt}
			got, err := json.MarshalIndent(settings, "", "  ")
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != c.ExpectedFile {
				t.Errorf("settings.conf mismatch\ngot:\n%s\nwant:\n%s", got, c.ExpectedFile)
			}
		})
	}
}

// ─── global.conf (GlobalConfig) ────────────────────────────────────

type globalCase struct {
	Name     string `json:"name"`
	Input    struct {
		RecursionLimit int `json:"recursion_limit"`
	} `json:"input"`
	Normalized struct {
		RecursionLimit int `json:"recursion_limit"`
	} `json:"normalized"`
	ExpectedFile string `json:"expected_file"`
}

func TestGlobalConfigSerializationMatchesSharedFixture(t *testing.T) {
	var fx struct {
		Cases []globalCase `json:"cases"`
	}
	if err := json.Unmarshal(readFixture(t, "global_cases.json"), &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			n := NormalizeRecursionLimit(c.Input.RecursionLimit)
			if n != c.Normalized.RecursionLimit {
				t.Errorf("normalized mismatch: got %d, want %d", n, c.Normalized.RecursionLimit)
			}
			cfg := GlobalConfig{RecursionLimit: n}
			got, err := json.MarshalIndent(cfg, "", "  ")
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != c.ExpectedFile {
				t.Errorf("global.conf mismatch\ngot:\n%s\nwant:\n%s", got, c.ExpectedFile)
			}
		})
	}
}

// ─── mcp.conf (parse + write) ──────────────────────────────────────

type mcpParseCase struct {
	Name           string `json:"name"`
	InputText      string `json:"input_text"`
	ExpectedParsed string `json:"expected_parsed"`
}

type mcpWriteCase struct {
	Name          string `json:"name"`
	InputServers  string `json:"input_servers"`
	ExpectedText  string `json:"expected_text"`
}

func TestMcpParseMatchesSharedFixture(t *testing.T) {
	var fx struct {
		ParseCases []mcpParseCase `json:"parse_cases"`
	}
	if err := json.Unmarshal(readFixture(t, "mcp_cases.json"), &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	for _, c := range fx.ParseCases {
		t.Run(c.Name, func(t *testing.T) {
			servers := parseMcpConf(c.InputText)
			got, err := json.Marshal(servers)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != c.ExpectedParsed {
				t.Errorf("mcp parse mismatch\ngot:  %s\nwant: %s", got, c.ExpectedParsed)
			}
		})
	}
}

func TestMcpWriteMatchesSharedFixture(t *testing.T) {
	var fx struct {
		WriteCases []mcpWriteCase `json:"write_cases"`
	}
	if err := json.Unmarshal(readFixture(t, "mcp_cases.json"), &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	for _, c := range fx.WriteCases {
		t.Run(c.Name, func(t *testing.T) {
			var servers []map[string]any
			if err := json.Unmarshal([]byte(c.InputServers), &servers); err != nil {
				t.Fatalf("parse input servers: %v", err)
			}
			got := writeMcpConf(servers)
			if got != c.ExpectedText {
				t.Errorf("mcp write mismatch\ngot:\n%s\nwant:\n%s", got, c.ExpectedText)
			}
		})
	}
}
