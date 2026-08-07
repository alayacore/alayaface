package server

import (
	"bufio"
	"net"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// shortenWSKeepalive shrinks the ping/pong windows for a test and
// restores them afterwards. Safe under -race (atomic stores).
func shortenWSKeepalive(t *testing.T) {
	t.Helper()
	oldPong, oldPing, oldWrite := wsPongWait.Load(), wsPingPeriod.Load(), wsWriteTimeout.Load()
	wsPongWait.Store(int64(400 * time.Millisecond))
	wsPingPeriod.Store(int64(100 * time.Millisecond))
	wsWriteTimeout.Store(int64(500 * time.Millisecond))
	t.Cleanup(func() {
		wsPongWait.Store(oldPong)
		wsPingPeriod.Store(oldPing)
		wsWriteTimeout.Store(oldWrite)
	})
}

// rawWSUpgrade opens a raw TCP connection to /ws and completes the
// WebSocket handshake manually, returning the connection. The caller
// controls the socket completely — no automatic pongs (unlike the
// gorilla dialer), which is exactly what a zombie client looks like.
func rawWSUpgrade(t *testing.T, addr string) net.Conn {
	t.Helper()
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	req := "GET /ws HTTP/1.1\r\n" +
		"Host: " + addr + "\r\n" +
		"Upgrade: websocket\r\n" +
		"Connection: Upgrade\r\n" +
		"Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" +
		"Sec-WebSocket-Version: 13\r\n\r\n"
	if _, err := conn.Write([]byte(req)); err != nil {
		t.Fatal(err)
	}
	br := bufio.NewReader(conn)
	status, err := br.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(status, "101") {
		t.Fatalf("upgrade failed: %s", status)
	}
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			t.Fatal(err)
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	return conn
}

// TestWSZombieConnectionReaped: a client that completes the handshake
// and then goes silent (never pongs — half-open TCP, laptop sleep,
// network blackhole) must be closed by the server within the pong
// window. Without the ping/pong keepalive this leaked the read-pump
// goroutine and the hub registration forever.
func TestWSZombieConnectionReaped(t *testing.T) {
	shortenWSKeepalive(t)

	s := New("", "")
	ts := httptest.NewServer(s.Routes())
	defer ts.Close()
	addr := strings.TrimPrefix(ts.URL, "http://")

	conn := rawWSUpgrade(t, addr)

	// Zombie: never respond to the server's pings. Drain whatever the
	// server sends (the ping frames themselves) until the connection is
	// closed — the read deadline (wsPongWait=400ms) must fire and the
	// server must close us. A 3s bound keeps the test from hanging if
	// the reap is broken.
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	buf := make([]byte, 256)
	for {
		if _, err := conn.Read(buf); err != nil {
			break // closed (EOF/reset) — the zombie was reaped
		}
	}
	// If we got here via the 3s read deadline instead of a close, the
	// hub assertion below still catches it (client not dropped).

	// And the hub must have dropped it.
	deadline := time.Now().Add(2 * time.Second)
	for s.Hub.Len() > 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if got := s.Hub.Len(); got != 0 {
		t.Fatalf("hub still holds %d clients after zombie reap", got)
	}
}

// TestWSAliveClientSurvivesPingPeriod: a healthy client (gorilla
// dialer, which auto-pongs each server ping) must NOT be reaped — the
// pongs keep extending the read deadline past several pong windows.
// ReadMessage never returns the pings (gorilla consumes control frames
// internally), so liveness is: the read times out (no data, still
// connected) instead of failing with a closed connection.
func TestWSAliveClientSurvivesPingPeriod(t *testing.T) {
	shortenWSKeepalive(t)

	s := New("", "")
	ts := httptest.NewServer(s.Routes())
	defer ts.Close()
	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws"

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// Read for 3s (> 7 pong windows). Each server ping is auto-ponged,
	// so the server must NOT close us; ReadMessage only returns when its
	// own 3s deadline fires (i/o timeout) — NOT with a closed-connection
	// error, which would mean the server reaped us.
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, _, err = conn.ReadMessage()
	if err == nil {
		t.Fatal("expected a read timeout (no data frames), got a message")
	}
	if !websocket.IsCloseError(err, websocket.CloseNormalClosure, websocket.CloseGoingAway) &&
		!strings.Contains(err.Error(), "use of closed network connection") &&
		!strings.Contains(err.Error(), "connection reset") {
		// i/o timeout (or similar) → the connection is still alive.
	} else {
		t.Fatalf("alive client was reaped by the server: %v", err)
	}

	if s.Hub.Len() != 1 {
		t.Fatalf("hub has %d clients, want 1 (the alive client)", s.Hub.Len())
	}
}
