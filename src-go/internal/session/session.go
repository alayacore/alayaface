// Package session manages AlayaCore sessions.
//
// Each session corresponds to one `alayacore --rawio` subprocess.
// Port of src-tauri/src/session.rs.
package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"

	"alayaface/src-go/internal/core"
	"alayaface/src-go/internal/hub"
	"alayaface/src-go/internal/tlv"
)

// ErrNotFound is returned when a session id is not in the manager.
// Message matches the Rust backend exactly ("Session not found").
var ErrNotFound = errors.New("Session not found")

// Session is a running alayacore session handle.
type Session struct {
	ID         string
	Stdin      io.WriteCloser
	Stdout     io.ReadCloser // owned by the reader goroutine
	Child      *exec.Cmd
	SessionDir string
	// Owner is the client identity that created/resumed this session
	// (empty = legacy/unknown). close_all_sessions reclaims only the
	// caller's own sessions, so one browser tab's page load never kills
	// another tab's live sessions (the Go backend is reachable from
	// multiple clients over LAN/SSH).
	Owner string

	stdinMu   sync.Mutex
	connected atomic.Bool
	// killOnce guarantees the child is killed/reaped exactly once even
	// when Close and the reader goroutine's EOF path race.
	killOnce sync.Once
	// PendingCmds maps call ID → command name (CI sent, CO not yet
	// received). The reader attaches the command name to CO frames,
	// since CO carries only the call ID. Bounded (FIFO eviction beyond
	// maxPendingCmds) so an unanswered CO cannot leak forever.
	PendingCmds *pendingCmds
}

// kill reaps the child process exactly once (idempotent).
func (s *Session) kill() {
	s.killOnce.Do(func() { core.KillChild(s.Child) })
}

// Connected reports whether the session's stdout pipe is still open.
func (s *Session) Connected() bool { return s.connected.Load() }

// setConnected stores the connection flag.
func (s *Session) setConnected(v bool) { s.connected.Store(v) }

// Manager is a shared map of session id → Session.
type Manager struct {
	mu       sync.Mutex
	sessions map[string]*Session
}

// NewManager creates an empty session manager.
func NewManager() *Manager {
	return &Manager{sessions: make(map[string]*Session)}
}

// Get returns a session by id.
func (m *Manager) Get(id string) (*Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	if !ok {
		return nil, ErrNotFound
	}
	return s, nil
}

// Insert registers a session.
func (m *Manager) Insert(s *Session) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.sessions[s.ID] = s
}

// Remove deletes a session from the map and returns it.
func (m *Manager) Remove(id string) (*Session, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.sessions[id]
	if ok {
		delete(m.sessions, id)
	}
	return s, ok
}

// Len returns the number of active sessions.
func (m *Manager) Len() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.sessions)
}

// ForEach iterates over a snapshot of sessions, stopping early if fn
// returns true.
func (m *Manager) ForEach(fn func(*Session) bool) {
	m.mu.Lock()
	items := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		items = append(items, s)
	}
	m.mu.Unlock()
	for _, s := range items {
		if fn(s) {
			return
		}
	}
}

// takeAll removes every session from the map and returns them. The
// caller owns their teardown.
func (m *Manager) takeAll() []*Session {
	m.mu.Lock()
	defer m.mu.Unlock()
	items := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		items = append(items, s)
	}
	m.sessions = make(map[string]*Session)
	return items
}

// CloseAll kills every session (used on server shutdown). Runs the
// per-session teardown in parallel so N sessions cost one grace period,
// not N × grace period.
func (m *Manager) CloseAll() {
	items := m.takeAll()
	var wg sync.WaitGroup
	for _, s := range items {
		wg.Add(1)
		go func(s *Session) {
			defer wg.Done()
			s.kill()
		}(s)
	}
	wg.Wait()
}

// CloseAllGracefully closes every active session with the same
// cancel-first graceful sequence as Close (cancel → save → EOF → grace
// → SIGKILL). The frontend calls this once on page load so sessions
// orphaned by a page refresh (their windows are gone but the backend
// still holds the handles) are reclaimed — otherwise resume_session
// keeps failing with "Session is already active" until the backend is
// restarted. History is preserved up to each session's cancel point.
// Runs the per-session sequence in parallel (bounded by one grace
// period regardless of session count).
func (m *Manager) CloseAllGracefully() {
	m.CloseAllGracefullyFor("")
}

