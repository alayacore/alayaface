// Package core manages the AlayaCore subprocess.
//
// Spawns `alayacore --rawio` as a child process and provides access to
// its stdin/stdout for TLV communication. Port of src-tauri/src/alayacore.rs.
package core

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"time"

	"alayaface/src-go/internal/tlv"
)

// SupportedMessageVersion is the alayacore TLV protocol
// `message_version` this adapter implements.
//
// alayacore announces its version as the first boot frame
// (`SM {"type":"version","data":{"message_version":N,...}}`, see
// alayacore/adapter-guide/README.md). A mismatch means the wire
// format the adapter knows about has drifted from the binary the user
// installed — silently sending prompts into a binary that parses them
// differently is worse than refusing to start, so `CheckAlayacore`
// hard-fails on mismatch with the same UX as a missing binary.
//
// Must stay in sync with src-tauri/src/alayacore.rs::SUPPORTED_MESSAGE_VERSION
// (AGENTS.md: "two backends must stay symmetric").
const SupportedMessageVersion = 11

// VersionProbeTimeout is how long CheckMessageVersion waits for the
// boot version frame before giving up. The version frame is the
// FIRST thing alayacore emits on stdout (before any
// task/model/reasoning/ready SMs and before any replayed history) —
// in practice it arrives in a few ms, so 2s is generous. Anything
// slower means the binary is hung or running a different mode;
// either way we cannot trust it.
const VersionProbeTimeout = 2 * time.Second

// CoreProcess is a spawned alayacore process with its pipes.
type CoreProcess struct {
	Cmd    *exec.Cmd
	Stdin  io.WriteCloser
	Stdout io.ReadCloser
}

// Spawn starts alayacore with --rawio and returns the process + pipes.
// If configPath is non-empty, passes --config-path <configPath>.
// If sessionPath is non-empty, passes --session <sessionPath>.
// If toolConfirm is non-empty, passes --tool-confirm=<toolConfirm>.
// If builtinTools is non-nil, passes --builtin-tools=<value> — a nil
// pointer means "don't pass the flag" (alayacore default: all tools),
// while a pointer to "" means NO builtin tools (alayacore treats an
// explicitly-empty flag as an empty list; Plan Sessions use this so the
// planner physically cannot execute tools).
// If systemPrompt is non-empty, passes --system=<text> (appended to the
// default system prompt; used by Plan Sessions).
// If reasoningLevel is in 0..2, passes --reasoning-level=<n> (AlayaCore's
// initial reasoning level for the session).
// If workDir is non-empty, the child's working directory is set to it
// (per-plan isolation for Plan Mode nodes; empty = inherit the backend's
// cwd, the pre-isolation behavior).
// stderr is inherited so alayacore's own logs reach the terminal.
func Spawn(binaryPath, configPath, sessionPath, toolConfirm string, builtinTools *string, systemPrompt string, reasoningLevel int, workDir string) (*CoreProcess, error) {
	args := []string{"--rawio"}
	if configPath != "" {
		args = append(args, "--config-path", configPath)
	}
	if sessionPath != "" {
		args = append(args, "--session", sessionPath)
	}
	if toolConfirm != "" {
		args = append(args, "--tool-confirm="+toolConfirm)
	}
	if builtinTools != nil {
		args = append(args, "--builtin-tools="+*builtinTools)
	}
	if systemPrompt != "" {
		args = append(args, "--system="+systemPrompt)
	}
	if reasoningLevel >= 0 && reasoningLevel <= 2 {
		args = append(args, "--reasoning-level="+strconv.Itoa(reasoningLevel))
	}

	cmd := exec.Command(binaryPath, args...)
	if workDir != "" {
		cmd.Dir = workDir
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, err
	}
	return &CoreProcess{Cmd: cmd, Stdin: stdin, Stdout: stdout}, nil
}

