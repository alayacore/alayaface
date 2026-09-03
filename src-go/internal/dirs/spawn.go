package dirs

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// SpawnArgsFile is the file inside a session directory recording the
// alayacore spawn arguments used when the session was created. Resume
// re-applies them so a resumed session keeps its capability envelope:
//
//   - tool_confirm: the --tool-confirm list ("allow" = runner auto-approve)
//   - builtin_tools: nil = don't pass --builtin-tools (all tools);
//     "" = explicitly NO builtin tools (Plan Sessions);
//     "a,b" = those tools only
//   - system_prompt: the --system text (the preset's system_prompt, or a
//     recursion guard over the plan depth limit)
//   - reasoning_level: the --reasoning-level (0|1|2); nil = unset →
//     default 1 on resume
//   - work_dir: the child's working directory (per-plan isolation)
//   - preset: the preset this session was created under; forks of plain
//     sessions inherit it so they stay in the same preset
//
// Sessions created before this file existed (no spawn.json) resume with
// the old behavior (no restrictions) — the file is best-effort.
func SpawnArgsFile(sessionDir string) string {
	return filepath.Join(sessionDir, "session.spawn.json")
}

// SpawnArgs is the persisted spawn configuration of a session.
type SpawnArgs struct {
	ToolConfirm    string  `json:"tool_confirm"`
	BuiltinTools   *string `json:"builtin_tools"`
	SystemPrompt   string  `json:"system_prompt"`
	ReasoningLevel *int    `json:"reasoning_level,omitempty"`
	WorkDir        string  `json:"work_dir"`
	Preset         string  `json:"preset"`
}

// WriteSpawnArgs persists the spawn args atomically (tmp + rename).
func WriteSpawnArgs(sessionDir string, args SpawnArgs) error {
	text, err := json.MarshalIndent(args, "", "  ")
	if err != nil {
		return err
	}
	return WriteFileAtomic(SpawnArgsFile(sessionDir), text)
}

// ReadSpawnArgs reads the persisted spawn args. A missing or corrupt
// file yields zero-value args (old pre-persistence behavior) — never an
// error, so resume keeps working for legacy sessions.
func ReadSpawnArgs(sessionDir string) SpawnArgs {
	text, err := os.ReadFile(SpawnArgsFile(sessionDir))
	if err != nil {
		return SpawnArgs{}
	}
	var args SpawnArgs
	if err := json.Unmarshal(text, &args); err != nil {
		return SpawnArgs{}
	}
	if args.WorkDir != "" && !filepath.IsAbs(args.WorkDir) {
		// Defensive: a relative work dir would resolve against the
		// backend's cwd, not the session's — treat as absent.
		args.WorkDir = ""
	}
	return args
}

// String renders the args for log lines.
func (a SpawnArgs) String() string {
	bt := "<unset>"
	if a.BuiltinTools != nil {
		bt = *a.BuiltinTools
		if bt == "" {
			bt = "<none>"
		}
	}
	rl := "<unset>"
	if a.ReasoningLevel != nil {
		rl = fmt.Sprintf("%d", *a.ReasoningLevel)
	}
	return fmt.Sprintf("tool_confirm=%q builtin_tools=%s system_prompt=%d chars reasoning_level=%s work_dir=%q",
		a.ToolConfirm, bt, len(a.SystemPrompt), rl, a.WorkDir)
}
