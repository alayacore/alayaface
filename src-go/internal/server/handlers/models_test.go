package handlers

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadActiveModelName(t *testing.T) {
	dir := t.TempDir()

	// Missing file → not found.
	if _, ok := readActiveModelName(dir); ok {
		t.Error("missing runtime.conf must yield not-found")
	}

	// Key: value lines; active_model is a model NAME (alayacore format,
	// strings double-quoted like model.conf).
	if err := os.WriteFile(filepath.Join(dir, "runtime.conf"), []byte("active_model: \"MyModel\"\nactive_theme: dark\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	name, ok := readActiveModelName(dir)
	if !ok || name != "MyModel" {
		t.Errorf("readActiveModelName = %q, %v; want MyModel, true", name, ok)
	}
	// Unquoted values are tolerated too.
	if err := os.WriteFile(filepath.Join(dir, "runtime.conf"), []byte("active_model: MyModel\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	name, ok = readActiveModelName(dir)
	if !ok || name != "MyModel" {
		t.Errorf("readActiveModelName (unquoted) = %q, %v; want MyModel, true", name, ok)
	}

	// Comments and whitespace are tolerated; missing key → not found.
	if err := os.WriteFile(filepath.Join(dir, "runtime.conf"), []byte("# comment\nactive_theme: dark\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, ok := readActiveModelName(dir); ok {
		t.Error("runtime.conf without active_model must yield not-found")
	}

	// Empty value → not found.
	if err := os.WriteFile(filepath.Join(dir, "runtime.conf"), []byte("active_model:  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, ok := readActiveModelName(dir); ok {
		t.Error("empty active_model must yield not-found")
	}
}
