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
	ID        string `json:"id"`
	CreatedAt string `json:"created_at"`
	Preset    string `json:"preset"`
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
		ReasoningLevel  *int    `json:"reasoningLevel"`
		WorkDir         *string `json:"workDir"`
		PlanID          *string `json:"planId"`
		NodeID          *string `json:"nodeId"`
		OriginSessionID *string `json:"originSessionId"`
		ClientID        string  `json:"clientId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	sessionsDir, err := dirs.Ensure()
	if err != nil {
		return err
	}
	bin := ResolveBinary(args.BinaryPath)
	id := uuid.NewString()
	presetName := ""
	if args.Preset != nil {
		presetName = *args.Preset
	}
	// The preset is REQUIRED (there is no active preset): resolve it now
	// so a missing/unknown preset fails before any directory is created.
	if _, err := dirs.ResolveConfigDir(presetName); err != nil {
		return err
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
		if eff, err := effectiveToolConfirm(presetName); err != nil {
			log.Printf("[settings] tool-confirm unavailable, spawning without it: %v", err)
		} else {
			tc = eff
		}
	}
	// Builtin tools: an EXPLICIT override wins — including an explicit
	// empty string, which means NO builtin tools (alayacore treats
	// `--builtin-tools=` as an empty list; Plan Sessions use this so the
	// planner physically cannot execute tools). Unspecified = the
	// session's preset's builtin_tools; an empty effective value means
	// don't pass the flag = all tools.
	var bt *string
	if args.BuiltinTools != nil {
		v := *args.BuiltinTools
		bt = &v
	} else {
		if eff, err := effectiveBuiltinTools(presetName); err != nil {
			log.Printf("[settings] builtin-tools unavailable, spawning without it: %v", err)
		} else if eff != "" {
			bt = &eff
		}
	}
	// System prompt: an explicit non-empty override wins (the frontend
	// sends only the recursion guard over the plan depth limit);
	// otherwise the session's preset's system_prompt (settings.conf) is
	// used as --system.
	sp := ""
	if args.SystemPrompt != nil && strings.TrimSpace(*args.SystemPrompt) != "" {
		sp = *args.SystemPrompt
	} else {
		if eff, err := effectiveSystemPrompt(presetName); err != nil {
			log.Printf("[settings] system-prompt unavailable, spawning without it: %v", err)
		} else {
			sp = eff
		}
	}
	// Reasoning level: an explicit per-session override wins (validated
	// 0|1|2); otherwise the session's preset's reasoning_level
	// (settings.conf) is used as --reasoning-level; default 1.
	rl := 1
	if args.ReasoningLevel != nil {
		var err error
		if rl, err = NormalizeReasoningLevel(*args.ReasoningLevel); err != nil {
			return err
		}
	} else {
		if eff, err := effectiveReasoningLevel(presetName); err != nil {
			log.Printf("[settings] reasoning-level unavailable, spawning with default: %v", err)
		} else {
			rl = eff
		}
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
	log.Printf("  with --reasoning-level=%d", rl)
	if presetName != "" {
		log.Printf("  preset=%s", presetName)
	}
	if wd != "" {
		log.Printf("  work_dir=%s", wd)
	}

	// Persist the effective spawn args so resume_session can re-apply
	// them: a resumed session must keep its capability envelope
	// (builtin-tools restriction, tool-confirm policy, preset system
	// prompt, reasoning level, work dir) — otherwise e.g. a Plan Session
	// with NO tools would come back with ALL tools after a restart. The
	// preset name is recorded too so plain forks of this session can
	// inherit it.
	if err := dirs.WriteSpawnArgs(sessionDir, dirs.SpawnArgs{
		ToolConfirm:    tc,
		BuiltinTools:   bt,
		SystemPrompt:   sp,
		ReasoningLevel: &rl,
		WorkDir:        wd,
		Preset:         presetName,
	}); err != nil {
		log.Printf("[session] warning: cannot persist spawn args for %s: %v", sessionDir, err)
	}

	s, err := h.Sessions.Create(session.CreateConfig{
		ID:             id,
		Binary:         bin,
		ConfigPath:     effectiveConfig,
		SessionFile:    sessionFile,
		SessionDir:     sessionDir,
		ToolConfirm:    tc,
		BuiltinTools:   bt,
		SystemPrompt:   sp,
		ReasoningLevel: rl,
		WorkDir:        wd,
		Owner:          args.ClientID,
	}, h.Hub, h.Cache)
	if err != nil {
		return err
	}
	return writeResult(w, s.ID)
}

// planSessionDirFor builds the on-disk path of a plan NODE session:
// <originSessionDir>/plans/<planId>/<nodeId>/<sessionId>. The frontend
// passes the owning session's REAL directory (sessions/<id> for a
// top-level session, the NESTED node-session dir for a plan child — P28:
// the sessions/ top level is never a plan child), so nested node
// sessions never leak to the top level. Plain sessions (no planId) stay
// at sessions/<sessionId>. The P28 layout is the ONLY layout — no
// legacy fallbacks.
func planSessionDirFor(sessionsRoot, originSessionDir, planId, nodeId, sessionId string) string {
	if strings.TrimSpace(planId) != "" {
		parentDir := originSessionDir
		if parentDir == "" {
			parentDir = sessionsRoot
		}
		// If parentDir is just a UUID (no separators), it's likely the originID from CreateSession.
		// In that case, we should prepend sessionsRoot.
		if parentDir != "" && !strings.Contains(parentDir, string(os.PathSeparator)) {
			parentDir = filepath.Join(sessionsRoot, parentDir)
		}
		return filepath.Join(
			parentDir,
			"plans",
			dirs.SanitizeDirComponent(planId),
			dirs.SanitizeDirComponent(nodeId),
			sessionId,
		)
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
		ClientID        string  `json:"clientId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	sessionsRoot := filepath.Join(dirs.AlayafaceDir(), "sessions")
	// Plan node sessions are nested under the plan's owning session; the
	// frontend passes originSessionId/planId/nodeId so resume finds the
	// on-disk dir even though the session id alone is only unique per
	// plan. Plain sessions (no planId) resolve at the top level.
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
	sessionsDir := planSessionDirFor(sessionsRoot, originID, planID, nodeID, args.SessionID)
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

	// Re-apply the persisted spawn args so the resumed session keeps its
	// capability envelope (builtin-tools restriction, tool-confirm
	// policy, planner prompt). A missing spawn.json = legacy session →
	// old behavior (no restrictions).
	spawn := dirs.ReadSpawnArgs(sessionsDir)

	// Resumed plan-node sessions keep the plan's working directory: an
	// explicit workDir from the frontend wins; otherwise the persisted one.
	wd := ""
	if args.WorkDir != nil && strings.TrimSpace(*args.WorkDir) != "" {
		wd = *args.WorkDir
		if err := os.MkdirAll(wd, 0o755); err != nil {
			return fmt.Errorf("Cannot create work dir %s: %w", wd, err)
		}
	} else if spawn.WorkDir != "" {
		wd = spawn.WorkDir
		if err := os.MkdirAll(wd, 0o755); err != nil {
			return fmt.Errorf("Cannot create work dir %s: %w", wd, err)
		}
	}
	log.Printf("Resuming %s with spawn args %s", sessionsDir, spawn.String())
	// Re-apply the persisted reasoning level (nil = legacy session /
	// pre-reasoning spawn.json → default 1 "Balanced").
	rl := 1
	if spawn.ReasoningLevel != nil {
		rl = *spawn.ReasoningLevel
	}
	s, err := h.Sessions.Create(session.CreateConfig{
		ID:             uuid.NewString(),
		Binary:         bin,
		ConfigPath:     configDir,
		SessionFile:    sessionFile,
		SessionDir:     sessionsDir,
		ToolConfirm:    spawn.ToolConfirm,
		BuiltinTools:   spawn.BuiltinTools,
		SystemPrompt:   spawn.SystemPrompt,
		ReasoningLevel: rl,
		WorkDir:        wd,
		Owner:          args.ClientID,
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

// CloseAllSessions gracefully closes every active session owned by the
// calling client (clientId; empty = all — legacy clients). The
// frontend calls this once on page load so sessions orphaned by a page
// refresh (their windows are gone but the backend still holds the
// handles) are reclaimed — otherwise resume_session keeps failing with
// "Session is already active" until the backend is restarted. History
// is saved up to each session's cancel point (same as close_session).
func CloseAllSessions(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		ClientID string `json:"clientId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	h.Sessions.CloseAllGracefullyFor(args.ClientID)
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
				ID:        e.Name(),
				CreatedAt: fmt.Sprintf("%d", created.Unix()),
				Preset:    dirs.ReadSpawnArgs(path).Preset,
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
	// them (plain sessions resolve at the top level).
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
	sessionDir := planSessionDirFor(sessionsRoot, originID, planID, nodeID, args.SessionID)
	// Retry the removal: the concurrent graceful close (close_session)
	// can still be flushing alayacore's save while RemoveAll traverses —
	// the save landing between readdir and rmdir makes the final rmdir
	// fail with ENOTEMPTY (or leave the dir behind), orphaning a
	// session.alaya-only ghost dir (no refs.json → invisible in the
	// session manager). The frontend sequences delete after close; this
	// loop is the backend safety net — by the retry the save is done
	// and the dir removes cleanly.
	for i := 0; i < 5; i++ {
		if _, err := os.Stat(sessionDir); err != nil {
			return writeResult(w, nil) // gone — done
		}
		err := os.RemoveAll(sessionDir)
		if err == nil {
			if _, statErr := os.Stat(sessionDir); statErr != nil {
				return writeResult(w, nil) // removed cleanly
			}
		}
		if i == 4 {
			if err != nil {
				return fmt.Errorf("Cannot delete %s: %w", sessionDir, err)
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return writeResult(w, nil)
}

// ForkSession forks a running session up to a history point and starts
// the new session. Optional plan-node args (P38): a forked plan NODE
// session lands in the SAME nested subtree as the original and keeps
// the node's config/tools/system prompt — so a cascade fork can replace
// the node session in place.
func ForkSession(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		SourceSessionID string  `json:"sourceSessionId"`
		HistoryID       string  `json:"historyId"`
		BinaryPath      string  `json:"binaryPath"`
		ToolConfirm     *string `json:"toolConfirm"`
		Preset          *string `json:"preset"`
		BuiltinTools    *string `json:"builtinTools"`
		SystemPrompt    *string `json:"systemPrompt"`
		ReasoningLevel  *int    `json:"reasoningLevel"`
		WorkDir         *string `json:"workDir"`
		PlanID          *string `json:"planId"`
		NodeID          *string `json:"nodeId"`
		OriginSessionID *string `json:"originSessionId"`
		ClientID        string  `json:"clientId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}

	sessionsDir, err := dirs.Ensure()
	if err != nil {
		return err
	}
	newID := uuid.NewString()
	presetName := ""
	if args.Preset != nil {
		presetName = *args.Preset
	}

	src, err := h.Sessions.Get(args.SourceSessionID)
	if err != nil {
		return err
	}
	// A plain fork (no explicit preset) is a work copy of the source
	// session: it inherits the source's preset (recorded in its
	// session.spawn.json) and its spawn envelope. Node forks carry an
	// explicit preset from the DAG node.
	srcArgs := dirs.ReadSpawnArgs(src.SessionDir)
	isPlainFork := presetName == ""
	if isPlainFork {
		presetName = srcArgs.Preset
		if presetName == "" {
			return fmt.Errorf("Preset is required: the source session has no recorded preset")
		}
	}
	// Resolve the preset now so a missing/unknown preset fails before
	// any directory is created.
	if _, err := dirs.ResolveConfigDir(presetName); err != nil {
		return err
	}

	var newSessionDir string
	if args.PlanID != nil && strings.TrimSpace(*args.PlanID) != "" {
		originID := ""
		if args.OriginSessionID != nil {
			originID = *args.OriginSessionID
		}
		nodeID := ""
		if args.NodeID != nil {
			nodeID = *args.NodeID
		}
		newSessionDir, err = dirs.CreatePlanSessionDirFrom(sessionsDir, originID, *args.PlanID, nodeID, newID, presetName)
	} else {
		newSessionDir, err = dirs.CreateSessionDirFrom(sessionsDir, newID, presetName)
	}
	if err != nil {
		return err
	}
	targetFile := filepath.Join(newSessionDir, "session.alaya")
	configPath := filepath.Join(newSessionDir, "config")

	log.Printf("Forking %s up to history %s → %s", args.SourceSessionID, args.HistoryID, targetFile)

	input := fmt.Sprintf("%s %s", args.HistoryID, targetFile)
	if _, err := src.SendCmd("fork", input); err != nil {
		return err
	}

	// Wait for the session file to stabilize (size unchanged for a bit).
	if err := waitForFile(targetFile); err != nil {
		return err
	}

	// Mirror create_session's optional overrides so the fork keeps the
	// node session's tool/preset/system-prompt behavior. An explicit
	// override wins; plain forks inherit the source session's spawn
	// envelope (it is a work copy); node forks resolve the node's
	// preset settings like create_session.
	tc := ""
	if args.ToolConfirm != nil && strings.TrimSpace(*args.ToolConfirm) != "" {
		tc = *args.ToolConfirm
	} else if isPlainFork {
		tc = srcArgs.ToolConfirm
	} else {
		if eff, err := effectiveToolConfirm(presetName); err != nil {
			log.Printf("[settings] tool-confirm unavailable, spawning without it: %v", err)
		} else {
			tc = eff
		}
	}
	var bt *string
	if args.BuiltinTools != nil {
		v := *args.BuiltinTools
		bt = &v
	} else if isPlainFork {
		bt = srcArgs.BuiltinTools
	} else {
		if eff, err := effectiveBuiltinTools(presetName); err != nil {
			log.Printf("[settings] builtin-tools unavailable, spawning without it: %v", err)
		} else if eff != "" {
			bt = &eff
		}
	}
	sp := ""
	if args.SystemPrompt != nil && strings.TrimSpace(*args.SystemPrompt) != "" {
		sp = *args.SystemPrompt
	} else if isPlainFork {
		sp = srcArgs.SystemPrompt
	} else {
		if eff, err := effectiveSystemPrompt(presetName); err != nil {
			log.Printf("[settings] system-prompt unavailable, spawning without it: %v", err)
		} else {
			sp = eff
		}
	}
	// Reasoning level: an explicit override wins; plain forks inherit
	// the source session's persisted level; node forks resolve the
	// node's preset setting (default 1).
	rl := 1
	switch {
	case args.ReasoningLevel != nil:
		// An explicit override is validated, not clamped: Rust's fork
		// rejects an out-of-range level with normalize_reasoning_level,
		// and Go silently re-centred it on 1 — the same request succeeded
		// on one backend and failed on the other, and the caller never
		// learned its level was ignored.
		var err error
		if rl, err = NormalizeReasoningLevel(*args.ReasoningLevel); err != nil {
			return err
		}
	case isPlainFork:
		rl = inheritedReasoningLevel(srcArgs.ReasoningLevel)
	default:
		if eff, err := effectiveReasoningLevel(presetName); err != nil {
			log.Printf("[settings] reasoning-level unavailable, spawning with default: %v", err)
		} else {
			rl = eff
		}
	}
	wd := ""
	if args.WorkDir != nil && strings.TrimSpace(*args.WorkDir) != "" {
		wd = *args.WorkDir
		if err := os.MkdirAll(wd, 0o755); err != nil {
			return fmt.Errorf("Cannot create work dir %s: %w", wd, err)
		}
	} else if isPlainFork {
		wd = srcArgs.WorkDir
	}
	// Persist the effective spawn args so resume_session re-applies them
	// (same as create_session). The preset name is recorded too so later
	// plain forks can inherit it.
	if err := dirs.WriteSpawnArgs(newSessionDir, dirs.SpawnArgs{
		ToolConfirm:    tc,
		BuiltinTools:   bt,
		SystemPrompt:   sp,
		ReasoningLevel: &rl,
		WorkDir:        wd,
		Preset:         presetName,
	}); err != nil {
		log.Printf("[session] warning: cannot persist spawn args for %s: %v", newSessionDir, err)
	}

	bin := ResolveBinary(args.BinaryPath)
	s, err := h.Sessions.Create(session.CreateConfig{
		ID:             newID,
		Binary:         bin,
		ConfigPath:     configPath,
		SessionFile:    targetFile,
		SessionDir:     newSessionDir,
		ToolConfirm:    tc,
		BuiltinTools:   bt,
		SystemPrompt:   sp,
		ReasoningLevel: rl,
		WorkDir:        wd,
		Owner:          args.ClientID,
	}, h.Hub, h.Cache)
	if err != nil {
		return err
	}
	return writeResult(w, s.ID)
}

// waitForFile waits for a file to stabilize (size unchanged for ~300ms),
// with a 10-second deadline. Port of commands/mod.rs wait_for_file.
// Requiring several consecutive unchanged polls (instead of one 50ms
// tick) prevents returning on a file that is still being written in
// chunks, and the longer deadline accommodates large session forks.
func waitForFile(path string) error {
	deadline := time.Now().Add(10 * time.Second)
	var (
		seenSize    int64
		stableTicks int
	)
	const stableWindow = 6 // 6 × 50ms ≈ 300ms of unchanged size
	for {
		if fi, err := os.Stat(path); err == nil {
			if size := fi.Size(); size > 0 {
				if size == seenSize {
					stableTicks++
					if stableTicks >= stableWindow {
						return nil
					}
				} else {
					seenSize = size
					stableTicks = 1
				}
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

// inheritedReasoningLevel maps a level persisted in session.spawn.json to an
// effective one: absent (a legacy session written before reasoning levels
// existed) or out of range (a hand-edited/corrupt file) falls back to 1,
// the same rule effectiveReasoningLevel applies to a preset setting. A
// fork must not forward a nonsense --reasoning-level to alayacore.
// Mirrors Rust's inherited_reasoning_level.
func inheritedReasoningLevel(v *int) int {
	if v == nil || *v < 0 || *v > 2 {
		return 1
	}
	return *v
}
