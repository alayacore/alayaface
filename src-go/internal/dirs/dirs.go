// Package dirs manages the ~/.alayaface/ directory structure.
//
//	~/.alayaface/
//	  global.conf          — cross-preset global config overlay (recursion_limit etc.)
//	  presets/
//	    <name>/            — one config directory per preset
//	      model.conf
//	      runtime.conf
//	      mcp.conf
//	      settings.conf    — AlayaFace-owned (tool_confirm, builtin_tools, system_prompt); NOT copied into sessions
//	      themes/
//	  sessions/
//	    <uuid>/            — PLAIN sessions only (top level is never a plan child)
//	      config/          — copy of the creating preset's config (minus settings.conf)
//	      session.alaya
//	      plans/           — plans created by this session (0..N)
//	        <planId>/      — one subtree per plan (sanitized id)
//	          <planId>.json / .meta.json / .run.json
//	          work/        — per-plan working directory
//	          <nodeId>/    — one subtree per plan node (sanitized id)
//	            <uuid>/    — the node's session dir (config/ + session.alaya)
//
// Port of src-tauri/src/dirs.rs. There is no "active preset": every
// session is created under an explicitly chosen preset (the frontend
// always passes one), and each preset carries its own settings.conf
// including the system_prompt used as --system.
package dirs

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// AlayafaceDir returns the base directory (~/.alayaface).
func AlayafaceDir() string {
	home := os.Getenv("HOME")
	if home == "" {
		home = os.Getenv("USERPROFILE")
	}
	if home == "" {
		home = "."
	}
	return filepath.Join(home, ".alayaface")
}

// PresetsRoot returns the directory holding all presets (~/.alayaface/presets).
func PresetsRoot() string {
	return filepath.Join(AlayafaceDir(), "presets")
}

// GlobalConfigFile returns the cross-preset global config file
// (~/.alayaface/global.conf). Unlike settings.conf (one per preset),
// this file applies to every preset — the global config overlay.
func GlobalConfigFile() string {
	return filepath.Join(AlayafaceDir(), "global.conf")
}

// ValidPresetName reports whether a preset name is a short,
// filesystem-safe identifier.
func ValidPresetName(name string) bool {
	if name == "" || len(name) > 64 {
		return false
	}
	for _, c := range name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_') {
			return false
		}
	}
	return true
}

// PresetDir returns the absolute path of a preset's config directory.
func PresetDir(name string) string {
	return filepath.Join(PresetsRoot(), name)
}

// ResolveConfigDir resolves the config dir for a preset name.
// The preset is REQUIRED — there is no active-preset fallback. Errors
// for empty/invalid names or unknown presets.
func ResolveConfigDir(preset string) (string, error) {
	name := strings.TrimSpace(preset)
	if name == "" {
		return "", fmt.Errorf("Preset is required")
	}
	if !ValidPresetName(name) {
		return "", fmt.Errorf("Invalid preset name: %q", name)
	}
	dir := PresetDir(name)
	if _, err := os.Stat(dir); err != nil {
		return "", fmt.Errorf("Preset not found: %s", name)
	}
	return dir, nil
}

// ListPresetNames returns preset names (sorted). A missing presets root
// yields an empty list.
func ListPresetNames() ([]string, error) {
	entries, err := os.ReadDir(PresetsRoot())
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if e.IsDir() && ValidPresetName(e.Name()) {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names, nil
}

// Ensure guarantees ~/.alayaface/ exists with the preset structure.
// On FIRST RUN (empty presets root), seeds the built-in presets
// (Simple/Complex) with their settings.conf (tool_confirm/builtin_tools/
// system_prompt). Once seeded, the seeds are regular presets: deleting
// one must not resurrect it, so seeding never runs again on a
// non-empty root. Returns the sessions dir.
func Ensure() (string, error) {
	base := AlayafaceDir()
	presets := PresetsRoot()
	sessions := filepath.Join(base, "sessions")

	for _, d := range []string{presets, sessions} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return "", err
		}
	}

	// Seed built-in presets on first run only (a non-empty root means
	// the user has already managed presets — deleting a seed must not
	// resurrect it).
	entries, err := os.ReadDir(presets)
	if err != nil {
		return "", err
	}
	if len(entries) == 0 {
		for _, name := range SeedPresets {
			if err := CreatePresetDefaults(filepath.Join(presets, name), name); err != nil {
				return "", err
			}
		}
	}

	return sessions, nil
}