// FindBinary detects the alayacore binary.
//
// Resolution order:
//  1. Bundled binary (next to the running executable). The
//     recommended install layout is alayacore adjacent to the
//     alayaface-server binary (drop-in place beside it, no install
//     step). The bundled copy wins by default so a packaged install
//     always uses the alayacore that ships with it; ALAYACORE_BIN or
//     a PATH hit is the override path.
//  2. ALAYACORE_BIN environment variable
//  3. which alayacore (Unix) or where alayacore (Windows)
//  4. Known relative/absolute paths
//  5. Fallback to "alayacore" (assume in PATH)
func FindBinary() string {
	// 1. Bundled binary (next to the running executable). A 0-byte
	//    stub from an install that failed to find alayacore must NOT
	//    be picked up — the spawn would fail with a confusing exec
	//    error. The caller will see the env-var / PATH fallback take
	//    over instead.
	if bundled, ok := bundledBinaryPath(); ok {
		if info, err := os.Stat(bundled); err == nil && info.Size() > 0 {
			return bundled
		}
	}

	// 2. Check env var
	if bin := os.Getenv("ALAYACORE_BIN"); bin != "" {
		if _, err := os.Stat(bin); err == nil {
			return bin
		}
	}

	// 3. Try `which` (Unix) or `where` (Windows)
	whichCmd := "which"
	if runtime.GOOS == "windows" {
		whichCmd = "where"
	}
	if out, err := exec.Command(whichCmd, "alayacore").Output(); err == nil {
		line := firstLine(string(out))
		if line != "" {
			return line
		}
	}

	// 4. Check common locations
	for _, candidate := range []string{
		"alayacore",
		"../alayacore/alayacore",
		"./alayacore",
		"/usr/local/bin/alayacore",
		"/usr/bin/alayacore",
	} {
		if _, err := os.Stat(candidate); err == nil {
			abs, _ := filepath.Abs(candidate)
			return abs
		}
	}

	// 5. Fallback
	return "alayacore"
}

// bundledBinaryPath returns the path to the alayacore binary that
// would be picked up if the user placed it next to the running
// alayaface-server binary. Returns ok=false only when the executable
// path itself cannot be determined (rare; os.Executable can fail on
// some platforms). The caller MUST still stat the result.
func bundledBinaryPath() (string, bool) {
	exe, err := os.Executable()
	if err != nil {
		return "", false
	}
	binDir := filepath.Dir(exe)
	// filepath.Dir of a bare filename is "." — a relative path that
	// depends on the caller's cwd. We treat that as no bundled path
	// so the search falls back to env var / PATH.
	if binDir == "" || binDir == "." {
		return "", false
	}
	name := "alayacore"
	if runtime.GOOS == "windows" {
		name = "alayacore.exe"
	}
	return filepath.Join(binDir, name), true
}

// CheckMessageVersion spawns alayacore briefly and verifies its
// `message_version` matches SupportedMessageVersion. Used by
// CheckAlayacore to gate the home-screen banner: a wrong version is
// just as unusable as a missing binary (the wire format has drifted),
// so the same `ok=false` UX is surfaced.
//
// The probe spawns `alayacore --rawio`, reads TLV frames until
// `SM {"type":"version",...}` arrives or VersionProbeTimeout
// elapses, then kills the child. Config path / session / tools are
// irrelevant for the version announcement, so the probe uses the
// minimal flag set (no config dir, no session). stderr is discarded
// to avoid polluting the caller's terminal with probe-only logs.
//
// Error messages are user-facing (the home screen shows them
// verbatim), so they name the offending version when known.
//
// Port of src-tauri/src/alayacore.rs::check_message_version.
func CheckMessageVersion(binaryPath string) error {
	if binaryPath == "" {
		return errors.New("alayacore binary path is empty")
	}
	cmd := exec.Command(binaryPath, "--rawio")
	cmd.Stdin = nil // closed → alayacore sees EOF immediately
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return fmt.Errorf("failed to capture alayacore stdout: %w", err)
	}
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("alayacore could not be started to verify its protocol version: %w", err)
	}
	defer KillChild(cmd)

	if err := readVersionFrame(stdout); err != nil {
		return err
	}
	return nil
}

