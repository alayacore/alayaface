package session

import (
	"encoding/json"
	"sync"
)

// ModelCache is a shared model list cache, populated from `model_list`
// SM messages. Shared across all sessions (port of Rust ModelCache).
type ModelCache struct {
	mu     sync.Mutex
	models []json.RawMessage
}

// NewModelCache creates an empty cache.
func NewModelCache() *ModelCache { return &ModelCache{} }

// Get returns a copy of the cached models.
func (c *ModelCache) Get() []json.RawMessage {
	c.mu.Lock()
	defer c.mu.Unlock()
	out := make([]json.RawMessage, len(c.models))
	copy(out, c.models)
	return out
}

// Set replaces the cached models.
func (c *ModelCache) Set(models []json.RawMessage) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.models = append([]json.RawMessage(nil), models...)
}

// IsEmpty reports whether the cache has no models.
func (c *ModelCache) IsEmpty() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.models) == 0
}
