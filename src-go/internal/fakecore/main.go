// Command fakecore is a scriptable stand-in for alayacore used by the
// Go backend integration tests (internal/server/integration_test.go).
//
// It speaks the same TLV rawio protocol as the real thing:
//
//   - stdin: UT/UI/UV/UA/UD (user content) and CI (command input) frames
//   - stdout: SM task on startup, user echoes, At/Ar deltas + AT/AR
//     terminators for a canned assistant reply, SM model_list on EOF,
//     and CO replies to CI commands (with the caller's call ID echoed
//     so the backend's pending-command name injection can be verified)
//
// Scripted CI commands (matching what the backend sends):
//
//	fork          input "<historyId> <targetFile>" — writes the session
//	              file (like real alayacore) and replies CO ok
//	model_set     replies CO ok with the model id echoed
//	model_load    emits SM model_list then replies CO ok
//	model_sync    replies CO ok; if input contains `"invalid"` replies
//	              CO with is_error=true ({"message":"invalid config"})
//	tool_confirm / tool_decline — replies CO ok with the tool id
//	cancel        replies CO ok
//	mcp_decline / mcp_cancel — replies CO ok
//	(anything else) replies CO with is_error=true
//
// A `--session <path>` flag makes it write a session file on startup
// (mirrors real alayacore creating session.alaya), so resume_session
// has something to find.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"

	"alayaface/src-go/internal/tlv"
)

const historyID = "hist-1"

type cmdMsg struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Input string `json:"input"`
}

func writeFrame(tag, value string) {
	_ = tlv.WriteFrame(os.Stdout, tag, value)
}

// echo replies with the NUL-delimited history-ID prefix, like alayacore.
func echo(tag, content string) {
	writeFrame(tag, "\x00"+historyID+"\x00"+content)
}

// streamReply emits a canned assistant reply: reasoning + text deltas
// followed by empty AT/AR terminators (delta mode).
func streamReply() {
	echo("Ar", "Thinking about it...")
	echo("At", "Hello")
	echo("At", " world")
	echo("AT", "")
	echo("AR", "")
}

func coOk(id string, output map[string]any) {
	payload, _ := json.Marshal(map[string]any{
		"id":       id,
		"output":   output,
		"is_error": false,
	})
	writeFrame("CO", string(payload))
}

func coErr(id, message string) {
	payload, _ := json.Marshal(map[string]any{
		"id":       id,
		"output":   map[string]any{"message": message},
		"is_error": true,
	})
	writeFrame("CO", string(payload))
}

func smModelList() {
	payload := `{"type":"model_list","data":{"models":[` +
		`{"id":1,"name":"fake-model-1"},` +
		`{"id":2,"name":"fake-model-2"}]}}`
	writeFrame("SM", payload)
}

func handleCmd(raw string) {
	var msg cmdMsg
	if err := json.Unmarshal([]byte(raw), &msg); err != nil {
		coErr("", "bad CI payload")
		return
	}
	switch msg.Name {
	case "fork":
		// input = "<historyId> <targetFile>"
		fields := strings.Fields(msg.Input)
		if len(fields) < 2 {
			coErr(msg.ID, "fork needs <historyId> <targetFile>")
			return
		}
		target := fields[len(fields)-1]
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			coErr(msg.ID, "cannot create fork dir")
			return
		}
		if err := os.WriteFile(target, []byte(`{"history":[{"id":"`+fields[0]+`"}]}`), 0o644); err != nil {
			coErr(msg.ID, "cannot write session file")
			return
		}
		coOk(msg.ID, map[string]any{"message": "forked"})
	case "model_set":
		coOk(msg.ID, map[string]any{"modelId": msg.Input})
	case "model_load":
		smModelList()
		coOk(msg.ID, map[string]any{"ok": true})
	case "model_sync":
		if strings.Contains(msg.Input, `"invalid"`) {
			coErr(msg.ID, "invalid config")
			return
		}
		coOk(msg.ID, map[string]any{"message": "synced"})
	case "tool_confirm", "tool_decline":
		coOk(msg.ID, map[string]any{"id": msg.Input, "allowed": msg.Name == "tool_confirm"})
	case "cancel":
		coOk(msg.ID, map[string]any{"cancelled": true})
	case "mcp_decline", "mcp_cancel":
		coOk(msg.ID, map[string]any{"server": msg.Input})
	default:
		coErr(msg.ID, "unknown command: "+msg.Name)
	}
}

func main() {
	rawio := flag.Bool("rawio", false, "required rawio mode flag")
	sessionPath := flag.String("session", "", "session file to create on startup")
	_ = flag.String("config-path", "", "config dir (accepted, unused)")
	_ = flag.String("tool-confirm", "", "pre-approved tool list (accepted, unused)")
	flag.Parse()

	if !*rawio {
		os.Exit(2) // not rawio mode: refuse like the real binary would
	}

	// Real alayacore creates session.alaya when started with --session
	// (the session dir already exists). No MkdirAll: the fake must not
	// resurrect a directory that was deleted mid-startup.
	if *sessionPath != "" {
		_ = os.WriteFile(*sessionPath, []byte(`{"version":1}`), 0o644)
	}

	// Startup system message, like alayacore announcing its task.
	writeFrame("SM", `{"type":"task","data":{"id":"boot","title":"fake core ready"}}`)

	reader := bufio.NewReader(os.Stdin)
	staged := 0
	for {
		frame, err := tlv.ReadFrame(reader)
		if err != nil || frame == nil {
			break
		}
		switch frame.Tag {
		case "UT", "UI", "UV", "UA", "UD":
			echo(frame.Tag, frame.Value)
			staged++
		case "UE":
			if staged > 0 {
				streamReply()
				staged = 0
			}
		case "CI":
			handleCmd(frame.Value)
		}
	}

	// stdin closed (probe pattern): report the model list, then exit.
	smModelList()
}
