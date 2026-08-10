package session

import "testing"

// M5 (D6): the pending-commands registry must stay BOUNDED — a CO
// reply that never arrives (protocol anomaly / killed core) must not
// grow the map forever. Store evicts the OLDEST entries beyond the cap
// (FIFO), so the newest calls — the ones most likely to still get a
// reply — always survive.

func TestPendingCmdsBoundedByCap(t *testing.T) {
	p := newPendingCmds()
	for i := 1; i <= maxPendingCmds+100; i++ {
		p.Store(idOf(i), "cmd")
	}
	if got := p.Len(); got != maxPendingCmds {
		t.Fatalf("Len = %d, want cap %d", got, maxPendingCmds)
	}
	// The 100 OLDEST entries were evicted; the newest survive.
	if _, ok := p.Load(idOf(1)); ok {
		t.Error("oldest entry survived the cap eviction")
	}
	if _, ok := p.Load(idOf(100)); ok {
		t.Error("entry at the eviction boundary survived")
	}
	if _, ok := p.Load(idOf(101)); !ok {
		t.Error("first surviving entry was evicted")
	}
	if _, ok := p.Load(idOf(maxPendingCmds + 100)); !ok {
		t.Error("newest entry was evicted")
	}
}

func TestPendingCmdsLoadAndDelete(t *testing.T) {
	p := newPendingCmds()
	p.Store("call-1", "model_set")
	name, ok := p.LoadAndDelete("call-1")
	if !ok || name != "model_set" {
		t.Fatalf("LoadAndDelete = (%q, %v), want (model_set, true)", name, ok)
	}
	if _, ok := p.LoadAndDelete("call-1"); ok {
		t.Error("LoadAndDelete of a removed id reported ok")
	}
	if p.Len() != 0 {
		t.Errorf("Len = %d after delete, want 0", p.Len())
	}
	// The removed id must not count toward eviction order.
	for i := 1; i <= maxPendingCmds; i++ {
		p.Store(idOf(i), "cmd")
	}
	// Re-insert the previously removed id (reuses a freed slot).
	p.Store("call-1", "cmd")
	if p.Len() != maxPendingCmds {
		t.Fatalf("Len = %d, want cap %d", p.Len(), maxPendingCmds)
	}
}

func TestPendingCmdsDelete(t *testing.T) {
	p := newPendingCmds()
	p.Store("call-1", "a")
	p.Store("call-2", "b")
	p.Delete("call-1")
	if _, ok := p.Load("call-1"); ok {
		t.Error("Delete did not remove the entry")
	}
	if v, ok := p.Load("call-2"); !ok || v != "b" {
		t.Errorf("call-2 = (%q, %v), want (b, true)", v, ok)
	}
	// Delete of an absent id is a no-op.
	p.Delete("nope")
	if p.Len() != 1 {
		t.Errorf("Len = %d, want 1", p.Len())
	}
}

func TestPendingCmdsReinsertDoesNotDuplicateOrder(t *testing.T) {
	p := newPendingCmds()
	p.Store("call-1", "a")
	p.Store("call-1", "a2") // same id, new name
	// Fill to the cap: if call-1 were duplicated in the order queue,
	// the cap would evict TWO entries instead of one.
	for i := 1; i <= maxPendingCmds; i++ {
		p.Store(idOf(i), "cmd")
	}
	if p.Len() != maxPendingCmds {
		t.Fatalf("Len = %d, want cap %d (duplicated order queue)", p.Len(), maxPendingCmds)
	}
}

func idOf(i int) string {
	return "call-" + string(rune('0'+i/100)) + string(rune('0'+(i/10)%10)) + string(rune('0'+i%10))
}
