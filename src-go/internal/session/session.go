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

	"github.com/google/uuid"

	"alayaface/src-go/internal/core"
	"alayaface/src-go/internal/hub"
	"alayaface/src-go/internal/tlv"
)

// ErrNotFound is returned when a session id is not in the manager.
var ErrNotFound = errors.New("session not found")

// Session is a running alayacore session handle.
type Session struct {
	ID         string
	Stdin      io.WriteCloser
	Stdout     io.ReadCloser // owned by the reader goroutine
	Child      *exec.Cmd
	SessionDir string

	stdinMu   sync.Mutex
	connected atomic.Bool
	// PendingCmds maps call ID → command name (CI sent, CO not yet
	// received). The reader attaches the command name to CO frames,
	// since CO carries only the call ID.
	PendingCmds sync.Map
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

// CloseAll kills every session (used on server shutdown).
func (m *Manager) CloseAll() {
	m.mu.Lock()
	items := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		items = append(items, s)
	}
	m.sessions = make(map[string]*Session)
	m.mu.Unlock()
	for _, s := range items {
		core.KillChild(s.Child)
	}
}

// CreateConfig configures a new session.
type CreateConfig struct {
	ID          string // also names the session dir
	Binary      string
	ConfigPath  string
	SessionFile string
	SessionDir  string
	ToolConfirm string
}

// Create spawns alayacore, registers the session, and starts the stdout
// reader. The session is fully registered and the reader running before
// Create returns (same ordering as Rust), so onStatus cannot arrive
// before onSessionCreated on the client.
func (m *Manager) Create(cfg CreateConfig, h *hub.Hub, cache *ModelCache) (*Session, error) {
	proc, err := core.Spawn(cfg.Binary, cfg.ConfigPath, cfg.SessionFile, cfg.ToolConfirm)
	if err != nil {
		return nil, fmt.Errorf("failed to start alayacore: %w", err)
	}

	s := &Session{
		ID:         cfg.ID,
		Stdin:      proc.Stdin,
		Stdout:     proc.Stdout,
		Child:      proc.Cmd,
		SessionDir: cfg.SessionDir,
	}
	s.setConnected(true)

	m.Insert(s)
	s.startReader(h, cache)

	h.Broadcast(hub.NewEvent("core-status", StatusEvent{
		SessionID: s.ID,
		Connected: true,
		Message:   fmt.Sprintf("Connected to alayacore (%s)", cfg.Binary),
	}))
	log.Printf("[session] created %s (dir %s)", s.ID, cfg.SessionDir)
	return s, nil
}

// Close kills the subprocess and removes the session from the map.
func (m *Manager) Close(id string) error {
	s, ok := m.Remove(id)
	if !ok {
		return ErrNotFound
	}
	core.KillChild(s.Child)
	log.Printf("[session] closed %s", id)
	return nil
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
		return errors.New("session is disconnected")
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
// The call ID → name mapping is registered BEFORE the frame is written —
// the CO reply can arrive as soon as the CI frame is flushed.
func (s *Session) SendCmd(name, input string) (string, error) {
	id := uuid.NewString()
	s.PendingCmds.Store(id, name)
	payload, err := json.Marshal(tlv.CmdMsg{ID: id, Name: name, Input: input})
	if err != nil {
		return "", err
	}
	if err := s.WriteFrame(tlv.TagCmdInput, string(payload)); err != nil {
		s.PendingCmds.Delete(id)
		return "", err
	}
	return id, nil
}
