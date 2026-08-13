package core

import (
	"bufio"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
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
	// (per-plan isolation). fakecore reports its cwd in the startup SM
	// frame, so we can assert it end-to-end.
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
	frame, err := tlv.ReadFrame(reader)
	if err != nil || frame == nil {
		t.Fatalf("read startup frame: %v", err)
	}
	var env struct {
		Data struct {
			Cwd string `json:"cwd"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(frame.Value), &env); err != nil {
		t.Fatalf("bad SM payload %q: %v", frame.Value, err)
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
