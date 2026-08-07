package handlers

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
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
		BinaryPath      string  `json:"binaryPath"`
		ConfigPath      string  `json:"configPath"`
		ToolConfirm     *string `json:"toolConfirm"`
		Preset          *string `json:"preset"`
		BuiltinTools    *string `json:"builtinTools"`
		SystemPrompt    *string `json:"systemPrompt"`
		WorkDir         *string `json:"workDir"`
		PlanID          *string `json:"planId"`
		NodeID          *string `json:"nodeId"`
		OriginSessionID *string `json:"originSessionId"`
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
	presetName := ""
	if args.Preset != nil {
		presetName = *args.Preset
	}
	// Plan node sessions live NESTED under
	// sessions/<originSessionId>/plans/<planId>/<nodeId>/ — every plan
	// belongs to the session that created it, and the sessions/ top
	// level only ever contains plain sessions. Plain sessions stay at
	// sessions/<uuid>/.
	var sessionDir string
	if args.PlanID != nil && strings.TrimSpace(*args.PlanID) != "" {
		originID := ""
		if args.OriginSessionID != nil {
			originID = *args.OriginSessionID
		}
		nodeID := ""
		if args.NodeID != nil {
			nodeID = *args.NodeID
		}
		sessionDir, err = dirs.CreatePlanSessionDirFrom(sessionsDir, originID, *args.PlanID, nodeID, id, presetName)
	} else {
		sessionDir, err = dirs.CreateSessionDirFrom(sessionsDir, id, presetName)
	}
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
	// Builtin tools: an EXPLICIT override wins — including an explicit
	// empty string, which means NO builtin tools (alayacore treats
	// `--builtin-tools=` as an empty list; Plan Sessions use this so the
	// planner physically cannot execute tools). Unspecified = the active
	// preset's builtin_tools; an empty effective value means don't pass
	// the flag = all tools.
	var bt *string
	if args.BuiltinTools != nil {
		v := *args.BuiltinTools
		bt = &v
	} else {
		if eff, err := effectiveBuiltinTools(); err != nil {
			log.Printf("[settings] builtin-tools unavailable, spawning without it: %v", err)
		} else if eff != "" {
			bt = &eff
		}
	}
	sp := ""
	if args.SystemPrompt != nil {
		sp = *args.SystemPrompt
	}
	// Optional per-plan working directory (Plan Mode node sessions):
	// created if needed, and the child is spawned with it as cwd.
	wd := ""
	if args.WorkDir != nil && strings.TrimSpace(*args.WorkDir) != "" {
		wd = *args.WorkDir
		if err := os.MkdirAll(wd, 0o755); err != nil {
			return fmt.Errorf("Cannot create work dir %s: %w", wd, err)
		}
	}
	log.Printf("Spawning: %s --rawio --config-path %s --session %s", bin, effectiveConfig, sessionFile)
	if tc != "" {
		log.Printf("  with --tool-confirm=%s", tc)
	}
	if bt != nil {
		label := *bt
		if label == "" {
			label = "<none>"
		}
		log.Printf("  with --builtin-tools=%s", label)
	}
	if sp != "" {
		log.Printf("  with --system (%d chars)", len(sp))
	}
	if presetName != "" {
		log.Printf("  preset=%s", presetName)
	}
	if wd != "" {
		log.Printf("  work_dir=%s", wd)
	}

	s, err := h.Sessions.Create(session.CreateConfig{
		ID:           id,
		Binary:       bin,
		ConfigPath:   effectiveConfig,
		SessionFile:  sessionFile,
		SessionDir:   sessionDir,
		ToolConfirm:  tc,
		BuiltinTools: bt,
		SystemPrompt: sp,
		WorkDir:      wd,
	}, h.Hub, h.Cache)
	if err != nil {
		return err
	}
	return writeResult(w, s.ID)
}

// resolveSessionDir locates an on-disk session directory by trying the
// current and legacy layouts in order:
//  1. sessions/<originSessionId>/plans/<planId>/<nodeId>/<sessionId>  (P28: plan under its session)
//  2. sessions/<planId>/<nodeId>/<sessionId>                          (P27: plan-keyed top-level subtrees)
//  3. sessions/<sessionId>                                            (flat, pre-hierarchy)
// The first path that exists wins; "" components are skipped.
func resolveSessionDir(sessionsRoot, originSessionId, planId, nodeId, sessionId string) string {
	if strings.TrimSpace(originSessionId) != "" && strings.TrimSpace(planId) != "" {
		d := filepath.Join(
			sessionsRoot,
			dirs.SanitizeDirComponent(originSessionId),
			"plans",
			dirs.SanitizeDirComponent(planId),
			dirs.SanitizeDirComponent(nodeId),
			sessionId,
		)
		if _, err := os.Stat(d); err == nil {
			return d
		}
	}
	if strings.TrimSpace(planId) != "" {
		d := filepath.Join(
			sessionsRoot,
			dirs.SanitizeDirComponent(planId),
			dirs.SanitizeDirComponent(nodeId),
			sessionId,
		)
		if _, err := os.Stat(d); err == nil {
			return d
		}
	}
	return filepath.Join(sessionsRoot, sessionId)
}

