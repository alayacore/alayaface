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
// If builtinTools is non-empty, passes --builtin-tools=<list> (empty =
// don't pass the flag = alayacore default: all tools).
// If systemPrompt is non-empty, passes --system=<text> (appended to the
// default system prompt; used by Plan Sessions).
// If workDir is non-empty, the child's working directory is set to it
// (per-plan isolation for Plan Mode nodes; empty = inherit the backend's
// cwd, the pre-isolation behavior).
// stderr is inherited so alayacore's own logs reach the terminal.
func Spawn(binaryPath, configPath, sessionPath, toolConfirm, builtinTools, systemPrompt, workDir string) (*CoreProcess, error) {
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
	if builtinTools != "" {
		args = append(args, "--builtin-tools="+builtinTools)
	}
	if systemPrompt != "" {
		args = append(args, "--system="+systemPrompt)
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
//  1. ALAYACORE_BIN environment variable
//  2. which alayacore (Unix) or where alayacore (Windows)
//  3. Known relative/absolute paths
//  4. Fallback to "alayacore" (assume in PATH)
func FindBinary() string {
	// 1. Check env var
	if bin := os.Getenv("ALAYACORE_BIN"); bin != "" {
		if _, err := os.Stat(bin); err == nil {
			return bin
		}
	}

	// 2. Try `which` (Unix) or `where` (Windows)
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

	// 3. Check common locations
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

	// 4. Fallback
	return "alayacore"
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
