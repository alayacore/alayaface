package session

import (
	"encoding/json"
	"sync"
)

// ModelCache is a shared model list cache, populated from `model_list`
// SM messages. Shared across all sessions (port of Rust ModelCache).
//
// Waiters (ListModels) sleep on the notification channel instead of
// polling: Set broadcasts by closing + replacing the channel, so a
// waiter can never miss a model list that arrived before it started
// waiting (WaitCh re-checks under the same lock as Set's write).
type ModelCache struct {
	mu       sync.Mutex
	models   []json.RawMessage
	notifyCh chan struct{}
}

// NewModelCache creates an empty cache.
func NewModelCache() *ModelCache {
	return &ModelCache{notifyCh: make(chan struct{})}
}

// Get returns a copy of the cached models.
func (c *ModelCache) Get() []json.RawMessage {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]json.RawMessage, len(c.models))
	copy(out, c.models)
	return out
}

// Set replaces the cached models and wakes every waiter.
func (c *ModelCache) Set(models []json.RawMessage) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.models = append([]json.RawMessage(nil), models...)
	close(c.notifyCh)
	c.notifyCh = make(chan struct{})
}

// IsEmpty reports whether the cache has no models.
func (c *ModelCache) IsEmpty() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.models) == 0
}

// WaitCh returns a channel that is closed once the cache holds models.
// A non-empty cache yields an already-closed channel; an empty one
// yields the live notification channel — checked under the same lock
// as Set, so a model list that arrived just before the call is never
// missed (the wait returns immediately).
func (c *ModelCache) WaitCh() <-chan struct{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	if len(c.models) > 0 {
		ch := make(chan struct{})
		close(ch)
		return ch
	}
	return c.notifyCh
}
