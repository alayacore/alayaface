// Package core manages the AlayaCore subprocess.
//
// Spawns `alayacore --rawio` as a child process and provides access to
// its stdin/stdout for TLV communication. Port of src-tauri/src/alayacore.rs.
package core

import (
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"time"
)

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

// KillChild closes the child's stdin (EOF), waits up to 3s for a natural
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
