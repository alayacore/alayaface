package handlers

import (
	"encoding/json"
	"testing"
)

const sampleMcpConf = `#server: disabledOne
#url: http://localhost:1
---
server: exaWebSearch
url: https://mcp.exa.ai/mcp
proto-version: 2025-11-25
---
#server: disabledTwo
---
server: embedded
command: "embedded-debugger-mcp"
args: ["--allow-flash-erase", "serve"]
env: {"RUST_LOG": "info"}
auth-type: authorization_code
`

func TestParseSkipsCommentedBlocks(t *testing.T) {
	servers := parseMcpConf(sampleMcpConf)
	if len(servers) != 2 {
		t.Fatalf("parsed %d servers, want 2", len(servers))
	}
	if servers[0]["type"] != "http" {
		t.Errorf("server[0].type = %v, want http", servers[0]["type"])
	}
	if servers[1]["type"] != "stdio" {
		t.Errorf("server[1].type = %v, want stdio", servers[1]["type"])
	}
	if servers[1]["args"] != `["--allow-flash-erase","serve"]` {
		t.Errorf("server[1].args = %v, want compact JSON text", servers[1]["args"])
	}
	if servers[1]["env"] != `{"RUST_LOG":"info"}` {
		t.Errorf("server[1].env = %v, want compact JSON text", servers[1]["env"])
	}
}

func TestWriteRoundtrips(t *testing.T) {
	servers := parseMcpConf(sampleMcpConf)
	out := writeMcpConf(servers)
	reparsed := parseMcpConf(out)
	if len(reparsed) != len(servers) {
		t.Fatalf("reparsed %d servers, want %d", len(reparsed), len(servers))
	}
	for i := range servers {
		a, _ := json.Marshal(servers[i])
		b, _ := json.Marshal(reparsed[i])
		if string(a) != string(b) {
			t.Errorf("server %d mismatch:\n got  %s\n want %s", i, b, a)
		}
	}
}

func TestSyncValidates(t *testing.T) {
	isolatedHome(t, func() {
		seedPresets(t)
		badCases := []string{
			// Invalid args JSON must be rejected (stdio server).
			`[{"server":"x","command":"bin","args":"not json"}]`,
			// Duplicate names must be rejected.
			`[{"server":"x"},{"server":"x"}]`,
			// stdio server without a command must be rejected.
			`[{"server":"x","command":""}]`,
			// http server with authorization_code but no client id/secret.
			`[{"server":"x","url":"https://example.com/mcp","auth_type":"authorization_code"}]`,
			// http server with static auth but no token.
			`[{"server":"x","url":"https://example.com/mcp","auth_type":"static"}]`,
		}
		for _, c := range badCases {
			if err := callErr(t, SyncDefaultMcp, map[string]any{"config": c, "preset": "Simple"}); err == nil {
				t.Errorf("expected error for config %s", c)
			}
		}
	})
}

func TestSyncAcceptsEmptyArgsEnv(t *testing.T) {
	isolatedHome(t, func() {
		seedPresets(t)
		okCases := []string{
			// HTTP server: empty args/env strings must not be validated.
			`[{"server":"exa","url":"https://mcp.exa.ai/mcp","args":"","env":""}]`,
			// STDIO server: empty args/env treated as unset and accepted.
			`[{"server":"blah","command":"my-mcp","args":"","env":""}]`,
			// STDIO server with valid JSON args/env accepted.
			`[{"server":"blah","command":"my-mcp","args":"[\"--foo\"]","env":"{\"RUST_LOG\":\"info\"}"}]`,
		}
		for _, c := range okCases {
			if err := callErr(t, SyncDefaultMcp, map[string]any{"config": c, "preset": "Simple"}); err != nil {
				t.Errorf("unexpected error for config %s: %v", c, err)
			}
		}
	})
}

func TestListDefaultMcpMissingFileReturnsEmpty(t *testing.T) {
	isolatedHome(t, func() {
		seedPresets(t)
		// A missing mcp.conf must be an empty list, not an error.
		rr := call(t, ListDefaultMcp, map[string]any{"preset": "Simple"})
		var out []map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if len(out) != 0 {
			t.Errorf("expected empty list, got %v", out)
		}
	})
}
