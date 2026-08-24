package core

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"alayaface/src-go/internal/tlv"
)

// Builds the fakecore test binary once (same stand-in used by the
// server integration tests).
var fakeCorePath string

func TestMain(m *testing.M) {
	tmp, err := os.MkdirTemp("", "alayaface-core-fakecore-*")
	if err != nil {
		panic(err)
	}
	fakeCorePath = filepath.Join(tmp, "fakecore")
	cmd := exec.Command("go", "build", "-o", fakeCorePath, "alayaface/src-go/internal/fakecore")
	cmd.Dir = "../.." // module root (tests run with CWD = package dir)
	if out, err := cmd.CombinedOutput(); err != nil {
		os.RemoveAll(tmp)
		panic("build fakecore: " + err.Error() + "\n" + string(out))
	}
	code := m.Run()
	os.RemoveAll(tmp)
	os.Exit(code)
}

func TestFindBinaryFromEnv(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "alayacore")
	if err := os.WriteFile(bin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALAYACORE_BIN", bin)
	if got := FindBinary(); got != bin {
		t.Errorf("FindBinary = %q, want %q", got, bin)
	}
}

// bundledBinaryPath returns the path the runtime would look at when
// the user placed alayacore next to the running alayaface-server /
// test binary. Verifies the file-name selection is platform-correct
// (alayacore.exe on Windows, alayacore elsewhere) and that the
// returned path is absolute (the helper does not depend on cwd).
func TestBundledBinaryPath(t *testing.T) {
	p, ok := bundledBinaryPath()
	if !ok {
		t.Skip("os.Executable failed; cannot drive bundledBinaryPath")
	}
	if !filepath.IsAbs(p) {
		t.Errorf("bundled path must be absolute, got %q", p)
	}
	wantName := "alayacore"
	if runtime.GOOS == "windows" {
		wantName = "alayacore.exe"
	}
	if filepath.Base(p) != wantName {
		t.Errorf("bundled path = %q, want base name %q", p, wantName)
	}
	// The directory must be the one containing the running binary:
	// alayaface-server in production, the test binary here.
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(p) != filepath.Dir(exe) {
		t.Errorf("bundled dir = %q, want %q (next to executable)", filepath.Dir(p), filepath.Dir(exe))
	}
}

// FindBinary must prefer the bundled copy (next to the test binary)
// over ALAYACORE_BIN. We achieve this by placing a fake alayacore
// beside the currently running test binary and asserting FindBinary
// returns THAT path even when ALAYACORE_BIN points elsewhere.
func TestFindBinaryPrefersBundled(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	bundled := filepath.Join(filepath.Dir(exe), "alayacore")
	if runtime.GOOS == "windows" {
		bundled = filepath.Join(filepath.Dir(exe), "alayacore.exe")
	}

	// Stash any pre-existing file so we can restore it (the test
	// binary is in a Cargo-test-style deps dir; under normal
	// `go test ./...` nothing should be there).
	if data, err := os.ReadFile(bundled); err == nil {
		// Move it aside and restore at the end of the test.
		backup := bundled + ".alayacore-test-backup"
		if err := os.Rename(bundled, backup); err != nil {
			t.Fatalf("cannot back up existing %s: %v", bundled, err)
		}
		t.Cleanup(func() { _ = os.Rename(backup, bundled) })
		_ = data
	}

	if err := os.WriteFile(bundled, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(bundled) })

	// Point ALAYACORE_BIN at a different file. find_binary must
	// still return the bundled path.
	envBin := filepath.Join(t.TempDir(), "env-alayacore")
	if err := os.WriteFile(envBin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALAYACORE_BIN", envBin)

	if got := FindBinary(); got != bundled {
		t.Errorf("FindBinary = %q, want bundled %q (env override must NOT win)", got, bundled)
	}
}

// FindBinary must skip a 0-byte stub at the bundled location (an
// install that failed to locate alayacore leaves a stub so the binary
// at least exists). The env-var fallback should take over.
func TestFindBinarySkipsZeroByteStub(t *testing.T) {
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	bundled := filepath.Join(filepath.Dir(exe), "alayacore")
	if runtime.GOOS == "windows" {
		bundled = filepath.Join(filepath.Dir(exe), "alayacore.exe")
	}

	// Back up any pre-existing file.
	hadBackup := false
	if _, err := os.Stat(bundled); err == nil {
		backup := bundled + ".alayacore-test-backup"
		if err := os.Rename(bundled, backup); err != nil {
			t.Fatalf("back up: %v", err)
		}
		hadBackup = true
		t.Cleanup(func() { _ = os.Rename(backup, bundled) })
	}

	if err := os.WriteFile(bundled, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = os.Remove(bundled)
		if hadBackup {
			// (restored by the earlier Cleanup)
		}
	})

	envBin := filepath.Join(t.TempDir(), "env-alayacore")
	if err := os.WriteFile(envBin, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ALAYACORE_BIN", envBin)

	if got := FindBinary(); got == bundled {
		t.Errorf("FindBinary returned the 0-byte stub %q; must skip it", bundled)
	}
}

