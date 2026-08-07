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
//	save          writes the session file (mirrors real alayacore's
//	              `:save` with an empty filename → --session file) and
//	              replies CO ok with the path
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
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"alayaface/src-go/internal/tlv"
)

// sessionFile is the --session flag value; `save` writes to it (empty
// filename semantics, like real alayacore).
var sessionFile string

// stagedText accumulates user text frames of the current message; the
// fail-once simulation keys its marker off it.
var stagedText string

// hanging marks a hung task (hang-once): the task never answers prompts,
// but the process keeps reading stdin and serving CI commands — mirroring
// real alayacore, which keeps its command loop alive while a task is
// stuck (cancel-first close depends on this: CI `cancel` must abort the
// hung task instead of waiting for the grace-period SIGKILL).
var hanging bool

// msgSeq numbers user messages (echo history ids): real alayacore gives
// every message a unique history id — the client dedupes echoes by it,
// so a constant id would drop the SECOND user message (e.g. the plan
// feedback prompt).
var msgSeq int

// replySeq numbers ASSISTANT content blocks (Ar/At/AT/AR echo ids).
// Real alayacore gives every content block a unique history id; constant
// ids (the historical "t1"/"p1"/"r1") made every reply share one id —
// the plan-message binding (meta origin messageId) then matched multiple
// messages in the same session.
var replySeq int

func nextReplyID() string {
	replySeq++
	return fmt.Sprintf("a-%d", replySeq)
}

type cmdMsg struct {
	ID    string `json:"id"`
	Name  string `json:"name"`
	Input string `json:"input"`
}

func writeFrame(tag, value string) {
	_ = tlv.WriteFrame(os.Stdout, tag, value)
}

// echo replies with a NUL-delimited history-ID prefix, like alayacore.
// Each USER MESSAGE gets its own id (msgSeq, incremented per UE flush).
func echo(tag, content string) {
	writeFrame(tag, "\x00"+fmt.Sprintf("hist-%d", msgSeq)+"\x00"+content)
}

// echoID is echo with an explicit history id. Real alayacore gives every
// content block a unique id (Ar/At/AF never share one); the fake mirrors
// that so the client's per-(role,id) delta accumulation is exercised.
func echoID(tag, id, content string) {
	writeFrame(tag, "\x00"+id+"\x00"+content)
}

// streamReply emits a canned assistant reply: reasoning + text deltas
// followed by empty AT/AR terminators (delta mode) and the task-done SM
// frame (in_progress=false → the runner marks the node Succeeded). The
// last assistant message echoes the received prompt so the E2E can
// verify output injection: a downstream node's prompt contains the
// upstream node's final answer (which itself echoes its own prompt).
func streamReply() {
	rid := nextReplyID()
	aid1 := nextReplyID()
	aid2 := nextReplyID()
	echoID("Ar", rid, "Thinking about it...")
	echoID("At", aid1, "Hello")
	echoID("At", aid1, " world")
	echoID("AT", aid1, "")
	echoID("AR", rid, "")
	echoID("At", aid2, "Received prompt: "+stagedText)
	echoID("AT", aid2, "")
	writeFrame("SM", `{"type":"task","data":{"in_progress":false,"task_error":false}}`)
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
	case "save":
		// Empty input = save to the --session file (real alayacore
		// semantics). Overwrite with a marker so tests can verify the
		// graceful-close save arrived before the process exited.
		if sessionFile != "" {
			if err := os.WriteFile(sessionFile, []byte(`{"version":1,"saved":true}`), 0o644); err != nil {
				coErr(msg.ID, "cannot write session file")
				return
			}
		}
		coOk(msg.ID, map[string]any{"path": sessionFile})
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
	flag.StringVar(&sessionFile, "session", "", "session file to create on startup")
	_ = flag.String("config-path", "", "config dir (accepted, unused)")
	_ = flag.String("tool-confirm", "", "pre-approved tool list (accepted, unused)")
	systemFlag := flag.String("system", "", "system prompt (accepted; non-empty switches to plan mode)")
	builtinToolsFlag := flag.String("builtin-tools", "", "builtin tools (accepted; echoed in the boot frame)")
	flag.Parse()

	if !*rawio {
		os.Exit(2) // not rawio mode: refuse like the real binary would
	}

	// Explicit-set detection mirrors alayacore: unspecified --builtin-tools
	// = all tools; explicitly empty = NO tools. The boot frame echoes both
	// so integration tests can assert the spawn flags.
	btSet := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "builtin-tools" {
			btSet = true
		}
	})

	// Plan mode: Plan Sessions spawn with --system (the planner prompt);
	// plain sessions and runner node sessions do not. In plan mode the
	// first user message is answered with a fenced plan JSON so the UI's
	// Create Plan offer appears.
	planMode := *systemFlag != ""

	// Real alayacore creates session.alaya when started with --session
	// (the session dir already exists). No MkdirAll: the fake must not
	// resurrect a directory that was deleted mid-startup.
	if sessionFile != "" {
		_ = os.WriteFile(sessionFile, []byte(`{"version":1}`), 0o644)
	}

	// Startup system message, like alayacore announcing its task. The
	// cwd/builtin_tools fields let tests assert spawn flags (per-plan
	// working-directory isolation, no-tools Plan Sessions); the client
	// ignores them.
	cwd, _ := os.Getwd()
	boot, _ := json.Marshal(map[string]any{
		"type": "task",
		"data": map[string]any{
			"id":                "boot",
			"title":             "fake core ready",
			"cwd":               cwd,
			"in_progress":       false, // mirrors real alayacore's boot task frame
			"builtin_tools":     *builtinToolsFlag,
			"builtin_tools_set": btSet,
		},
	})
	writeFrame("SM", string(boot))

	reader := bufio.NewReader(os.Stdin)
	staged := 0
	firstPrompt := true
	for {
		frame, err := tlv.ReadFrame(reader)
		if err != nil || frame == nil {
			break
		}
		switch frame.Tag {
		case "UT", "UI", "UV", "UA", "UD":
			echo(frame.Tag, frame.Value)
			staged++
			if frame.Tag == "UT" {
				stagedText += frame.Value
			}
		case "UE":
			if staged > 0 {
				// Mirrors real alayacore: processing a prompt starts the
				// task (in_progress:true) before any reply — even when the
				// task later hangs. The runner gates TaskDone on having
				// seen this frame (so the boot in_progress:false is not a
				// completion), so a hung task can still be aborted by the
				// cancel-first close below (which emits in_progress:false).
				writeFrame("SM", `{"type":"task","data":{"in_progress":true,"current_step":1,"context":0}}`)
				if hanging {
					// Hung task: swallow the prompt (no reply) — the
					// runner's timeout would fail the node (removed in
					// R1) and a cancel-first close can still abort us.
					staged = 0
					stagedText = ""
				} else {
					switch {
					case strings.HasPrefix(stagedText, "[Plan Result]"):
						// R3: the plan-feedback continuation prompt may
						// contain arbitrary node outputs (including words
						// like "hang-once" that trigger marker scenarios) —
						// it must ALWAYS get a normal reply.
						streamReply()
					case planMode && firstPrompt && strings.Contains(stagedText, "plan"):
						// R2: EVERY session now carries the planner hint
						// (--system). The fake answers with a fenced plan
						// JSON only when the user prompt actually asks for
						// planning — node task prompts (fixture) do NOT
						// contain "plan", so nodes complete normally.
						planReply()
						firstPrompt = false
					case strings.Contains(stagedText, "hang-once"):
						hangOnceReply()
					case strings.Contains(stagedText, "fail-once"):
						failOnceReply()
					default:
						streamReply()
					}
					staged = 0
					stagedText = ""
				}
				msgSeq++
			}
		case "CI":
			if hanging && strings.Contains(frame.Value, `"name":"cancel"`) {
				// Cancel aborts the hung task: emit the task-done frame
				// (mirrors alayacore's handleTaskDone after cancel) and
				// leave hang mode; the CO reply to the cancel command is
				// produced by handleCmd below.
				hanging = false
				streamReply()
			}
			handleCmd(frame.Value)
		}
	}

	// stdin closed (probe pattern): report the model list, then exit.
	smModelList()
}

