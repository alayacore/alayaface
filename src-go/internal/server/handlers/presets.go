package handlers

import (
	"fmt"
	"net/http"
	"os"
	"strings"

	"alayaface/src-go/internal/dirs"
)

// PresetInfo is the serialized preset info for the frontend.
type PresetInfo struct {
	Name   string `json:"name"`
	IsSeed bool   `json:"is_seed"`
}

// ListPresets lists all presets.
func ListPresets(h *Handler, w http.ResponseWriter, r *http.Request) error {
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	names, err := dirs.ListPresetNames()
	if err != nil {
		return err
	}
	presets := make([]PresetInfo, 0, len(names))
	for _, name := range names {
		presets = append(presets, PresetInfo{Name: name, IsSeed: dirs.IsSeedPreset(name)})
	}
	return writeJSON(w, presets)
}

// CopyPreset creates a new preset as a copy of an existing source preset.
func CopyPreset(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Source string `json:"source"`
		Name   string `json:"name"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	source, err := validatePresetName(args.Source)
	if err != nil {
		return err
	}
	name, err := validatePresetName(args.Name)
	if err != nil {
		return err
	}
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	if source == name {
		return fmt.Errorf("Source and new preset have the same name")
	}
	src := dirs.PresetDir(source)
	if _, err := os.Stat(src); err != nil {
		return fmt.Errorf("Preset not found: %s", source)
	}
	dst := dirs.PresetDir(name)
	if _, err := os.Stat(dst); err == nil {
		return fmt.Errorf("Preset already exists: %s", name)
	}
	if err := dirs.ClonePresetDir(src, dst); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// DeletePreset deletes a preset. Built-in seed presets (Simple/Complex)
// cannot be deleted (the seeded plan contract references them), and the
// last remaining preset cannot be deleted either.
func DeletePreset(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Name string `json:"name"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	name, err := validatePresetName(args.Name)
	if err != nil {
		return err
	}
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	if dirs.IsSeedPreset(name) {
		return fmt.Errorf("Cannot delete the built-in preset: %s", name)
	}
	names, err := dirs.ListPresetNames()
	if err != nil {
		return err
	}
	if len(names) <= 1 {
		return fmt.Errorf("Cannot delete the last preset")
	}
	dir := dirs.PresetDir(name)
	if _, err := os.Stat(dir); err != nil {
		return fmt.Errorf("Preset not found: %s", name)
	}
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// RenamePreset renames a preset. Built-in seed presets (Simple/Complex)
// cannot be renamed — the seeded plan contract references them by name.
func RenamePreset(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		OldName string `json:"oldName"`
		NewName string `json:"newName"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	oldName, err := validatePresetName(args.OldName)
	if err != nil {
		return err
	}
	newName, err := validatePresetName(args.NewName)
	if err != nil {
		return err
	}
	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	if dirs.IsSeedPreset(oldName) {
		return fmt.Errorf("Cannot rename the built-in preset: %s", oldName)
	}
	if oldName == newName {
		return writeResult(w, nil)
	}
	oldDir := dirs.PresetDir(oldName)
	if _, err := os.Stat(oldDir); err != nil {
		return fmt.Errorf("Preset not found: %s", oldName)
	}
	newDir := dirs.PresetDir(newName)
	if _, err := os.Stat(newDir); err == nil {
		return fmt.Errorf("Preset already exists: %s", newName)
	}
	if err := os.Rename(oldDir, newDir); err != nil {
		return err
	}
	return writeResult(w, nil)
}

func validatePresetName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if !dirs.ValidPresetName(name) {
		return "", fmt.Errorf("Invalid preset name: %q (use letters, digits, '-' or '_')", name)
	}
	return name, nil
}
