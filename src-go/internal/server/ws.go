package server

import (
	"log"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

// writeTimeout bounds a single WebSocket write. Without it a client
// that stops reading (frozen tab) would block the write pump forever
// (gorilla WriteMessage blocks on a full TCP buffer), which combined
// with the hub's drop-on-full behavior is what "cut off" sessions: the
// client is dropped, the socket closes, and the frontend reconnects
// with no replay of the frames emitted while disconnected. With the
// deadline the socket is closed deterministically and the frontend's
// reconnect keeps the connection healthy.
const writeTimeout = 60 * time.Second

// handleWS upgrades GET /ws and pumps hub events to the client.
//
// Server → client: {type, payload} text messages (tlv-delta,
// tlv-frame, core-status). Client → server: only control frames
// (ping/pong/close); the read loop exists to detect disconnects.
func (s *Server) handleWS(w http.ResponseWriter, r *http.Request) {
	if s.Token != "" && r.URL.Query().Get("token") != s.Token {
		writeRPCError(w, &rpcError{status: http.StatusUnauthorized, msg: "unauthorized"})
		return
	}

	conn, err := s.upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Printf("[ws] upgrade failed: %v", err)
		return
	}

	c := s.Hub.NewClient()
	s.Hub.Register(c)
	log.Printf("[ws] client connected")

	// Write pump: drain the client's send channel. When the channel is
	// closed (Unregister, or the hub dropping a slow client), close the
	// connection so the read pump unblocks and this handler exits. A
	// per-write deadline prevents a frozen (non-reading) client from
	// blocking the pump forever.
	writeDone := make(chan struct{})
	go func() {
		defer close(writeDone)
		for msg := range c.Chan() {
			_ = conn.SetWriteDeadline(time.Now().Add(writeTimeout))
			if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
				break
			}
		}
		_ = conn.Close()
	}()

	// Read pump: detect client close; also answer pings.
	conn.SetReadLimit(4096)
	conn.SetPongHandler(func(string) error { return nil })
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			break
		}
	}

	// Cleanup: unregister (closes send chan → write pump exits),
	// then wait for the write pump.
	s.Hub.Unregister(c)
	<-writeDone
	log.Printf("[ws] client disconnected")
}