// SeedPresets lists the built-in presets seeded on first run:
//   - Simple  — light everyday chat and one-sentence subtasks
//   - Complex — heavy reasoning / multi-step / research subtasks
//
// Each is a config template (model/mcp placeholders); users fill keys,
// tune settings.conf and can copy/rename them. The plan contract in the
// seeded system_prompt names these presets, so they cannot be renamed
// (see IsSeedPreset).
var SeedPresets = []string{"Simple", "Complex"}

// IsSeedPreset reports whether a preset is one of the built-in seeds.
// Seed presets are referenced by name in the seeded system_prompt, so
// renaming them is rejected (rename_preset).
func IsSeedPreset(name string) bool {
	for _, s := range SeedPresets {
		if s == name {
			return true
		}
	}
	return false
}

// CreateSessionDirFrom creates a session directory from a specific
// preset's config (`preset` REQUIRED). Used by Plan Mode so different
// DAG nodes can run under different presets. settings.conf is excluded
// from the copy.
func CreateSessionDirFrom(sessionsDir, uuid, preset string) (string, error) {
	return createSessionDirIn(sessionsDir, uuid, preset)
}

// SanitizeDirComponent maps an arbitrary plan/node id to a safe single
// path component (deterministic: create and resume apply the same
// mapping, so both sides agree on the directory). Every character
// outside [A-Za-z0-9_-] becomes '_' — including '.', so an id of ".."
// can never resolve to a parent directory — and an empty result becomes
// "p".
func SanitizeDirComponent(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	out := b.String()
	if out == "" {
		return "p"
	}
	return out
}

// CreatePlanSessionDirFrom creates a PLAN NODE session directory nested
// under <originSessionDir>/plans/<planId>/<nodeId>/<uuid>/, where
// originSessionDir is the owning session's REAL directory (the frontend
// passes sessions/<id> for a top-level session or the nested node-session
// dir for a plan child — P28: the sessions/ top level only ever contains
// plain sessions). All id components are sanitized with
// SanitizeDirComponent; preset selects the config template like
// CreateSessionDirFrom.
func CreatePlanSessionDirFrom(sessionsDir, originSessionDir, planId, nodeId, uuid, preset string) (string, error) {
	parent := filepath.Join(
		originSessionDir,
		"plans",
		SanitizeDirComponent(planId),
		SanitizeDirComponent(nodeId),
	)
	return createSessionDirIn(parent, uuid, preset)
}

// createSessionDirIn copies the preset config into parent/<uuid>/config.
func createSessionDirIn(parent, uuid, preset string) (string, error) {
	if _, err := Ensure(); err != nil {
		return "", err
	}
	name := strings.TrimSpace(preset)
	if name == "" {
		return "", fmt.Errorf("Preset is required")
	}
	if !ValidPresetName(name) {
		return "", os.ErrInvalid
	}
	template := PresetDir(name)
	if _, err := os.Stat(template); err != nil {
		return "", fmt.Errorf("Preset not found: %s", preset)
	}

	sessionDir := filepath.Join(parent, uuid)
	dstConfig := filepath.Join(sessionDir, "config")
	if err := copyDirExcluding(template, dstConfig, []string{"settings.conf"}); err != nil {
		return "", err
	}
	return sessionDir, nil
}

// ClonePresetDir recursively copies a whole preset directory (including
// settings.conf) — used when cloning a preset to create a new one.
func ClonePresetDir(src, dst string) error {
	return copyDirExcluding(src, dst, nil)
}

// seedSettingsConf builds the AlayaFace-owned settings.conf for a seed
// preset: empty tool lists, the default reasoning level (1 = Balanced)
// plus the preset's system_prompt (the plan contract phrased for the
// preset's role).
func seedSettingsConf(name string) string {
	s := map[string]any{
		"tool_confirm":    "",
		"builtin_tools":   "",
		"reasoning_level": 1,
		"system_prompt":   seedSystemPrompt(name),
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return ""
	}
	return string(b)
}

