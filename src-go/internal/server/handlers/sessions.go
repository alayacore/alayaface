package handlers

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"

	"alayaface/src-go/internal/dirs"
	"alayaface/src-go/internal/session"
)

// SessionDirInfo is the serialized session directory info.
type SessionDirInfo struct {
	ID             string `json:"id"`
	HasSessionFile bool   `json:"has_session_file"`
	CreatedAt      string `json:"created_at"`
}

// CreateSession spawns a new alayacore session.
func CreateSession(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		BinaryPath  string  `json:"binaryPath"`
		ConfigPath  string  `json:"configPath"`
		ToolConfirm *string `json:"toolConfirm"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	_, sessionsDir, err := dirs.Ensure()
	if err != nil {
		return err
	}
	bin := ResolveBinary(args.BinaryPath)
	id := uuid.NewString()
	sessionDir, err := dirs.CreateSessionDir(sessionsDir, id)
	if err != nil {
		return err
	}

	effectiveConfig := args.ConfigPath
	if effectiveConfig == "" {
		effectiveConfig = filepath.Join(sessionDir, "config")
	}
	sessionFile := filepath.Join(sessionDir, "session.alaya")

	tc := ""
	if args.ToolConfirm != nil && strings.TrimSpace(*args.ToolConfirm) != "" {
		tc = *args.ToolConfirm
	} else {
		if eff, err := effectiveToolConfirm(); err != nil {
			log.Printf("[settings] tool-confirm unavailable, spawning without it: %v", err)
		} else {
			tc = eff
		}
	}
	log.Printf("Spawning: %s --rawio --config-path %s --session %s", bin, effectiveConfig, sessionFile)
	if tc != "" {
		log.Printf("  with --tool-confirm=%s", tc)
	}

	s, err := h.Sessions.Create(session.CreateConfig{
		ID:          id,
		Binary:      bin,
		ConfigPath:  effectiveConfig,
		SessionFile: sessionFile,
		SessionDir:  sessionDir,
		ToolConfirm: tc,
	}, h.Hub, h.Cache)
	if err != nil {
		return err
	}
	return writeResult(w, s.ID)
}

// ResumeSession resumes an on-disk session directory.
func ResumeSession(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID  string `json:"sessionId"`
		BinaryPath string `json:"binaryPath"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	sessionsDir := filepath.Join(dirs.AlayafaceDir(), "sessions", args.SessionID)
	sessionFile := filepath.Join(sessionsDir, "session.alaya")
	configDir := filepath.Join(sessionsDir, "config")

	for _, p := range []string{sessionsDir, sessionFile, configDir} {
		if _, err := os.Stat(p); err != nil {
			return fmt.Errorf("session path not found: %s", p)
		}
	}

	// Check not already running: resumed sessions are keyed by a fresh
	// UUID each time, so compare by directory rather than by the
	// on-disk id to catch double-resumes of the same dir.
	alreadyActive := false
	h.Sessions.ForEach(func(s *session.Session) bool {
		if s.SessionDir == sessionsDir {
			alreadyActive = true
			return true
		}
		return false
	})
	if alreadyActive {
		return fmt.Errorf("session is already active")
	}

	bin := ResolveBinary(args.BinaryPath)
	s, err := h.Sessions.Create(session.CreateConfig{
		ID:          uuid.NewString(),
		Binary:      bin,
		ConfigPath:  configDir,
		SessionFile: sessionFile,
		SessionDir:  sessionsDir,
		ToolConfirm: "",
	}, h.Hub, h.Cache)
	if err != nil {
		return err
	}
	return writeResult(w, s.ID)
}

