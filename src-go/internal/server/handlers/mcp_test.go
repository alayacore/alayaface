package handlers

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"alayaface/src-go/internal/dirs"
)

// The MCP editor's format lives in App/McpConfig.elm. Both backends only
// move bytes, so what these tests pin is exactly that: the text written is
// the text the client produced (no re-serialization, no field dropped), the
// file is 0600 (it can hold OAuth secrets), and a missing file reads as an
// empty document rather than an error.

const sampleMcpText = `server: "a&b<c>"
url: "https://h/mcp?a=1&b=2"
auth-scopes: ["read"]
proto-version: "2025-11-25"
`

func TestSyncDefaultMcpWritesVerbatim(t *testing.T) {
	isolatedHome(t, func() {
		seedPresets(t)
		if err := callErr(t, SyncDefaultMcp, map[string]any{
			"config": sampleMcpText,
			"preset": "Simple",
		}); err != nil {
			t.Fatalf("SyncDefaultMcp: %v", err)
		}

		path := filepath.Join(dirs.PresetDir("Simple"), "mcp.conf")
		got, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("read mcp.conf: %v", err)
		}
		if string(got) != sampleMcpText {
			t.Errorf("mcp.conf = %q, want %q", got, sampleMcpText)
		}
		if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o600 {
			t.Errorf("mode = %v, want 0600 (OAuth secrets live here)", fi.Mode())
		}
	})
}

func TestListDefaultMcpReturnsRawText(t *testing.T) {
	isolatedHome(t, func() {
		seedPresets(t)
		if err := callErr(t, SyncDefaultMcp, map[string]any{
			"config": sampleMcpText,
			"preset": "Simple",
		}); err != nil {
			t.Fatalf("SyncDefaultMcp: %v", err)
		}

		rr := call(t, ListDefaultMcp, map[string]any{"preset": "Simple"})
		var out struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out.Text != sampleMcpText {
			t.Errorf("text = %q, want %q", out.Text, sampleMcpText)
		}
	})
}

func TestListDefaultMcpMissingFileReturnsEmptyDocument(t *testing.T) {
	isolatedHome(t, func() {
		seedPresets(t)
		rr := call(t, ListDefaultMcp, map[string]any{"preset": "Simple"})
		var out struct {
			Text string `json:"text"`
		}
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out.Text != "" {
			t.Errorf("missing file text = %q, want empty", out.Text)
		}
	})
}