// CloseAllGracefullyFor closes the sessions owned by `owner` (empty =
// all). The frontend passes its per-page clientId so a page refresh
// reclaims only ITS orphaned sessions — with the Go backend reachable
// from multiple clients (LAN/SSH port forwarding), an unconditional
// close-all on every page load would kill the other clients' live
// sessions.
func (m *Manager) CloseAllGracefullyFor(owner string) {
	var items []*Session
	m.mu.Lock()
	for _, s := range m.sessions {
		if owner == "" || s.Owner == owner {
			items = append(items, s)
			delete(m.sessions, s.ID)
		}
	}
	m.mu.Unlock()
	var wg sync.WaitGroup
	for _, s := range items {
		wg.Add(1)
		go func(s *Session) {
			defer wg.Done()
			s.closeGracefully()
			log.Printf("[session] closed %s", s.ID)
		}(s)
	}
	wg.Wait()
}

// CreateConfig configures a new session.
type CreateConfig struct {
	ID          string // also names the session dir
	Binary      string
	ConfigPath  string
	SessionFile string
	SessionDir  string
	ToolConfirm string
	// BuiltinTools: nil = don't pass --builtin-tools (all tools);
	// pointer to "" = explicitly no builtin tools (Plan Sessions);
	// pointer to a list = those tools only.
	BuiltinTools *string
	SystemPrompt string
	// ReasoningLevel is the session's initial reasoning level (0|1|2),
	// passed to alayacore as --reasoning-level=<n>.
	ReasoningLevel int
	WorkDir        string // child cwd (per-plan isolation; "" = backend cwd)
	// Owner is the client identity that created the session (empty =
	// legacy). Used by close_all_sessions to reclaim only one client's
	// orphaned sessions.
	Owner string
}

// Create spawns alayacore, registers the session, and starts the stdout
// reader. The session is fully registered and the reader running before
// Create returns (same ordering as Rust), so onStatus cannot arrive
// before onSessionCreated on the client.
func (m *Manager) Create(cfg CreateConfig, h *hub.Hub, cache *ModelCache) (*Session, error) {
	proc, err := core.Spawn(cfg.Binary, cfg.ConfigPath, cfg.SessionFile, cfg.ToolConfirm, cfg.BuiltinTools, cfg.SystemPrompt, cfg.ReasoningLevel, cfg.WorkDir)
	if err != nil {
		return nil, fmt.Errorf("Failed to start alayacore: %w", err)
	}

	s := &Session{
		ID:          cfg.ID,
		Stdin:       proc.Stdin,
		Stdout:      proc.Stdout,
		Child:       proc.Cmd,
		SessionDir:  cfg.SessionDir,
		Owner:       cfg.Owner,
		PendingCmds: newPendingCmds(),
	}
	s.setConnected(true)

	m.Insert(s)

	// Broadcast connected:true BEFORE starting the stdout reader. If the
	// child dies instantly (bad args, missing binary, ...), the reader
	// immediately observes EOF and broadcasts connected:false — with the
	// old ordering (reader first) the false could arrive before the true,
	// leaving the client believing a dead session is connected.
	h.Broadcast(hub.NewEvent("core-status", StatusEvent{
		SessionID: s.ID,
		Connected: true,
		Message:   fmt.Sprintf("Connected to alayacore (%s)", cfg.Binary),
	}))

	s.startReader(h, cache)
	log.Printf("[session] created %s (dir %s)", s.ID, cfg.SessionDir)
	return s, nil
}

// gracefulCloseTimeout is how long close_session waits for alayacore to
// exit after the cancel-first sequence (cancel → save → EOF) before
// SIGKILLing it. Mirrors alayacore::GRACEFUL_CLOSE_TIMEOUT (Rust).
const gracefulCloseTimeout = 5 * time.Second

// Close removes the session from the map and closes it cancel-first:
// CI "cancel" (aborts the running task, auto-saving up to the cancel
// point) → CI "save" → close stdin (EOF → exits immediately) → SIGKILL
// only after the grace period.
func (m *Manager) Close(id string) error {
	s, ok := m.Remove(id)
	if !ok {
		return ErrNotFound
	}
	s.closeGracefully()
	log.Printf("[session] closed %s", id)
	return nil
}

