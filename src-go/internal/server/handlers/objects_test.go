package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestObjectPutGetRoundtrip: content-addressed store — same content →
// same hash (idempotent, shared object), different content → different
// hash, and the object reads back verbatim.
func TestObjectPutGetRoundtrip(t *testing.T) {
	// Isolate HOME so the store lands in a temp ~/.alayaface.
	old := os.Getenv("HOME")
	t.Cleanup(func() { os.Setenv("HOME", old) })
	home := t.TempDir()
	os.Setenv("HOME", home)

	// Put twice: same content must yield the same hash and write once.
	rr1 := call(t, ObjectPut, map[string]any{"content": `{"k":1}`})
	rr2 := call(t, ObjectPut, map[string]any{"content": `{"k":1}`})
	var h1, h2 struct{ Hash string }
	if err := json.Unmarshal(rr1.Body.Bytes(), &h1); err != nil {
		t.Fatalf("object_put response: %v", err)
	}
	if err := json.Unmarshal(rr2.Body.Bytes(), &h2); err != nil {
		t.Fatalf("object_put response: %v", err)
	}
	if h1.Hash == "" || h1.Hash != h2.Hash {
		t.Fatalf("object_put(same) hashes = %q, %q; want equal non-empty", h1.Hash, h2.Hash)
	}

	// Object dir layout: ~/.alayaface/objects/<hash>/content.json
	store := filepath.Join(home, ".alayaface", "objects", h1.Hash, "content.json")
	if _, err := os.Stat(store); err != nil {
		t.Fatalf("object file missing: %v", err)
	}

	// Different content → different hash.
	rr3 := call(t, ObjectPut, map[string]any{"content": `{"k":2}`})
	var h3 struct{ Hash string }
	if err := json.Unmarshal(rr3.Body.Bytes(), &h3); err != nil {
		t.Fatalf("object_put response: %v", err)
	}
	if h3.Hash == h1.Hash {
		t.Fatalf("object_put(different) hash equals first: %q", h3.Hash)
	}

	// Roundtrip read.
	rr4 := call(t, ObjectGet, map[string]any{"hash": h1.Hash})
	if got := strings.TrimSpace(rr4.Body.String()); got != `"{\"k\":1}"` {
		t.Fatalf("object_get = %s, want the stored content", got)
	}

	// Unknown hash → clean error.
	if err := callErr(t, ObjectGet, map[string]any{"hash": strings.Repeat("ab", 32)}); err == nil {
		t.Fatal("object_get(unknown) must fail")
	}
}
