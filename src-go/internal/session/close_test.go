package session

import (
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"alayaface/src-go/internal/tlv"
)

// gatedPipe is a stdin stand-in whose FIRST write blocks until released
// (holding the session's stdinMu the whole time, like a slow prompt
// send) and whose Close records when it was called. Later writes (the
// cancel/save CI frames) pass through immediately.
type gatedPipe struct {
	writeStarted chan struct{}
	releaseWrite chan struct{}
	writes       atomic.Int32

	mu       sync.Mutex
	writeEnd time.Time
	closedAt time.Time
}

func newGatedPipe() *gatedPipe {
	return &gatedPipe{
		writeStarted: make(chan struct{}),
		releaseWrite: make(chan struct{}),
	}
}

func (g *gatedPipe) Write(p []byte) (int, error) {
	if g.writes.Add(1) == 1 {
		close(g.writeStarted)
		<-g.releaseWrite
	}
	g.mu.Lock()
	g.writeEnd = time.Now()
	g.mu.Unlock()
	return len(p), nil
}

func (g *gatedPipe) Close() error {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.closedAt = time.Now()
	return nil
}

// TestCloseGracefullyClosesStdinAfterInFlightWrite: the cancel → save →
// EOF sequence must hold the stdin lock, so Stdin.Close() can never run
// while a concurrent prompt write is in flight (which would leave a
// partial TLV frame on the wire). Deterministic: the first write blocks
// while holding the lock; closeGracefully must wait for it.
func TestCloseGracefullyClosesStdinAfterInFlightWrite(t *testing.T) {
	pipe := newGatedPipe()
	s := &Session{ID: "test", Stdin: pipe, PendingCmds: newPendingCmds()}
	s.setConnected(true)

	writeDone := make(chan struct{})
	go func() {
		defer close(writeDone)
		_ = s.WriteFrames([]tlv.Frame{{Tag: tlv.TagUserText, Value: "hello"}})
	}()
	<-pipe.writeStarted // the prompt write now holds stdinMu and blocks

	closeDone := make(chan struct{})
	go func() {
		defer close(closeDone)
		s.closeGracefully()
	}()

	// The close sequence must NOT reach Stdin.Close while the prompt
	// write holds the lock.
	time.Sleep(50 * time.Millisecond)
	pipe.mu.Lock()
	closedEarly := !pipe.closedAt.IsZero()
	pipe.mu.Unlock()
	if closedEarly {
		t.Fatal("stdin was closed while a prompt write was still in flight")
	}

	// Release the write; closeGracefully then proceeds (cancel, save,
	// close) strictly AFTER the write completed.
	close(pipe.releaseWrite)
	<-writeDone

	deadline := time.Now().Add(2 * time.Second)
	for {
		pipe.mu.Lock()
		closed := !pipe.closedAt.IsZero()
		pipe.mu.Unlock()
		if closed {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("closeGracefully never closed stdin")
		}
		time.Sleep(5 * time.Millisecond)
	}

	pipe.mu.Lock()
	writeEnd := pipe.writeEnd
	closedAt := pipe.closedAt
	pipe.mu.Unlock()
	if closedAt.Before(writeEnd) {
		t.Fatalf("stdin closed at %v before the in-flight write finished at %v", closedAt, writeEnd)
	}

	// Let the grace-period poll observe the disconnect and return.
	s.setConnected(false)
	<-closeDone
}
