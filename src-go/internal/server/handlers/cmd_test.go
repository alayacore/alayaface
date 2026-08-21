package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// CheckAlayacore must resolve a real binary on disk and report ok=true
// with the discovered path. The fakeCore test binary from core_test.go
// is a stand-in for alayacore here.
func TestCheckAlayacoreFindsBinaryFromEnv(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "alayacore")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALAYACORE_BIN", bin)

	rr := call(t, CheckAlayacore, map[string]any{})
	if rr.Code != 200 {
		t.Fatalf("status = %d, body %s", rr.Code, rr.Body.String())
	}
	var got AlayacoreCheck
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if !got.OK {
		t.Errorf("OK = false, error = %q", got.Error)
	}
	if got.Path != bin {
		t.Errorf("path = %q, want %q", got.Path, bin)
	}
	if got.Error != "" {
		t.Errorf("error = %q, want empty", got.Error)
	}
}

// CheckAlayacore must surface a clear error when no binary is reachable
// at all. The error message mentions the path that was tried so the
// user can diagnose env-var / PATH / candidate-path issues.
func TestCheckAlayacoreMissingBinary(t *testing.T) {
	// Point ALAYACORE_BIN at a guaranteed-missing file. core.FindBinary
	// returns env var wins → exists check filters this path → falls
	// through to `which` / candidate paths. We can't unset `which` or
	// remove the candidate paths, but if the env var is set to a path
	// that does NOT exist AND that path is also NOT on PATH and NOT any
	// of the candidates, the fallback "alayacore" string is returned,
	// and the binary will not be stat-able in a normal test env either.
	//
	// Use a per-test HOME that doesn't contain an alayacore anywhere
	// reachable: stripped PATH so `which` fails, and cwd set to an empty
	// temp dir so the relative candidates don't resolve either.
	missing := filepath.Join(t.TempDir(), "definitely-not-alayacore")
	t.Setenv("ALAYACORE_BIN", missing)
	t.Setenv("PATH", t.TempDir()) // empty PATH, `which` returns nothing

	// The `which` fallback is shell-dependent; we also isolate the
	// working directory so the relative candidates ("alayacore",
	// "../alayacore/alayacore", "./alayacore") cannot resolve.
	origCwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(origCwd) })

	rr := call(t, CheckAlayacore, map[string]any{})
	if rr.Code != 200 {
		t.Fatalf("status = %d, body %s", rr.Code, rr.Body.String())
	}
	var got AlayacoreCheck
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.OK {
		t.Errorf("OK = true on a missing binary; path = %q", got.Path)
	}
	if got.Error == "" {
		t.Error("error is empty; expected a user-facing message")
	}
}
