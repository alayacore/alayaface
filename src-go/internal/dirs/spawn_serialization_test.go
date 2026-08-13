package dirs

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// M1 truth table (D3): session.spawn.json serialization must match the
// shared fixture testdata/serialization/spawn_cases.json — the same
// fixture the Rust side (src-tauri/src/dirs.rs) is tested against.
// Locks the builtin_tools null semantics (nil -> null, "" -> "",
// "a,b" -> "a,b") and the 2-space pretty layout. See REFACTOR.md M1.

type spawnFixture struct {
	Cases []spawnCase `json:"cases"`
}

type spawnCase struct {
	Name     string     `json:"name"`
	Input    spawnInput `json:"input"`
	Expected string     `json:"expected"`
}

type spawnInput struct {
	ToolConfirm  string  `json:"tool_confirm"`
	BuiltinTools *string `json:"builtin_tools"`
	SystemPrompt string  `json:"system_prompt"`
	WorkDir      string  `json:"work_dir"`
	Preset       string  `json:"preset"`
}

func loadSpawnFixture(t *testing.T) spawnFixture {
	t.Helper()
	path := filepath.Join("..", "..", "..", "testdata", "serialization", "spawn_cases.json")
	text, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fx spawnFixture
	if err := json.Unmarshal(text, &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	return fx
}

func TestSpawnArgsSerializationMatchesSharedFixture(t *testing.T) {
	fx := loadSpawnFixture(t)
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			args := SpawnArgs{
				ToolConfirm:  c.Input.ToolConfirm,
				BuiltinTools: c.Input.BuiltinTools,
				SystemPrompt: c.Input.SystemPrompt,
				WorkDir:      c.Input.WorkDir,
				Preset:       c.Input.Preset,
			}
			got, err := json.MarshalIndent(args, "", "  ")
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != c.Expected {
				t.Errorf("spawn.json mismatch\ngot:\n%s\nwant:\n%s", got, c.Expected)
			}
		})
	}
}