// seedSystemPrompt returns the seeded --system text for a preset. Both
// seeds carry the full plan-mode contract (any session may be asked to
// create a plan); the difference is the role framing. Keep in sync with
// src-tauri/src/dirs.rs seed_system_prompt.
func seedSystemPrompt(name string) string {
	role := "You are the Simple preset of AlayaFace: handle everyday chat and light tasks directly, in one go, without planning.\n"
	if name == "Complex" {
		role = "You are the Complex preset of AlayaFace: you handle heavy reasoning, multi-step and research-heavy tasks. Prefer decomposing them into a plan.\n"
	}
	return role + planContract
}

// planContract is the plan-mode contract shared by every seed preset:
// when to output a plan, the exact JSON schema, per-task preset choice
// and stopping rules. Keep in sync with src-tauri/src/dirs.rs.
// (Written with a @@FENCE@@ placeholder because Go raw strings cannot
// contain backticks — the plan format needs ```json fences.)
var planContract = strings.ReplaceAll(planContractRaw, "@@FENCE@@", "```")

const planContractRaw = `
You can use AlayaFace's plan mode: for complex or multi-step tasks, first output a plan so its subtasks run in parallel / by dependency, instead of doing everything yourself in one go.

When to output a plan:
- The task needs multiple steps, research/search across several areas, or a summarized report -> output a plan;
- A simple task (doable in one sentence) -> just do it directly, do not output a plan.

Plan format (output exactly one @@FENCE@@json code block, then stop and wait for the plan to finish executing):
{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "plan name",
  "goal": "goal description",
  "concurrency": 8,
  "default_max_attempts": 3,
  "tasks": [
    { "id": "t1", "title": "subtask title", "prompt": "complete, self-contained instruction", "depends_on": [], "preset": "Simple", "max_attempts": 3 }
  ]
}
Rules:
- The top level MUST include "type": "alayaface-plan" (without it the framework will not recognize the plan)
- Field names must be spelled exactly as in the schema above (depends_on, concurrency, max_attempts, ...) — a misspelled or extra field makes the whole plan be rejected; do not invent fields
- ids are globally unique; prompts are self-contained by default; if a downstream task needs an upstream task's output, reference it in the prompt with {{t1.output}} (the framework replaces it with that upstream task's final output once it completes; you may only reference tasks already declared as dependencies — never reference tasks outside the dependency graph)
- Tasks that can run in parallel must not depend on each other
- Set "preset" on EVERY task: "Simple" for light, one-sentence subtasks; "Complex" for heavy reasoning, multi-step or research subtasks. Both presets have models configured
- For risky tasks involving commands, restrict the tool set with the tools field (e.g. read-only tools)
- Even if a task needs no decomposition (doable in one sentence), still output a plan (a single task is fine) — that is your output format
- After outputting the plan: stop, wait for the plan to finish and its result to come back, then continue your answer based on the result`

// CreatePresetDefaults seeds a new preset's config with built-in
// defaults. Both seed presets carry a settings.conf with their
// system_prompt (see seedSystemPrompt).
//
// Presets are seeded as EMPTY shells: model.conf, runtime.conf and
// themes/ are auto-created by alayacore on first use (verified against
// the real binary — an empty config dir starts clean and alayacore
// writes a working local-Ollama default model). Only AlayaFace-owned
// settings.conf is written here.
func CreatePresetDefaults(dir, name string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	conf := seedSettingsConf(name)
	if conf == "" {
		return fmt.Errorf("Cannot build settings.conf for %s", name)
	}
	return os.WriteFile(filepath.Join(dir, "settings.conf"), []byte(conf), 0o644)
}

// copyDirExcluding recursively copies a directory, skipping any files
// whose names are in exclude.
func copyDirExcluding(src, dst string, exclude []string) error {
	if err := os.MkdirAll(dst, 0o755); err != nil {
		return err
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		return err
	}
	for _, e := range entries {
		name := e.Name()
		if !e.IsDir() && contains(exclude, name) {
			continue
		}
		srcPath := filepath.Join(src, name)
		dstPath := filepath.Join(dst, name)
		if e.IsDir() {
			if err := copyDirExcluding(srcPath, dstPath, exclude); err != nil {
				return err
			}
		} else {
			data, err := os.ReadFile(srcPath)
			if err != nil {
				return err
			}
			if err := os.WriteFile(dstPath, data, 0o644); err != nil {
				return err
			}
		}
	}
	return nil
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
