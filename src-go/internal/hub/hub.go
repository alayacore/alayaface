// Package hub implements the WebSocket event bus.
//
// All AlayaCore stdout frames (and connection status changes) are
// broadcast to every connected client as {type, payload} messages,
// mirroring the Tauri event system (tlv-delta / tlv-frame / core-status).
package hub

import (
	"encoding/json"
	"sync"
)

// sendBuffer is the per-client outbound queue size. It must absorb the
// largest burst alayacore can flush at once (a task completing dumps
// thousands of TLV frames — reasoning deltas, tool results, the final
// answer — in a few hundred milliseconds). If it is too small the hub
// drops the client, the WebSocket closes, and the frontend reconnects
// WITHOUT a replay: the frames emitted while disconnected are lost and
// the session looks "cut off" while the alayacore process keeps running
// to completion. 16384 frames (a few MB) covers any realistic burst.
const sendBuffer = 16384

// Event is a server→client push message.
type Event struct {
	Type    string          `json:"type"`
	Payload json.RawMessage `json:"payload"`
}

// NewEvent builds an Event from a typed payload.
func NewEvent(typ string, payload any) Event {
	raw, err := json.Marshal(payload)
	if err != nil {
		// Payloads are internal structs; marshaling cannot fail in practice.
		raw = json.RawMessage(`null`)
	}
	return Event{Type: typ, Payload: raw}
}

// Client is a single WebSocket connection. send is a buffered channel
// drained by the connection's write goroutine; Broadcast never blocks.
type Client struct {
	hub  *Hub
	send chan []byte
}

// NewClient creates a client bound to the hub with a send buffer.
func (h *Hub) NewClient() *Client {
	return &Client{hub: h, send: make(chan []byte, sendBuffer)}
}

// Chan returns the client's outbound message channel (drained by the
// connection's write goroutine). The channel is closed on Unregister.
func (c *Client) Chan() <-chan []byte { return c.send }

// Hub fans out events to all connected clients.
type Hub struct {
	mu      sync.Mutex
	clients map[*Client]struct{}
}

// New creates an empty hub.
func New() *Hub {
	return &Hub{clients: make(map[*Client]struct{})}
}

// Len returns the number of connected clients.
func (h *Hub) Len() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// Register adds a client and starts its write loop.
func (h *Hub) Register(c *Client) {
	h.mu.Lock()
	h.clients[c] = struct{}{}
	h.mu.Unlock()
}

// Unregister removes a client and closes its send channel.
// The caller is responsible for closing the underlying connection.
func (h *Hub) Unregister(c *Client) {
	h.mu.Lock()
	if _, ok := h.clients[c]; ok {
		delete(h.clients, c)
		close(c.send)
	}
	h.mu.Unlock()
}

// Broadcast marshals the event and queues it on every client.
// Clients with a full send buffer are dropped (slow consumer).
func (h *Hub) Broadcast(ev Event) {
	raw, err := json.Marshal(ev)
	if err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	for c := range h.clients {
		select {
		case c.send <- raw:
		default:
			// Slow client: drop it to avoid blocking the session readers.
			delete(h.clients, c)
			close(c.send)
		}
	}
}