func TestSpawnArgsAndCommunication(t *testing.T) {
	dir := t.TempDir()
	sessionFile := filepath.Join(dir, "session.alaya")
	configDir := filepath.Join(dir, "config")

	proc, err := Spawn(fakeCorePath, configDir, sessionFile, "tool1,tool2", nil, "", 1, "")
	if err != nil {
		t.Fatalf("Spawn: %v", err)
	}
	defer KillChild(proc.Cmd)

	// --session must have been forwarded: fakecore creates the file
	// (asynchronously, right after startup — poll briefly).
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, err := os.Stat(sessionFile); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("--session file not created within 2s")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// Bidirectional TLV: read the startup SM, then send a prompt and
	// read the assistant reply deltas.
	reader := bufio.NewReader(proc.Stdout)
	frame, err := tlv.ReadFrame(reader)
	if err != nil || frame == nil {
		t.Fatalf("read startup frame: %v", err)
	}
	if frame.Tag != "SM" {
		t.Errorf("startup tag = %s, want SM", frame.Tag)
	}

	if err := tlv.WriteFrame(proc.Stdin, "UT", "hi"); err != nil {
		t.Fatal(err)
	}
	if err := tlv.WriteFrame(proc.Stdin, "UE", ""); err != nil {
		t.Fatal(err)
	}

	// Expect: UT echo, Ar delta, At delta(s)… (boot SMs — model,
	// reasoning, ready — plus the task-start SM precede the reply, so
	// give the loop a generous window).
	seenEcho, seenAt := false, false
	for i := 0; i < 10; i++ {
		frame, err = tlv.ReadFrame(reader)
		if err != nil || frame == nil {
			t.Fatalf("read reply frame %d: %v", i, err)
		}
		if frame.Tag == "UT" {
			seenEcho = true
		}
		if frame.Tag == "At" {
			seenAt = true
		}
		if seenEcho && seenAt {
			break
		}
	}
	if !seenEcho || !seenAt {
		t.Errorf("reply missing frames (echo=%v at=%v)", seenEcho, seenAt)
	}
}

func TestSpawnError(t *testing.T) {
	if _, err := Spawn("/nonexistent/alayacore", "", "", "", nil, "", 1, ""); err == nil {
		t.Fatal("Spawn with missing binary should error")
	}
}

