package session

import (
	"encoding/json"
	"sync"
)

// pendingCmds maps command ID → command name (CI sent, CO not yet
// received). Bounded: if a CO reply never arrives (protocol anomaly /
// killed core), an entry must not grow the map forever — Store evicts
// the OLDEST entries beyond the cap (FIFO). Mirrors the Rust
// session::PendingCommands guard (M5/D6).
const maxPendingCmds = 512

type pendingCmds struct {
	mu    sync.Mutex
	m     map[string]string
	order []string // insertion order (FIFO eviction)

	// waiters are command IDs whose SENDER is blocked on the answer. Used by
	// SendCmdWait (the model write RPC waits on `model_load`'s CO); kept apart
	// from the id→name map because only a few commands ask for it. The
	// reader resolves (and removes) an entry as the CO arrives.
	waiters map[string]chan json.RawMessage
}

func newPendingCmds() *pendingCmds {
	return &pendingCmds{
		m:       make(map[string]string),
		waiters: make(map[string]chan json.RawMessage),
	}
}

// Waiter registers a buffered channel that Resolve will receive the CO on.
// Call it BEFORE writing the CI frame: the answer can arrive as soon as the
// frame is flushed.
func (p *pendingCmds) Waiter(id string) chan json.RawMessage {
	ch := make(chan json.RawMessage, 1)
	p.mu.Lock()
	p.waiters[id] = ch
	p.mu.Unlock()
	return ch
}

// DropWaiter removes a waiter that will never be resolved (write failed,
// timeout).
func (p *pendingCmds) DropWaiter(id string) {
	p.mu.Lock()
	delete(p.waiters, id)
	p.mu.Unlock()
}

// Resolve hands the CO body to a waiting sender, if any, and forgets the
// waiter. Non-blocking: the channel is buffered (1), and a sender that already
// timed out has removed its entry.
func (p *pendingCmds) Resolve(id string, raw json.RawMessage) {
	p.mu.Lock()
	ch, ok := p.waiters[id]
	if ok {
		delete(p.waiters, id)
	}
	p.mu.Unlock()
	if ok {
		select {
		case ch <- raw:
		default:
		}
	}
}

// Store records id → name, evicting the oldest entries beyond the cap.
func (p *pendingCmds) Store(id, name string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, ok := p.m[id]; !ok {
		p.order = append(p.order, id)
	}
	p.m[id] = name
	for len(p.order) > maxPendingCmds {
		old := p.order[0]
		p.order = p.order[1:]
		delete(p.m, old)
	}
}

// LoadAndDelete removes and returns the name for id.
func (p *pendingCmds) LoadAndDelete(id string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	v, ok := p.m[id]
	if !ok {
		return "", false
	}
	delete(p.m, id)
	p.removeOrderLocked(id)
	return v, true
}

// Load returns the name for id without removing it.
func (p *pendingCmds) Load(id string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	v, ok := p.m[id]
	return v, ok
}

// Delete removes id (no-op when absent).
func (p *pendingCmds) Delete(id string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, ok := p.m[id]; !ok {
		return
	}
	delete(p.m, id)
	p.removeOrderLocked(id)
}

// Len returns the number of pending entries.
func (p *pendingCmds) Len() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.m)
}

func (p *pendingCmds) removeOrderLocked(id string) {
	for i, x := range p.order {
		if x == id {
			p.order = append(p.order[:i], p.order[i+1:]...)
			return
		}
	}
}
