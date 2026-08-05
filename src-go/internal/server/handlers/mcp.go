package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"alayaface/src-go/internal/dirs"
)

// ListDefaultMcp lists the MCP server list from a preset's mcp.conf
// (`preset` empty = active). A missing mcp.conf is treated as an empty
// server list (first run), not an error.
func ListDefaultMcp(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Preset string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	configDir, err := dirs.ResolveConfigDir(args.Preset)
	if err != nil {
		return err
	}
	path := filepath.Join(configDir, "mcp.conf")
	text, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return writeJSON(w, []map[string]any{})
		}
		return err
	}
	servers := parseMcpConf(string(text))
	return writeJSON(w, servers)
}

// SyncDefaultMcp replaces the MCP server list in a preset's mcp.conf
// (`preset` empty = active). Validates per server kind: names must be
// unique; http servers need a url and auth fields per auth-type; stdio
// servers need a command and args/env as JSON. Writes atomically.
func SyncDefaultMcp(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Config string `json:"config"`
		Preset string `json:"preset"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	var servers []map[string]any
	if err := json.Unmarshal([]byte(args.Config), &servers); err != nil {
		return fmt.Errorf("invalid config JSON: %w", err)
	}

	names := map[string]bool{}
	for _, s := range servers {
		name, _ := s["server"].(string)
		name = strings.TrimSpace(name)
		if name == "" {
			return fmt.Errorf("every server needs a non-empty `server` name")
		}
		if names[name] {
			return fmt.Errorf("duplicate server name: %s", name)
		}
		names[name] = true

		// Server kind is inferred the same way as parseMcpConf: URL →
		// http, otherwise stdio. Different kinds validate different fields.
		url, _ := s["url"].(string)
		url = strings.TrimSpace(url)
		if url != "" {
			authType, _ := s["auth_type"].(string)
			authType = strings.TrimSpace(authType)
			switch authType {
			case "authorization_code":
				cid, _ := s["auth_client_id"].(string)
				secret, _ := s["auth_client_secret"].(string)
				if strings.TrimSpace(cid) == "" {
					return fmt.Errorf("server %s: auth-client-id is required for authorization_code auth", name)
				}
				if strings.TrimSpace(secret) == "" {
					return fmt.Errorf("server %s: auth-client-secret is required for authorization_code auth", name)
				}
			case "static":
				token, _ := s["auth_token"].(string)
				if strings.TrimSpace(token) == "" {
					return fmt.Errorf("server %s: auth-token is required for static auth", name)
				}
			}
		} else {
			command, _ := s["command"].(string)
			if strings.TrimSpace(command) == "" {
				return fmt.Errorf("server %s: command is required for stdio servers", name)
			}
			if err := validateJSONField(s, name, "args", true); err != nil {
				return err
			}
			if err := validateJSONField(s, name, "env", false); err != nil {
				return err
			}
		}
	}

	text := writeMcpConf(servers)
	configDir, err := dirs.ResolveConfigDir(args.Preset)
	if err != nil {
		return err
	}
	path := filepath.Join(configDir, "mcp.conf")
	tmp := filepath.Join(configDir, "mcp.conf.tmp")
	if err := os.WriteFile(tmp, []byte(text), 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return writeResult(w, nil)
}

// validateJSONField validates that a field holding raw JSON text parses
// as a JSON array (wantArray) or object. An absent or empty/whitespace
// value is treated as "not set" and skipped.
func validateJSONField(obj map[string]any, name, key string, wantArray bool) error {
	v, ok := obj[key]
	if !ok {
		return nil
	}
	kind := "object"
	if wantArray {
		kind = "array"
	}
	switch val := v.(type) {
	case string:
		if strings.TrimSpace(val) == "" {
			return nil
		}
		var parsed any
		if err := json.Unmarshal([]byte(val), &parsed); err != nil {
			return fmt.Errorf("server %s: %s is not valid JSON: %w", name, key, err)
		}
		if wantArray {
			if _, isArr := parsed.([]any); !isArr {
				return fmt.Errorf("server %s: %s must be a JSON %s", name, key, kind)
			}
		} else {
			if _, isObj := parsed.(map[string]any); !isObj {
				return fmt.Errorf("server %s: %s must be a JSON %s", name, key, kind)
			}
		}
	default:
		if wantArray {
			if _, isArr := val.([]any); !isArr {
				return fmt.Errorf("server %s: %s must be a JSON %s", name, key, kind)
			}
		} else {
			if _, isObj := val.(map[string]any); !isObj {
				return fmt.Errorf("server %s: %s must be a JSON %s", name, key, kind)
			}
		}
	}
	return nil
}
