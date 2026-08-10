package session

import (
	"encoding/json"
	"testing"
	"time"
)

// M6 (D6): wait semantics — Set wakes waiters instead of polling;
// WaitCh can never miss a model list that arrived before it was called
// (non-empty cache returns an already-closed channel).

func TestModelCacheSetWakesWaiters(t *testing.T) {
	c := NewModelCache()
	woken := make(chan struct{})
	go func() {
		<-c.WaitCh()
		close(woken)
	}()
	// Give the waiter time to grab the live notify channel.
	time.Sleep(20 * time.Millisecond)
	c.Set([]json.RawMessage{json.RawMessage(`{"id":1}`)})
	select {
	case <-woken:
	case <-time.After(time.Second):
		t.Fatal("waiter was not woken by Set")
	}
	if c.IsEmpty() {
		t.Error("cache empty after Set")
	}
}

func TestModelCacheWaitChNonEmptyReturnsImmediately(t *testing.T) {
	c := NewModelCache()
	c.Set([]json.RawMessage{json.RawMessage(`{"id":1}`)})
	select {
	case <-c.WaitCh():
	default:
		t.Fatal("WaitCh on a non-empty cache did not return immediately")
	}
}

func TestModelCacheSetReplacesAndCopies(t *testing.T) {
	c := NewModelCache()
	c.Set([]json.RawMessage{json.RawMessage(`{"id":1}`)})
	got := c.Get()
	if len(got) != 1 || string(got[0]) != `{"id":1}` {
		t.Fatalf("Get = %v", got)
	}
	// Mutating the returned copy must not affect the cache.
	got[0] = json.RawMessage(`{"id":9}`)
	if string(c.Get()[0]) != `{"id":1}` {
		t.Error("Get returned a shared slice")
	}
}

func TestModelCacheMultipleSetsKeepWaking(t *testing.T) {
	c := NewModelCache()
	c.Set([]json.RawMessage{json.RawMessage(`{"id":1}`)})
	c.Set([]json.RawMessage{json.RawMessage(`{"id":2}`)})
	// A fresh waiter after the second Set must still return immediately.
	select {
	case <-c.WaitCh():
	default:
		t.Fatal("WaitCh after multiple Sets did not return immediately")
	}
	if string(c.Get()[0]) != `{"id":2}` {
		t.Errorf("Get = %s, want the latest set", c.Get())
	}
}