// CloseSession kills the subprocess and removes it from the map.
func CloseSession(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	if err := h.Sessions.Close(args.SessionID); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// ListSessionDirs lists session directories, newest first.
func ListSessionDirs(h *Handler, w http.ResponseWriter, r *http.Request) error {
	sessionsDir := filepath.Join(dirs.AlayafaceDir(), "sessions")
	entries, err := os.ReadDir(sessionsDir)
	if err != nil {
		if os.IsNotExist(err) {
			return writeJSON(w, []SessionDirInfo{})
		}
		return err
	}

	type item struct {
		info SessionDirInfo
		mod  time.Time
	}
	var items []item
	for _, e := range entries {
		path := filepath.Join(sessionsDir, e.Name())
		fi, err := os.Stat(path) // follows symlinks, like Rust's path.is_dir()
		if err != nil || !fi.IsDir() {
			continue
		}
		_, err = os.Stat(filepath.Join(path, "session.alaya"))
		hasSessionFile := err == nil
		created := fi.ModTime()
		items = append(items, item{
			info: SessionDirInfo{
				ID:             e.Name(),
				HasSessionFile: hasSessionFile,
				CreatedAt:      fmt.Sprintf("%d", created.Unix()),
			},
			mod: created,
		})
	}
	// Newest first (Rust sorts by modified, reversed).
	for i := 0; i < len(items); i++ {
		for j := i + 1; j < len(items); j++ {
			if items[j].mod.After(items[i].mod) {
				items[i], items[j] = items[j], items[i]
			}
		}
	}
	result := make([]SessionDirInfo, 0, len(items))
	for _, it := range items {
		result = append(result, it.info)
	}
	return writeJSON(w, result)
}

// DeleteSessionDir closes the session (if running) and removes the
// on-disk session directory.
func DeleteSessionDir(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID string `json:"sessionId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	_ = h.Sessions.Close(args.SessionID)
	sessionDir := filepath.Join(dirs.AlayafaceDir(), "sessions", args.SessionID)
	if _, err := os.Stat(sessionDir); err == nil {
		if err := os.RemoveAll(sessionDir); err != nil {
			return err
		}
	}
	return writeResult(w, nil)
}

// ForkSession forks a running session up to a history point and starts
// the new session.
func ForkSession(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SourceSessionID string `json:"sourceSessionId"`
		HistoryID       string `json:"historyId"`
		BinaryPath      string `json:"binaryPath"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	_, sessionsDir, err := dirs.Ensure()
	if err != nil {
		return err
	}
	newID := uuid.NewString()
	newSessionDir, err := dirs.CreateSessionDir(sessionsDir, newID)
	if err != nil {
		return err
	}
	targetFile := filepath.Join(newSessionDir, "session.alaya")
	configPath := filepath.Join(newSessionDir, "config")

	log.Printf("Forking %s up to history %s → %s", args.SourceSessionID, args.HistoryID, targetFile)

	src, err := h.Sessions.Get(args.SourceSessionID)
	if err != nil {
		return err
	}
	input := fmt.Sprintf("%s %s", args.HistoryID, targetFile)
	if _, err := src.SendCmd("fork", input); err != nil {
		return err
	}

	// Wait for the session file to stabilize (size unchanged for a bit).
	if err := waitForFile(targetFile); err != nil {
		return err
	}

	bin := ResolveBinary(args.BinaryPath)
	s, err := h.Sessions.Create(session.CreateConfig{
		ID:          newID,
		Binary:      bin,
		ConfigPath:  configPath,
		SessionFile: targetFile,
		SessionDir:  newSessionDir,
		ToolConfirm: "",
	}, h.Hub, h.Cache)
	if err != nil {
		return err
	}
	return writeResult(w, s.ID)
}

// waitForFile waits for a file to stabilize (size unchanged for a short
// period), with a 5-second deadline. Port of commands/mod.rs wait_for_file.
func waitForFile(path string) error {
	deadline := time.Now().Add(5 * time.Second)
	seenSize := int64(0)
	for {
		if fi, err := os.Stat(path); err == nil {
			len := fi.Size()
			if len > 0 && len == seenSize {
				return nil
			}
			if len > 0 {
				seenSize = len
			}
		}
		if time.Now().After(deadline) {
			if seenSize > 0 {
				return nil
			}
			return fmt.Errorf("timeout waiting for fork to complete")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
