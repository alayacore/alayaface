// Package dirs manages the ~/.alayaface/ directory structure.
//
//	~/.alayaface/
//	  active-preset        — name of the currently active preset
//	  presets/
//	    <name>/            — one config directory per preset
//	      model.conf
//	      runtime.conf
//	      mcp.conf
//	      settings.conf    — AlayaFace-owned (tool_confirm etc.); NOT copied into sessions
//	      themes/
//	  sessions/
//	    <uuid>/
//	      config/          — copy of the active preset's config (minus settings.conf)
//	      session.alaya
//
// Port of src-tauri/src/dirs.rs.
package dirs

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Default model config template (key-value block format).
const DefaultModelConf = `name: "Placeholder"
protocol_type: "openai"
base_url: "https://api.openai.com/v1"
api_key: ""
model_name: "gpt-4o"
context_limit: 128000
max_tokens: 4096
`

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

// ActivePresetFile returns the file recording the active preset name.
func ActivePresetFile() string {
	return filepath.Join(AlayafaceDir(), "active-preset")
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

// ReadActivePreset reads the active preset name. Errors if the marker
// is missing/invalid.
func ReadActivePreset() (string, error) {
	text, err := os.ReadFile(ActivePresetFile())
	if err != nil {
		return "", err
	}
	name := strings.TrimSpace(string(text))
	if !ValidPresetName(name) {
		return "", os.ErrInvalid
	}
	return name, nil
}

// WriteActivePreset persists the active preset name (atomic: temp + rename).
func WriteActivePreset(name string) error {
	if !ValidPresetName(name) {
		return os.ErrInvalid
	}
	path := ActivePresetFile()
	tmp := filepath.Join(AlayafaceDir(), "active-preset.tmp")
	if err := os.WriteFile(tmp, []byte(name), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ActiveConfigDir returns the config directory of the active preset.
func ActiveConfigDir() (string, error) {
	name, err := ReadActivePreset()
	if err != nil {
		return "", err
	}
	return PresetDir(name), nil
}

// ResolveConfigDir resolves the config dir for a preset name.
// Empty/whitespace means the active preset. Errors for unknown presets
// or invalid names.
func ResolveConfigDir(preset string) (string, error) {
	if strings.TrimSpace(preset) == "" {
		configDir, _, err := Ensure()
		if err != nil {
			return "", err
		}
		return configDir, nil
	}
	name := strings.TrimSpace(preset)
	if !ValidPresetName(name) {
		return "", os.ErrInvalid
	}
	dir := PresetDir(name)
	if _, err := os.Stat(dir); err != nil {
		return "", os.ErrNotExist
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
// On first run, seeds a `Default` preset and marks it active.
// Returns (activeConfigDir, sessionsDir).
func Ensure() (string, string, error) {
	base := AlayafaceDir()
	presets := PresetsRoot()
	sessions := filepath.Join(base, "sessions")

	for _, d := range []string{presets, sessions} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return "", "", err
		}
	}

	if _, err := os.Stat(ActivePresetFile()); err != nil {
		defaultDir := filepath.Join(presets, "Default")
		if _, err := os.Stat(defaultDir); err != nil {
			if err := CreatePresetDefaults(defaultDir); err != nil {
				return "", "", err
			}
		}
		if err := WriteActivePreset("Default"); err != nil {
			return "", "", err
		}
	}

	active, err := ReadActivePreset()
	if err != nil {
		return "", "", err
	}
	return PresetDir(active), sessions, nil
}

// CreateSessionDir creates a session directory with a copy of the active
// preset's config. The session.alaya file itself is created by alayacore
// when the session starts. settings.conf is AlayaFace-owned and
// intentionally NOT copied into sessions.
func CreateSessionDir(sessionsDir, uuid string) (string, error) {
	if _, _, err := Ensure(); err != nil {
		return "", err
	}
	sessionDir := filepath.Join(sessionsDir, uuid)
	dstConfig := filepath.Join(sessionDir, "config")
	template, err := ActiveConfigDir()
	if err != nil {
		return "", err
	}
	if err := copyDirExcluding(template, dstConfig, []string{"settings.conf"}); err != nil {
		return "", err
	}
	return sessionDir, nil
}

// ClonePresetDir recursively copies a whole preset directory (including
// settings.conf) — used when cloning the active preset to create a new one.
func ClonePresetDir(src, dst string) error {
	return copyDirExcluding(src, dst, nil)
}

// CreatePresetDefaults seeds a new preset's config with built-in defaults.
func CreatePresetDefaults(dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "model.conf"), []byte(DefaultModelConf), 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "runtime.conf"), []byte("{}"), 0o644); err != nil {
		return err
	}
	return os.MkdirAll(filepath.Join(dir, "themes"), 0o755)
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
