package session

import "sync"

// pendingCmds maps call ID → command name (CI sent, CO not yet
// received). Bounded: if a CO reply never arrives (protocol anomaly /
// killed core), an entry must not grow the map forever — Store evicts
// the OLDEST entries beyond the cap (FIFO). Mirrors the Rust
// session::PendingCommands guard (M5/D6).
const maxPendingCmds = 512

type pendingCmds struct {
	mu    sync.Mutex
	m     map[string]string
	order []string // insertion order (FIFO eviction)
}

func newPendingCmds() *pendingCmds {
	return &pendingCmds{m: make(map[string]string)}
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