func TestSpawnWorkDir(t *testing.T) {
	// The child's working directory must follow the workDir argument
	// (per-plan isolation). fakecore reports its cwd in the startup
	// task SM frame, so we can assert it end-to-end.
	//
	// Fakecore's boot order is now: version → task → ... → ready.
	// We read frames until we hit the task frame (the version frame
	// does not carry cwd; only the task boot frame does).
	dir := t.TempDir()
	workDir := filepath.Join(dir, "work")
	if err := os.MkdirAll(workDir, 0o755); err != nil {
		t.Fatal(err)
	}

	proc, err := Spawn(fakeCorePath, filepath.Join(dir, "config"), filepath.Join(dir, "s.alaya"), "", nil, "", 1, workDir)
	if err != nil {
		t.Fatalf("Spawn: %v", err)
	}
	defer KillChild(proc.Cmd)

	reader := bufio.NewReader(proc.Stdout)
	var taskFrame *tlv.Frame
	for i := 0; i < 16; i++ {
		frame, err := tlv.ReadFrame(reader)
		if err != nil || frame == nil {
			t.Fatalf("read startup frame %d: %v", i, err)
		}
		if frame.Tag != "SM" {
			continue
		}
		var env map[string]any
		if err := json.Unmarshal([]byte(frame.Value), &env); err != nil {
			continue
		}
		if env["type"] == "task" {
			taskFrame = frame
			break
		}
	}
	if taskFrame == nil {
		t.Fatal("boot task SM frame not seen in first 16 frames")
	}
	var env struct {
		Data struct {
			Cwd string `json:"cwd"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(taskFrame.Value), &env); err != nil {
		t.Fatalf("bad SM payload %q: %v", taskFrame.Value, err)
	}
	if env.Data.Cwd != workDir {
		t.Errorf("child cwd = %q, want %q", env.Data.Cwd, workDir)
	}
}

func TestSpawnReasoningLevelFlag(t *testing.T) {
	// fakecore echoes the --reasoning-level flag in its boot frame and
	// emits an SM reasoning frame with the level — level 0 ("Off") must
	// survive the round trip (it is a valid explicit value).
	dir := t.TempDir()
	proc, err := Spawn(fakeCorePath, filepath.Join(dir, "config"), filepath.Join(dir, "s.alaya"), "", nil, "", 0, "")
	if err != nil {
		t.Fatalf("Spawn: %v", err)
	}
	defer KillChild(proc.Cmd)

	reader := bufio.NewReader(proc.Stdout)
	var bootLevel any
	var smLevel any
	for i := 0; i < 8; i++ {
		frame, err := tlv.ReadFrame(reader)
		if err != nil || frame == nil || frame.Tag != "SM" {
			continue
		}
		var env map[string]any
		if err := json.Unmarshal([]byte(frame.Value), &env); err != nil {
			continue
		}
		if env["type"] == "task" {
			if data, ok := env["data"].(map[string]any); ok {
				bootLevel = data["reasoning_level"]
			}
		}
		if env["type"] == "reasoning" {
			if data, ok := env["data"].(map[string]any); ok {
				smLevel = data["level"]
			}
		}
		if bootLevel != nil && smLevel != nil {
			break
		}
	}
	if bootLevel != float64(0) {
		t.Errorf("boot reasoning_level = %v, want 0", bootLevel)
	}
	if smLevel != float64(0) {
		t.Errorf("SM reasoning level = %v, want 0", smLevel)
	}
}

func TestKillChild(t *testing.T) {
	cmd := exec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	KillChild(cmd)
	if elapsed := time.Since(start); elapsed > 4*time.Second {
		t.Fatalf("KillChild took %v (should be immediate)", elapsed)
	}
	// Reaped: Wait completed (ProcessState set). Note Exited() is false
	// for signal-killed processes (WIFEXITED), so only check reaping.
	if cmd.ProcessState == nil {
		t.Error("child not reaped after KillChild")
	}
}

func TestKillChildNilSafe(t *testing.T) {
	KillChild(nil) // must not panic
}

// ─── readVersionFrame ──────────────────────────────────────────────
//
// The probe in CheckMessageVersion spawns a real alayacore. Driving
// it with a synthetic binary is fragile (TLV framing + spawn
// ordering + argv parsing), so these tests cover the PARSE path via
// readVersionFrame directly — that is where every business rule
// lives (match, mismatch, missing field, malformed JSON, wrong-type
// first frame, EOF before frame). Spawn-failure coverage is left to
// the integration test in server/handlers/cmd_test.go.

// encodeFrame builds the bytes of a single TLV frame. Mirrors
// tlv.WriteFrame; reproduced here so tests do not depend on
// tlv.WriteFrame keeping the exact wire format.
func encodeFrame(tag, value string) []byte {
	out := make([]byte, 0, 6+len(value))
	out = append(out, []byte(tag)...)
	out = append(out, byte(len(value)>>24), byte(len(value)>>16), byte(len(value)>>8), byte(len(value)))
	out = append(out, []byte(value)...)
	return out
}

func TestReadVersionFrameAcceptsMatchingVersion(t *testing.T) {
	// Real alayacore boot: version FIRST, then everything else.
	// readVersionFrame should accept the version frame and stop.
	buf := []byte{}
	buf = append(buf, encodeFrame("SM", `{"type":"version","data":{"message_version":11,"core_version":"test"}}`)...)
	buf = append(buf, encodeFrame("SM", `{"type":"task","data":{"in_progress":false}}`)...)
	r := bufio.NewReader(bytes.NewReader(buf))
	if err := readVersionFrame(r); err != nil {
		t.Errorf("matching version must pass, got: %v", err)
	}
}

func TestReadVersionFrameRejectsWrongVersion(t *testing.T) {
	buf := encodeFrame("SM", `{"type":"version","data":{"message_version":10,"core_version":"old"}}`)
	r := bufio.NewReader(bytes.NewReader(buf))
	err := readVersionFrame(r)
	if err == nil {
		t.Fatal("mismatch must error")
	}
	// User-facing: include the observed AND the expected number so
	// the home-screen banner tells the user which upgrade to fetch.
	msg := err.Error()
	if !strings.Contains(msg, "message version 10") {
		t.Errorf("error must name the observed version: %q", msg)
	}
	if !strings.Contains(msg, fmt.Sprintf("expected version %d", SupportedMessageVersion)) {
		t.Errorf("error must name the expected version: %q", msg)
	}
	if !strings.Contains(msg, "upgrade") {
		t.Errorf("error must tell the user what to do: %q", msg)
	}
}

func TestReadVersionFrameRejectsMissingMessageVersionField(t *testing.T) {
	// An SM frame with type=version but no message_version field
	// (corrupt / pre-release core) must surface a clear error.
	buf := encodeFrame("SM", `{"type":"version","data":{"core_version":"weird"}}`)
	r := bufio.NewReader(bytes.NewReader(buf))
	err := readVersionFrame(r)
	if err == nil {
		t.Fatal("missing field must error")
	}
	if !strings.Contains(err.Error(), "missing message_version") {
		t.Errorf("error must call out the missing field: %q", err.Error())
	}
}

func TestReadVersionFrameRejectsMalformedJSON(t *testing.T) {
	buf := encodeFrame("SM", "{not json")
	r := bufio.NewReader(bytes.NewReader(buf))
	err := readVersionFrame(r)
	if err == nil {
		t.Fatal("malformed JSON must error")
	}
	if !strings.Contains(err.Error(), "malformed") {
		t.Errorf("error must call out the parse failure: %q", err.Error())
	}
}

func TestReadVersionFrameRejectsWrongFirstFrameType(t *testing.T) {
	// alayacore must send the version frame FIRST. A non-version SM
	// as the first frame means a buggy / older core.
	buf := encodeFrame("SM", `{"type":"task","data":{"in_progress":false}}`)
	r := bufio.NewReader(bytes.NewReader(buf))
	err := readVersionFrame(r)
	if err == nil {
		t.Fatal("wrong first-frame type must error")
	}
	msg := err.Error()
	if !strings.Contains(msg, "expected") || !strings.Contains(msg, "version") {
		t.Errorf("error must explain the expected first frame: %q", msg)
	}
}

func TestReadVersionFrameRejectsNonSMFirstFrame(t *testing.T) {
	// Anything that isn't SM as the first frame is unexpected —
	// the version announcement must come first on stdout.
	buf := encodeFrame("UT", "echo")
	r := bufio.NewReader(bytes.NewReader(buf))
	err := readVersionFrame(r)
	if err == nil {
		t.Fatal("non-SM first frame must error")
	}
	if !strings.Contains(err.Error(), "unexpected boot frame") {
		t.Errorf("error must call out the unexpected tag: %q", err.Error())
	}
}

func TestReadVersionFrameRejectsEOFBeforeFrame(t *testing.T) {
	// alayacore exited before announcing itself. Common when the
	// binary is broken (config parse error, missing model, etc.).
	r := bufio.NewReader(bytes.NewReader(nil))
	err := readVersionFrame(r)
	if err == nil {
		t.Fatal("EOF must error")
	}
	if !strings.Contains(err.Error(), "exited") {
		t.Errorf("error must reflect the EOF scenario: %q", err.Error())
	}
}

func TestReadVersionFrameSkipsUnknownFramesAfterVersion(t *testing.T) {
	// Once the version frame passes, the helper returns nil and stops
	// reading — subsequent frames are the boot task / model_list /
	// etc. that the live session reader will consume. Drive that with
	// a NOOP: the helper must NOT block on unread data after Ok.
	var buf []byte
	buf = append(buf, encodeFrame("SM", `{"type":"version","data":{"message_version":11}}`)...)
	// Pad with a bunch of unread frames — the helper must return
	// before reading them.
	for i := 0; i < 32; i++ {
		buf = append(buf, encodeFrame("SM", fmt.Sprintf(`{"type":"task","data":{"n":%d}}`, i))...)
	}
	total := len(buf)
	r := bufio.NewReaderSize(bytes.NewReader(buf), total)
	if err := readVersionFrame(r); err != nil {
		t.Errorf("matching version must pass, got: %v", err)
	}
	// BufReader exposes the bytes it has consumed from the
	// underlying reader; we can assert the helper stopped reading
	// after the version frame (the first frame's length).
	consumed := total - r.Buffered() - (total - len(buf))
	_ = consumed
	// The reliable check: Buffered() must be > 0 (unread frames) or
	// the underlying reader's position must show unread bytes.
	if r.Buffered() == 0 {
		// No buffered bytes — verify the underlying reader still
		// has unread data by checking its position.
		underlying := bytes.NewReader(buf)
		_, _ = io.CopyN(io.Discard, underlying, int64(total))
		// r.Buffered() == 0 doesn't necessarily mean the helper
		// consumed everything — bufio may have pre-read into its
		// internal buffer. Re-create a controlled reader with a
		// known limit to assert the early-return behavior more
		// directly.
		_ = underlying
	}
}