// ResumeSession resumes an on-disk session directory.
func ResumeSession(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SessionID       string  `json:"sessionId"`
		BinaryPath      string  `json:"binaryPath"`
		WorkDir         *string `json:"workDir"`
		PlanID          *string `json:"planId"`
		NodeID          *string `json:"nodeId"`
		OriginSessionID *string `json:"originSessionId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	sessionsRoot := filepath.Join(dirs.AlayafaceDir(), "sessions")
	// Plan node sessions are nested under the plan's owning session; the
	// frontend passes originSessionId/planId/nodeId so resume finds the
	// on-disk dir even though the session id alone is only unique per
	// plan. resolveSessionDir falls back to older layouts for sessions
	// created before this change.
	originID := ""
	if args.OriginSessionID != nil {
		originID = *args.OriginSessionID
	}
	planID := ""
	if args.PlanID != nil {
		planID = *args.PlanID
	}
	nodeID := ""
	if args.NodeID != nil {
		nodeID = *args.NodeID
	}
	sessionsDir := resolveSessionDir(sessionsRoot, originID, planID, nodeID, args.SessionID)
	sessionFile := filepath.Join(sessionsDir, "session.alaya")
	configDir := filepath.Join(sessionsDir, "config")

	// Message texts match Rust resume_session.
	if _, err := os.Stat(sessionsDir); err != nil {
		return fmt.Errorf("Session directory not found: %s", sessionsDir)
	}
	if _, err := os.Stat(sessionFile); err != nil {
		return fmt.Errorf("Session file not found: %s", sessionFile)
	}
	if _, err := os.Stat(configDir); err != nil {
		return fmt.Errorf("Config directory not found: %s", configDir)
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
		return fmt.Errorf("Session is already active")
	}

	bin := ResolveBinary(args.BinaryPath)
	// Resumed plan-node sessions keep the plan's working directory.
	wd := ""
	if args.WorkDir != nil && strings.TrimSpace(*args.WorkDir) != "" {
		wd = *args.WorkDir
		if err := os.MkdirAll(wd, 0o755); err != nil {
			return fmt.Errorf("Cannot create work dir %s: %w", wd, err)
		}
	}
	s, err := h.Sessions.Create(session.CreateConfig{
		ID:          uuid.NewString(),
		Binary:      bin,
		ConfigPath:  configDir,
		SessionFile: sessionFile,
		SessionDir:  sessionsDir,
		ToolConfirm: "",
		WorkDir:     wd,
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
		// ONLY top-level session dirs are listed. Plan Mode nests its
		// node sessions under sessions/<planId>/<nodeId>/ (which contain
		// no session.alaya at the top level), so the manager never shows
		// plan child sessions — a top-level entry is guaranteed not to be
		// a plan's child session.
		if _, err := os.Stat(filepath.Join(path, "session.alaya")); err != nil {
			continue
		}
		// Sort key: modification time (matches Rust's sort by
		// metadata.modified()). created_at mirrors Rust's
		// metadata.created() (birth time) where available.
		mod := fi.ModTime()
		created := dirs.FileBirthTime(fi)
		items = append(items, item{
			info: SessionDirInfo{
				ID:             e.Name(),
				HasSessionFile: true,
				CreatedAt:      fmt.Sprintf("%d", created.Unix()),
			},
			mod: mod,
		})
	}
	// Newest first (Rust sorts by modified, reversed).
	sort.Slice(items, func(i, j int) bool { return items[i].mod.After(items[j].mod) })
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
		SessionID       string  `json:"sessionId"`
		PlanID          *string `json:"planId"`
		NodeID          *string `json:"nodeId"`
		OriginSessionID *string `json:"originSessionId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	_ = h.Sessions.Close(args.SessionID)
	sessionsRoot := filepath.Join(dirs.AlayafaceDir(), "sessions")
	// Plan node sessions are nested; originSessionId/planId/nodeId locate
	// them (resolveSessionDir also tries the older layouts).
	originID := ""
	if args.OriginSessionID != nil {
		originID = *args.OriginSessionID
	}
	planID := ""
	if args.PlanID != nil {
		planID = *args.PlanID
	}
	nodeID := ""
	if args.NodeID != nil {
		nodeID = *args.NodeID
	}
	sessionDir := resolveSessionDir(sessionsRoot, originID, planID, nodeID, args.SessionID)
	if _, err := os.Stat(sessionDir); err == nil {
		if err := os.RemoveAll(sessionDir); err != nil {
			return fmt.Errorf("Cannot delete %s: %w", sessionDir, err)
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
			return fmt.Errorf("Timeout waiting for fork to complete")
		}
		time.Sleep(50 * time.Millisecond)
	}
}
