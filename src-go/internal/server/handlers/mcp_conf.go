package handlers

import (
	"encoding/json"
	"strings"
)

// ─── mcp.conf parsing/serialization ──────────────────────────────────
//
// The active preset's config (~/.alayaface/presets/<name>/mcp.conf) lists
// MCP servers in key-value block format (blocks separated by `---`).
// These helpers read/replace that file directly. Comments (`#`) and
// disabled blocks are dropped when the file is rewritten, mirroring the
// model editor behavior. Port of mcp.rs (second half).

// splitKVLine parses a `key: value` line. Skips blank lines and `#` comments.
func splitKVLine(line string) (string, string, bool) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "#") {
		return "", "", false
	}
	idx := strings.Index(trimmed, ":")
	if idx < 0 {
		return "", "", false
	}
	return strings.TrimSpace(trimmed[:idx]), strings.TrimSpace(trimmed[idx+1:]), true
}

// unquote strips surrounding double quotes (alayacore conf style).
func unquote(s string) string {
	t := strings.TrimSpace(s)
	if len(t) >= 2 && strings.HasPrefix(t, "\"") && strings.HasSuffix(t, "\"") {
		return t[1 : len(t)-1]
	}
	return t
}

// jsonKey maps a conf key to its JSON key (dash → underscore).
func jsonKey(confKey string) string {
	switch confKey {
	case "auth-type":
		return "auth_type"
	case "auth-token":
		return "auth_token"
	case "auth-client-id":
		return "auth_client_id"
	case "auth-client-secret":
		return "auth_client_secret"
	case "proto-version":
		return "proto_version"
	default:
		return confKey
	}
}

// confKey maps a JSON key back to its conf key (underscore → dash).
func confKey(jsonKey string) string {
	switch jsonKey {
	case "auth_type":
		return "auth-type"
	case "auth_token":
		return "auth-token"
	case "auth_client_id":
		return "auth-client-id"
	case "auth_client_secret":
		return "auth-client-secret"
	case "proto_version":
		return "proto-version"
	default:
		return jsonKey
	}
}

// parseMcpConf parses mcp.conf text into a list of server objects.
// `args`/`env` are normalized to raw JSON text strings so the frontend
// always receives strings for these fields.
func parseMcpConf(text string) []map[string]any {
	var servers []map[string]any
	var current []struct{ k, v string }

	flush := func() {
		if len(current) == 0 {
			return
		}
		obj := map[string]any{}
		for _, kv := range current {
			var value any
			if kv.k == "args" || kv.k == "env" {
				// Raw JSON text (array/object). Normalize to compact text.
				var parsed any
				if err := json.Unmarshal([]byte(kv.v), &parsed); err == nil {
					b, _ := json.Marshal(parsed)
					value = string(b)
				} else {
					value = kv.v
				}
			} else {
				value = unquote(kv.v)
			}
			obj[jsonKey(kv.k)] = value
		}
		// Only keep blocks that declared a server name (drops comment-only blocks).
		if _, ok := obj["server"]; ok {
			// Infer the server kind from the config: URL → HTTP, else STDIO.
			// Not persisted back (alayacore infers it the same way).
			url, _ := obj["url"].(string)
			kind := "stdio"
			if strings.TrimSpace(url) != "" {
				kind = "http"
			}
			obj["type"] = kind
			servers = append(servers, obj)
		}
		current = nil
	}

	for _, line := range strings.Split(text, "\n") {
		if strings.TrimSpace(line) == "---" {
			flush()
		} else if k, v, ok := splitKVLine(line); ok {
			current = append(current, struct{ k, v string }{k, v})
		}
	}
	flush()
	return servers
}

// mcpConfOrder is the ordered field list matching alayacore's mcp.conf layout.
var mcpConfOrder = []string{
	"server", "url", "command", "args", "env",
	"auth-type", "auth-token", "auth-client-id", "auth-client-secret", "proto-version",
}

// writeMcpConf serializes server objects back into mcp.conf block format.
// Matches Rust write_mcp_conf:
//   - args/env string values are written raw (already JSON text; empty → skipped)
//   - other string values are JSON-quoted (empty skipped, except `server`)
//   - non-string values are JSON-encoded
func writeMcpConf(servers []map[string]any) string {
	var out strings.Builder
	for i, s := range servers {
		if i > 0 {
			out.WriteString("---\n")
		}
		for _, ck := range mcpConfOrder {
			v, ok := s[jsonKey(ck)]
			if !ok {
				continue
			}
			if sv, isStr := v.(string); isStr {
				if ck == "args" || ck == "env" {
					if strings.TrimSpace(sv) == "" {
						continue
					}
					out.WriteString(ck + ": " + sv + "\n")
					continue
				}
				if sv == "" && ck != "server" {
					continue
				}
				quoted, err := json.Marshal(sv)
				if err != nil {
					continue
				}
				out.WriteString(ck + ": " + string(quoted) + "\n")
				continue
			}
			b, err := json.Marshal(v)
			if err != nil {
				continue
			}
			out.WriteString(ck + ": " + string(b) + "\n")
		}
	}
	return out.String()
}