// closeGracefully runs the cancel-first shutdown sequence for one session.
//
//  1. CI `cancel` — aborts the running task (alayacore cancels its
//     per-task context; the task completes through handleTaskDone, which
//     AUTO-SAVES the conversation up to the cancel point). Best-effort:
//     nothing to cancel / dead child produce an error that is ignored.
//  2. CI `save` — persist the conversation (best-effort).
//  3. EOF: close the stdin pipe. With the task canceled (or none),
//     alayacore exits immediately — it no longer drains a long-running
//     task to completion (cancel-first means Stop/closing a window
//     never waits for a task to finish, and history is kept up to the
//     cancel point instead of being lost to SIGKILL).
//  4. Wait for the natural exit, SIGKILL after the grace period.
//
// It does NOT call cmd.Wait() itself: reaping is owned by the reader's
// disconnect path (killOnce → core.KillChild), which fires exactly when
// the child's stdout closes — i.e. when the child exits on its own. So
// we only poll Connected() to learn the child has gone. Calling Wait
// here would race with that path (os/exec forbids concurrent Waits).
func (s *Session) closeGracefully() {
	// The whole cancel → save → EOF sequence runs under the stdin lock
	// so a concurrent SendPrompt/WriteFrames can neither interleave
	// between the CI frames nor be mid-write when the pipe closes
	// (which would leave a partial TLV frame on the wire).
	s.stdinMu.Lock()
	// 1. Cancel the active task first (fire-and-forget — no CO wait;
	//    errors ignored).
	_, _ = s.sendCmdLocked("cancel", "")
	// 2. Ask alayacore to persist the conversation (best-effort: a dead
	//    child produces a write error, which is ignored).
	_, _ = s.sendCmdLocked("save", "")
	// 3. EOF: close the stdin pipe. With no active task (canceled), the
	//    child exits immediately.
	_ = s.Stdin.Close()
	s.stdinMu.Unlock()
	// 4. Wait for the reader to observe the natural exit (stdout EOF →
	//    disconnect → killOnce reaps the child).
	deadline := time.Now().Add(gracefulCloseTimeout)
	for s.Connected() {
		if time.Now().After(deadline) {
			// 5. Fallback: SIGKILL (killOnce also reaps; idempotent if
			//    the reader already killed).
			s.kill()
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// WriteFrame sends a raw TLV frame to the session's stdin.
func (s *Session) WriteFrame(tag, value string) error {
	return s.WriteFrames([]tlv.Frame{{Tag: tag, Value: value}})
}

// WriteFrames sends a batch of TLV frames under a single stdin lock.
// Used for multi-frame messages (e.g. media + text + UE flush) so a
// concurrent CI command cannot interleave between frames — mirrors the
// Rust send_prompt which holds the stdin lock for the whole sequence.
func (s *Session) WriteFrames(frames []tlv.Frame) error {
	if !s.Connected() {
		return errors.New("Session is disconnected")
	}
	s.stdinMu.Lock()
	defer s.stdinMu.Unlock()
	for _, f := range frames {
		if err := tlv.WriteFrame(s.Stdin, f.Tag, f.Value); err != nil {
			return fmt.Errorf("write error: %w", err)
		}
		preview := f.Value
		if len(preview) > 200 {
			preview = preview[:200]
		}
		log.Printf("[tlv] >> %s %s %db %s", s.ID, f.Tag, len(f.Value), preview)
	}
	return nil
}

// SendCmd sends a CI (command input) frame and returns the generated call ID.
func (s *Session) SendCmd(name, input string) (string, error) {
	s.stdinMu.Lock()
	defer s.stdinMu.Unlock()
	return s.sendCmdLocked(name, input)
}

// sendCmdLocked sends a CI frame while stdinMu is held. The call ID →
// name mapping is registered BEFORE the frame is written — the CO reply
// can arrive as soon as the CI frame is flushed.
func (s *Session) sendCmdLocked(name, input string) (string, error) {
	id := uuid.NewString()
	s.PendingCmds.Store(id, name)
	payload, err := json.Marshal(tlv.CmdMsg{ID: id, Name: name, Input: input})
	if err != nil {
		return "", err
	}
	if err := tlv.WriteFrame(s.Stdin, tlv.TagCmdInput, string(payload)); err != nil {
		s.PendingCmds.Delete(id)
		return "", err
	}
	preview := payload
	if len(preview) > 200 {
		preview = preview[:200]
	}
	log.Printf("[tlv] >> %s %s %db %s", s.ID, tlv.TagCmdInput, len(payload), preview)
	return id, nil
}