// planReply emits a complete assistant text frame carrying a fenced plan
// JSON (the Create Plan offer detector scans the final AT content), then
// a normal reply and the task-done frame.
func planReply() {
	const planJSON = `{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "E2E Demo",
  "goal": "Automated end-to-end verification of Plan Mode",
  "concurrency": 2,
  "default_max_attempts": 3,
  "tasks": [
    { "id": "t1", "title": "Research", "prompt": "research the topic and summarize findings", "depends_on": [], "max_attempts": 3 },
    { "id": "t2", "title": "Draft", "prompt": "draft the report from the research (fail-once marker). using upstream output: {{t1.output}}", "depends_on": ["t1"], "max_attempts": 3 },
    { "id": "t3", "title": "Review", "prompt": "review the draft and fix any issues (hang-once marker)", "depends_on": ["t2"], "max_attempts": 3 }
  ]
}`
	echoID("AT", nextReplyID(), "Here is the plan:\n```json\n"+planJSON+"\n```\nI'll wait for you to create it.")
	echoID("AR", nextReplyID(), "")
	streamReply()
}

// failOnceReply simulates a task that fails on its first attempt and
// succeeds afterwards. The marker is keyed by the prompt text hash and
// lives in the shared temp dir, so it survives across processes: the
// runner's retry spawns a fresh fakecore in a NEW session directory,
// which sees the same marker and succeeds (a per-session marker would
// never be found again).
func failOnceReply() {
	h := sha256.Sum256([]byte(stagedText))
	marker := filepath.Join(os.TempDir(), fmt.Sprintf("alayaface-fakecore-fail-once-%x.marker", h[:8]))
	if _, err := os.Stat(marker); os.IsNotExist(err) {
		_ = os.WriteFile(marker, []byte("failed-once"), 0o644)
		// Task failure: SM task frame with in_progress=false,
		// task_error=true (the runner maps this to a node failure).
		writeFrame("SM", `{"type":"task","data":{"in_progress":false,"task_error":true}}`)
		return
	}
	streamReply()
}

// hangOnceReply simulates a task that HANGS: the first process writes the
// shared marker and enters hang mode (no reply to prompts); the retry
// process sees the marker and succeeds. Unlike a naive sleep, hang mode
// keeps reading stdin and serving CI commands, so a cancel-first close
// (CI `cancel`) can abort the hung task immediately — the E2E Stop step
// closes the hung session without waiting for a 30s sleep + SIGKILL.
func hangOnceReply() {
	h := sha256.Sum256([]byte(stagedText))
	marker := filepath.Join(os.TempDir(), fmt.Sprintf("alayaface-fakecore-hang-once-%x.marker", h[:8]))
	if _, err := os.Stat(marker); os.IsNotExist(err) {
		_ = os.WriteFile(marker, []byte("hung-once"), 0o644)
		hanging = true
		return
	}
	streamReply()
}
