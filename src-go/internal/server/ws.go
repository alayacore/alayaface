package server

import (
	"log"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
)

// WebSocket keepalive/write timeouts, stored as atomic nanoseconds so
// tests can shorten them without racing the server's goroutines.
//
// pongWait bounds the read side: the server pings every pingPeriod, and
// a client that neither pongs nor sends anything else within pongWait is
// dead (half-open TCP: laptop asleep, network blackhole) — the read
// deadline fires and the connection is reaped. Without this, zombie
// connections leaked a goroutine + a hub registration forever (the hub
// only drops clients when it broadcasts to a full send buffer, which an
// idle zombie never triggers).
var (
	// wsPongWait is how long the server waits for a pong (or any frame)
	// before considering the connection dead.
	wsPongWait atomic.Int64
	// wsPingPeriod is the interval between server pings (must be < pongWait).
	wsPingPeriod atomic.Int64
	// wsWriteTimeout bounds a single WebSocket write. Without it a
	// client that stops reading (frozen tab) would block the write pump
	// forever (gorilla WriteMessage blocks on a full TCP buffer), which
	// combined with the hub's drop-on-full behavior is what "cut off"
	// sessions: the client is dropped, the socket closes, and the
	// frontend reconnects with no replay of the frames emitted while
	// disconnected. With the deadline the socket is closed
	// deterministically and the frontend's reconnect keeps the
	// connection healthy.
	wsWriteTimeout atomic.Int64
)

func init() {
	wsPongWait.Store(int64(60 * time.Second))
	wsPingPeriod.Store(int64(30 * time.Second))
	wsWriteTimeout.Store(int64(60 * time.Second))
}

func wsPongWaitDur() time.Duration     { return time.Duration(wsPongWait.Load()) }
func wsPingPeriodDur() time.Duration   { return time.Duration(wsPingPeriod.Load()) }
func wsWriteTimeoutDur() time.Duration { return time.Duration(wsWriteTimeout.Load()) }

// handleWS upgrades GET /ws and pumps hub events to the client.
//
// Server → client: {type, payload} text messages (tlv-delta,
// tlv-frame, core-status) plus periodic pings. Client → server: only
// control frames (ping/pong/close); the read loop exists to detect
// disconnects, with a read deadline extended by pongs so half-open
// (zombie) connections are reaped instead of leaking forever.
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

	// Pongs (and any client frame) extend the read deadline; without
	// this a live-but-idle client would be reaped as a zombie.
	conn.SetPongHandler(func(string) error {
		return conn.SetReadDeadline(time.Now().Add(wsPongWaitDur()))
	})

	// Write pump: drain the client's send channel, pinging on a ticker
	// so dead peers are discovered (their pongs stop extending the read
	// deadline). When the channel is closed (Unregister, or the hub
	// dropping a slow client), close the connection so the read pump
	// unblocks and this handler exits.
	writeDone := make(chan struct{})
	go func() {
		defer close(writeDone)
		ticker := time.NewTicker(wsPingPeriodDur())
		defer ticker.Stop()
		for {
			select {
			case msg, ok := <-c.Chan():
				_ = conn.SetWriteDeadline(time.Now().Add(wsWriteTimeoutDur()))
				if !ok {
					// Send a close frame so a well-behaved client sees
					// a clean close; ignore errors (conn may be gone).
					_ = conn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
					_ = conn.Close()
					return
				}
				if err := conn.WriteMessage(websocket.TextMessage, msg); err != nil {
					_ = conn.Close()
					return
				}
			case <-ticker.C:
				_ = conn.SetWriteDeadline(time.Now().Add(wsWriteTimeoutDur()))
				if err := conn.WriteMessage(websocket.PingMessage, nil); err != nil {
					_ = conn.Close()
					return
				}
			}
		}
	}()

	// Read pump: detect client close; also answer pings (gorilla's
	// default ping handler pongs automatically). The per-read deadline
	// reaps zombies that stop ponging.
	conn.SetReadLimit(4096)
	_ = conn.SetReadDeadline(time.Now().Add(wsPongWaitDur()))
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			break
		}
		_ = conn.SetReadDeadline(time.Now().Add(wsPongWaitDur()))
	}
	// Close the connection so a write pump blocked in WriteMessage
	// (e.g. a zombie whose TCP buffer is full) fails immediately
	// instead of waiting out wsWriteTimeout. gorilla allows Close to
	// run concurrently with an in-flight write.
	_ = conn.Close()

	// Cleanup: unregister (closes send chan → write pump exits),
	// then wait for the write pump.
	s.Hub.Unregister(c)
	<-writeDone
	log.Printf("[ws] client disconnected")
}
