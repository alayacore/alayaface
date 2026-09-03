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

// TestObjectGetRejectsNonHashPaths pins the containment guard on the
// content-addressed store: object_get joins its argument straight into
// ~/.alayaface/objects/<hash>/content.json, so an unvalidated hash can walk
// out of the store with "../../sessions/x/config" and read any file named
// content.json.
func TestObjectGetRejectsNonHashPaths(t *testing.T) {
	old := os.Getenv("HOME")
	t.Cleanup(func() { os.Setenv("HOME", old) })
	os.Setenv("HOME", t.TempDir())

	for _, bad := range []string{
		"",
		"..",
		"../../sessions/x/config",
		strings.Repeat("ab", 31) + "z", // 64 chars, not hex
		strings.Repeat("AB", 32),       // 64 chars, wrong case (digests are lowercase)
		strings.Repeat("ab", 32) + "0", // 65 chars
	} {
		if err := callErr(t, ObjectGet, map[string]any{"hash": bad}); err == nil {
			t.Errorf("object_get accepted hash %q", bad)
		} else if !strings.Contains(err.Error(), "invalid hash") {
			t.Errorf("object_get(%q) error = %v, want the invalid-hash guard", bad, err)
		}
	}

	// A hash object_put actually produces still round-trips.
	rr := call(t, ObjectPut, map[string]any{"content": `{"a":1}`})
	var put struct{ Hash string }
	if err := json.Unmarshal(rr.Body.Bytes(), &put); err != nil || put.Hash == "" {
		t.Fatalf("object_put response: %s (%v)", rr.Body.String(), err)
	}
	got := call(t, ObjectGet, map[string]any{"hash": put.Hash})
	if want := `"{\"a\":1}"`; strings.TrimSpace(got.Body.String()) != want {
		t.Errorf("object_get = %s, want %s", got.Body.String(), want)
	}
}