// readVersionFrame reads TLV frames from r until the boot
// `SM {"type":"version",...}` arrives or VersionProbeTimeout elapses.
// Returns nil if the version matches SupportedMessageVersion;
// otherwise an error naming the observed version (or the failure
// mode). Pulled out of CheckMessageVersion so unit tests can drive
// it with a synthetic io.Reader (a real alayacore is awkward to
// mock — its wire format requires running the actual binary).
//
// r should be the OS pipe from StdoutPipe (a *os.File on Unix). We
// use SetReadDeadline so a hung alayacore cannot block ReadFull
// forever — without it, a probe that emitted a partial frame would
// hang the loop's goroutine until KillChild fires, leaking the
// child in the worst case. The deadline is re-armed on every
// iteration so it always covers the remaining probe budget.
func readVersionFrame(r io.Reader) error {
	// Arm a read deadline so a hung alayacore can't block the read
	// loop forever. ReadFull blocks on the underlying pipe; without
	// a deadline a stuck binary would hang here until KillChild
	// fires.
	if rd, ok := r.(interface{ SetReadDeadline(time.Time) error }); ok {
		_ = rd.SetReadDeadline(time.Now().Add(VersionProbeTimeout))
	}

	reader := bufio.NewReader(r)
	for {
		// Re-arm the deadline — the previous ReadFull consumed
		// some of the budget; subsequent reads must respect the
		// remaining time.
		if rd, ok := r.(interface{ SetReadDeadline(time.Time) error }); ok {
			_ = rd.SetReadDeadline(time.Now().Add(VersionProbeTimeout))
		}

		frame, err := tlv.ReadFrame(reader)
		if err != nil {
			return fmt.Errorf("failed to read alayacore's boot frames: %w", err)
		}
		if frame == nil {
			// Clean EOF (ReadFrame returns (nil, nil) when the
			// header read is short) — alayacore exited without
			// announcing itself.
			return errors.New("alayacore exited before announcing its protocol version")
		}
		if frame.Tag != "SM" {
			// The version SM is the very first boot frame;
			// anything else arriving before it means a broken
			// core. Report what we saw so the user can
			// diagnose.
			preview := frame.Value
			if len(preview) > 120 {
				preview = preview[:120]
			}
			return fmt.Errorf("unexpected boot frame before version announcement: tag=%s, value=%s", frame.Tag, preview)
		}

		var env struct {
			Type string          `json:"type"`
			Data json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal([]byte(frame.Value), &env); err != nil {
			return fmt.Errorf("alayacore sent a malformed version frame: %w", err)
		}
		if env.Type != "version" {
			return fmt.Errorf("expected alayacore's first frame to be 'version', got '%s'", env.Type)
		}
		var data struct {
			MessageVersion *int64  `json:"message_version"`
			CoreVersion    *string `json:"core_version"`
		}
		if err := json.Unmarshal(env.Data, &data); err != nil {
			return fmt.Errorf("alayacore's version frame data is malformed: %w", err)
		}
		if data.MessageVersion == nil {
			return errors.New("alayacore's version frame is missing message_version")
		}
		if *data.MessageVersion != SupportedMessageVersion {
			return fmt.Errorf("alayacore message version %d is incompatible with expected version %d. Please upgrade alayacore.",
				*data.MessageVersion, SupportedMessageVersion)
		}
		return nil
	}
}
// exit — alayacore drains the active task (auto-saving at task end) and
// exits — then sends kill as a fallback. Safe to call from multiple
// goroutines (Wait errors are ignored).
func KillChild(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if stdin, ok := cmd.Stdin.(io.Closer); ok {
		_ = stdin.Close()
	}

	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
}

func firstLine(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' || s[i] == '\r' {
			return s[:i]
		}
	}
	return s
}
