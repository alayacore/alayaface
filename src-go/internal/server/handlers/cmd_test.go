package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"alayaface/src-go/internal/core"
)

// writeFakeAlayacore emits a configurable `message_version` followed
// by enough SM frames to look like a running core. The probe in
// CheckAlayacore reads the FIRST frame and then kills the process.
// Python with an absolute shebang (not /usr/bin/env python3) so the
// script runs even when the test has stripped PATH to a directory
// that doesn't contain python3 (env would refuse to resolve it).
func writeFakeAlayacore(t *testing.T, dir string, messageVersion int) string {
	t.Helper()
	payload := `{"type":"version","data":{"message_version":` +
		itoa(messageVersion) + `,"core_version":"fake"}}`
	script := `#!/usr/bin/python3
import struct, sys, time
payload = ` + jsonString(payload) + `.encode()
sys.stdout.buffer.write(b"SM")
sys.stdout.buffer.write(struct.pack(">I", len(payload)))
sys.stdout.buffer.write(payload)
sys.stdout.flush()
while True:
    time.sleep(1)
`
	bin := filepath.Join(dir, "alayacore")
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

// jsonString returns s quoted with the JSON quoting rules Python's
// repr() applies to a string literal (so the embedded payload string
// in the script parses correctly).
func jsonString(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

// itoa is a tiny int-to-string converter so the generated Python
// script stays compact without importing strconv.
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	if neg {
		digits = append([]byte{'-'}, digits...)
	}
	return string(digits)
}

// CheckAlayacore must resolve a real binary on disk and report ok=true
// with the discovered path. The fake binary announces the supported
// protocol version — without that the new version check rejects it
// (a wrong-version binary is treated like a missing one).
func TestCheckAlayacoreFindsBinaryFromEnv(t *testing.T) {
	bin := writeFakeAlayacore(t, t.TempDir(), core.SupportedMessageVersion)
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

// CheckAlayacore must reject a binary that announces a mismatching
// protocol version. The home-screen banner surfaces the same
// `ok=false` UX as the missing-binary case, but the error names the
// version mismatch so the user knows to upgrade alayacore (not fix
// their PATH / ALAYACORE_BIN).
func TestCheckAlayacoreWrongVersion(t *testing.T) {
	bin := writeFakeAlayacore(t, t.TempDir(), core.SupportedMessageVersion-1)
	t.Setenv("ALAYACORE_BIN", bin)
	// Strip PATH so `which alayacore` cannot resolve to a real
	// binary on the test host — the env-var must win. The Python
	// shebang is absolute (`/usr/bin/python3`), so the stripped
	// PATH doesn't break the script launcher.
	t.Setenv("PATH", t.TempDir())

	rr := call(t, CheckAlayacore, map[string]any{})
	if rr.Code != 200 {
		t.Fatalf("status = %d, body %s", rr.Code, rr.Body.String())
	}
	var got AlayacoreCheck
	if err := json.Unmarshal(rr.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.OK {
		t.Errorf("OK = true on a wrong-version binary; error = %q", got.Error)
	}
	if !strings.Contains(got.Error, "message version") {
		t.Errorf("error must mention the protocol version: %q", got.Error)
	}
	if !strings.Contains(got.Error, "upgrade") {
		t.Errorf("error must tell the user what to do: %q", got.Error)
	}
}
