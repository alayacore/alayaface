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
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"alayaface/src-go/internal/core"
	"alayaface/src-go/internal/tlv"
)

// sessionFile is the --session flag value; `save` writes to it (empty
// filename semantics, like real alayacore). configDir is the
// --config-path value; model_set writes runtime.conf into it (mirrors
// real alayacore). readySent tracks whether the ready SM has been
// emitted: prompts before it are rejected (MCP_NOT_READY).
var sessionFile string
var configDir string
var readySent bool

// histMsg is one recorded message of this session's history. The fake
// maintains it so `fork` can truncate it into the new session file and
// the forked process can REPLAY it on startup (mirroring real
// alayacore: a forked session streams its truncated history) — the E2E
// cascade relies on this to exercise the fork session's replay
// suppression and status-bar binding.
type histMsg struct {
	Role    string `json:"role"` // "user" | "assistant"
	Content string `json:"content"`
	ID      string `json:"id"` // history id ("hist-N" / "a-N")
}

// history accumulates this session's messages (user echoes + assistant
// replies) in arrival order.
var history []histMsg

// versionSuffix: when /tmp/alayaface-fakecore-version.marker exists,
// every normal reply is suffixed with its content. The E2E writes it
// before a cascade RE-RUN so the new run's node summaries differ from
// the previous run — the cascade gate then propagates and forks the
// parent conversation (a deterministic way to force summary change
// without touching the plan fixture). The content doubles as the
// version tag ("v2", "v3", …), so successive re-runs can differ from
// each other (chained forks).
func versionSuffix() string {
	b, err := os.ReadFile(filepath.Join(os.TempDir(), "alayaface-fakecore-version.marker"))
	if err != nil {
		return ""
	}
	return " " + strings.TrimSpace(string(b))
}

// planJSON is the fenced plan document emitted by plan mode AND replayed
// on resume (see replayResumedHistory) — it must carry the alayaface-plan
// marker so the UI's plan detection sees it.
const planJSON = `{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "E2E Demo",
  "goal": "Automated end-to-end verification of Plan Mode",
  "concurrency": 2,
  "default_max_attempts": 3,
  "tasks": [
    { "id": "t1", "title": "Research", "prompt": "research the topic and summarize findings", "depends_on": [], "preset": "Simple", "max_attempts": 3 },
    { "id": "t2", "title": "Draft", "prompt": "draft the report from the research (fail-once marker). using upstream output: {{t1.output}}", "depends_on": ["t1"], "preset": "Complex", "max_attempts": 3 },
    { "id": "t3", "title": "Review", "prompt": "review the draft and fix any issues (hang-once marker)", "depends_on": ["t2"], "preset": "Complex", "max_attempts": 3 }
  ]
}`

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
// echo dedup then dropped or misattributed messages in the same session.
var replySeq int

func nextReplyID() string {
	replySeq++
	return fmt.Sprintf("a-%d", replySeq)
}

// contextTokens tracks the session's consumed context tokens (mirrors
// real alayacore's `context` field on task SM frames, adapter-guide).
// Each completed task consumes a fixed amount; the frontend renders the
// session bar readout "used/limit pct%" from context and the active
// model's context_limit.
var contextTokens int

// taskDoneFrame emits the task-completion SM frame carrying the current
// context token count and the latest step's speed metrics — real
// alayacore reports all three on every task frame (adapter-guide).
// step_tps/ttft_ms mirror the terminal adapter's "end-of-task" readout:
// after a step that produced output tokens, the values stay visible
// across the task-end broadcast so the speed bar doesn't blank out
// when the task finishes.
func taskDoneFrame() string {
	contextTokens += 4096
	return fmt.Sprintf(
		`{"type":"task","data":{"in_progress":false,"context":%d,"step_tps":%.1f,"ttft_ms":%d}}`,
		contextTokens, lastStepTps, lastTtftMs,
	)
}

// taskDoneBareFrame is the same as taskDoneFrame but WITHOUT step_tps /
// ttft_ms — used by fail-once / fail-always to mirror real alayacore's
// behaviour when a step produced no output tokens (adapter-guide:
// "step_tps / ttft_ms are absent until a step with output tokens
// completes"). The failure itself is signalled by the SM `error` frame
// the caller sends before this one.
func taskDoneBareFrame() string {
	contextTokens += 4096
	return fmt.Sprintf(
		`{"type":"task","data":{"in_progress":false,"context":%d}}`,
		contextTokens,
	)
}

// fake speed metrics — bumped on each streamed reply so the session-bar
// speed readout exercises the step_tps/ttft_ms path end-to-end.
var (
	fakeStep   = 1
	lastStepTps = 18.5
	lastTtftMs  = 240
)

// llmURL / llmModel — when llmURL is non-empty, streamReply forwards
// the prompt to this OpenAI-compatible endpoint and translates the SSE
// stream back into Ar/At/AT frames plus real step_tps / ttft_ms
// measurements (instead of the canned hardcoded "Hello world" reply).
// Used by the speed-display E2E to drive fakecore with a real local
// model (e.g. http://172.16.9.6:9999/v1 + gemma-4-12B).
var (
	llmURL   string
	llmModel string
)

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

// streamReply emits either a canned assistant reply OR — when llmURL is
// set — forwards the staged user prompt to the real LLM and streams
// the SSE response back as Ar/At/AT frames with real step_tps / ttft_ms
// broadcast on intermediate + final task frames (mirror of alayacore's
// SM-task-step.bin / SM-task-end.bin). Either way the last assistant
// message echoes the received prompt so E2E output-injection checks
// still hold.
func streamReply() {
	if llmURL != "" {
		realLLMReply()
		return
	}
	// Bump the fake per-step speed metrics so successive task completions
	// produce a visibly varying speed readout on the session bar.
	fakeStep++
	lastStepTps = 12.0 + float64(fakeStep%6)  // 12..17 tok/s
	lastTtftMs = 150 + (fakeStep%5)*40         // 150..310 ms
	rid := nextReplyID()
	aid1 := nextReplyID()
	aid2 := nextReplyID()
	echoID("Ar", rid, "Thinking about it...")
	echoID("At", aid1, "Hello")
	echoID("At", aid1, " world")
	echoID("AT", aid1, "")
	echoID("AR", rid, "")
	// Step 1 just finished — broadcast an in_progress:true task frame
	// with this step's speed metrics (mirrors real alayacore's
	// SM-task-step.bin). Without this, the session-bar stays empty
	// until the task ends and never shows live speed while streaming.
	contextTokens += 1024
	writeFrame("SM", fmt.Sprintf(
		`{"type":"task","data":{"in_progress":true,"current_step":2,"context":%d,"step_tps":%.1f,"ttft_ms":%d}}`,
		contextTokens, lastStepTps, lastTtftMs,
	))
	echoID("At", aid2, "Received prompt: "+stagedText+versionSuffix())
	echoID("AT", aid2, "")
	writeFrame("SM", taskDoneFrame())
	// Record the reply (merged) for fork-history replay.
	history = append(history, histMsg{"assistant", "Hello world\n\nReceived prompt: " + stagedText + versionSuffix(), aid2})
}

// writeRuntimeConf persists the active model name into a config dir's
// runtime.conf (key: value lines, like real alayacore — strings are
// double-quoted).
func writeRuntimeConf(configDir, modelName string) error {
	if err := os.MkdirAll(configDir, 0o755); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(configDir, "runtime.conf"), []byte("active_model: \""+modelName+"\"\n"), 0o644)
}

// realLLMReply forwards the staged user prompt to llmURL (OpenAI-
// compatible /v1/chat/completions with stream:true), parses the SSE
// response, and translates each delta.content into an At frame on a
// single stable history id (so the client's per-(role,id) delta
// accumulation works). At the end it broadcasts an SM task frame
// with the measured step_tps / ttft_ms — the speed the session-bar
// reads. If the upstream call fails or returns no choices, it emits
// an SM error frame followed by a bare task_end so the runner marks
// the node as failed rather than hanging.
func realLLMReply() {
	body := fmt.Sprintf(
		`{"model":%q,"messages":[{"role":"user","content":%q}],"stream":true,"stream_options":{"include_usage":true}}`,
		llmModel, stagedText,
	)
	url := strings.TrimRight(llmURL, "/") + "/chat/completions"
	req, err := http.NewRequest("POST", url, strings.NewReader(body))
	if err != nil {
		writeFrame("SM", fmt.Sprintf(`{"type":"error","data":{"text":"build request: %s"}}`, err.Error()))
		writeFrame("SM", taskDoneBareFrame())
		return
	}
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Do(req)
	if err != nil {
		writeFrame("SM", fmt.Sprintf(`{"type":"error","data":{"text":"http: %s"}}`, err.Error()))
		writeFrame("SM", taskDoneBareFrame())
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		writeFrame("SM", fmt.Sprintf(`{"type":"error","data":{"text":"upstream %d: %s"}}`, resp.StatusCode, string(b)))
		writeFrame("SM", taskDoneBareFrame())
		return
	}

	aid := nextReplyID()
	startedAt := time.Now()
	var firstTokenAt time.Time
	var tokenCount int
	var fullText strings.Builder

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" || !strings.HasPrefix(line, "data:") {
			continue
		}
		payload := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if payload == "[DONE]" {
			break
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
			Usage *struct {
				CompletionTokens int `json:"completion_tokens"`
			} `json:"usage"`
		}
		if err := json.Unmarshal([]byte(payload), &chunk); err != nil {
			continue
		}
		if chunk.Usage != nil && chunk.Usage.CompletionTokens > 0 {
			tokenCount = chunk.Usage.CompletionTokens
		}
		for _, c := range chunk.Choices {
			if c.Delta.Content == "" {
				continue
			}
			if firstTokenAt.IsZero() {
				firstTokenAt = time.Now()
			}
			fullText.WriteString(c.Delta.Content)
			echoID("At", aid, c.Delta.Content)
			if chunk.Usage == nil {
				tokenCount += len(c.Delta.Content) / 4
			}
		}
	}
	if err := scanner.Err(); err != nil {
		writeFrame("SM", fmt.Sprintf(`{"type":"error","data":{"text":"stream read: %s"}}`, err.Error()))
		writeFrame("SM", taskDoneBareFrame())
		return
	}
	endedAt := time.Now()

	if tokenCount == 0 && fullText.Len() == 0 {
		writeFrame("SM", `{"type":"error","data":{"text":"upstream returned no choices"}}`)
		writeFrame("SM", taskDoneBareFrame())
		return
	}

	var stepTps, ttftMs float64
	if !firstTokenAt.IsZero() {
		ttftMs = float64(firstTokenAt.Sub(startedAt).Milliseconds())
	}
	streamDur := endedAt.Sub(startedAt).Seconds()
	if streamDur > 0 && tokenCount > 0 {
		stepTps = float64(tokenCount) / streamDur
	}
	lastStepTps = stepTps
	lastTtftMs = int(ttftMs)

	echoID("AT", aid, "")
	contextTokens += tokenCount * 4 // rough context bump
	writeFrame("SM", fmt.Sprintf(
		`{"type":"task","data":{"in_progress":false,"context":%d,"step_tps":%.1f,"ttft_ms":%d}}`,
		contextTokens, lastStepTps, lastTtftMs,
	))
	history = append(history, histMsg{"assistant", fullText.String(), aid})
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
	// Full ModelInfo shape (mirrors real alayacore's model_list so the
	// Elm modelInfoDecoder accepts it): id, name, protocol_type,
	// base_url, api_key, model_name, context_limit, max_tokens.
	payload := `{"type":"model_list","data":{"models":[` +
		`{"id":1,"name":"fake-model-1","protocol_type":"openai","base_url":"http://localhost:11434/v1","api_key":"fake","model_name":"model-1","context_limit":8192,"max_tokens":2048},` +
		`{"id":2,"name":"fake-model-2","protocol_type":"openai","base_url":"http://localhost:11434/v1","api_key":"fake","model_name":"model-2","context_limit":16384,"max_tokens":4096}]}}`
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
		historyID := fields[0]
		target := fields[len(fields)-1]
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			coErr(msg.ID, "cannot create fork dir")
			return
		}
		// The fork's session.alaya carries exactly the truncated history
		// (up to and including historyID); the forked process replays it
		// on startup — mirrors real alayacore.
		payload, _ := json.Marshal(map[string]any{
			"version": 1,
			"forked":  true,
			"history": truncateHistory(historyID),
		})
		if err := os.WriteFile(target, payload, 0o644); err != nil {
			coErr(msg.ID, "cannot write session file")
			return
		}
		coOk(msg.ID, map[string]any{"message": "forked"})
	case "save":
		// Empty input = save to the --session file (real alayacore
		// semantics). Write the session's COMPLETE history (the replayed
		// fork history + every message received since) so a later resume
		// replays everything — real alayacore appends all messages to
		// session.alaya, so a forked session's file contains both the
		// truncated history AND the post-fork messages. No history (a
		// fresh/plain session) → the legacy marker (restart-e2e).
		if sessionFile != "" {
			var payload []byte
			if len(history) > 0 {
				payload, _ = json.Marshal(map[string]any{
					"version": 1, "saved": true, "history": history,
				})
			} else {
				payload = []byte(`{"version":1,"saved":true}`)
			}
			if err := os.WriteFile(sessionFile, payload, 0o644); err != nil {
				coErr(msg.ID, "cannot write session file")
				return
			}
		}
		coOk(msg.ID, map[string]any{"path": sessionFile})
	case "model_set":
		// Mirror real alayacore: model_set persists the active model to
		// the config dir's runtime.conf (`active_model: <name>`), so the
		// preset-level set-default-model flow is testable end to end.
		if configDir != "" {
			name := fmt.Sprintf("fake-model-%s", msg.Input)
			if err := writeRuntimeConf(configDir, name); err != nil {
				coErr(msg.ID, "cannot write runtime.conf")
				return
			}
		}
		coOk(msg.ID, map[string]any{"modelId": msg.Input})
	case "model_load":
		smModelList()
		coOk(msg.ID, map[string]any{"ok": true})
	case "reason":
		// Mirror real alayacore: accepts a level (0|1|2) and echoes it.
		coOk(msg.ID, map[string]any{"level": msg.Input})
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
	flag.StringVar(&configDir, "config-path", "", "config dir (runtime.conf is written here by model_set)")
	toolConfirmFlag := flag.String("tool-confirm", "", "pre-approved tool list (accepted; echoed in the boot frame)")
	systemFlag := flag.String("system", "", "system prompt (accepted; non-empty switches to plan mode)")
	builtinToolsFlag := flag.String("builtin-tools", "", "builtin tools (accepted; echoed in the boot frame)")
	reasoningLevelFlag := flag.Int("reasoning-level", 1, "initial reasoning level 0|1|2 (accepted; echoed in the boot frame and an SM reasoning frame)")
	// --llm-url <openai-base> + --llm-model <name> make fakecore act as a
	// pure protocol shim: it forwards the user prompt to a real OpenAI-
	// compatible /v1/chat/completions endpoint, streams the reply back as
	// Ar/At/AT frames, and broadcasts intermediate + final task frames
	// with the real step_tps / ttft_ms (mirrors what alayacore would
	// emit when calling that endpoint directly). Empty url = canned mode.
	flag.StringVar(&llmURL, "llm-url", "", "OpenAI-compatible base URL (e.g. http://172.16.9.6:9999/v1). Empty = canned replies.")
	flag.StringVar(&llmModel, "llm-model", "", "model name to send with the chat completions request (required when --llm-url is set)")
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
	// (the session dir already exists). On RESUME the file already exists
	// → history content frames are replayed after the boot SM frames —
	// this ORDER was verified against the real binary (alayadump: 6 boot
	// SMs first, then UT/At/AT replay). The frontend's replay suppression
	// must NOT key on the first SM; it keys on the user sending a new
	// message instead. The E2E depends on this order to exercise the
	// suppression path.
	wasResume := false
	if sessionFile != "" {
		if _, err := os.Stat(sessionFile); err == nil {
			wasResume = true
			// The file already exists (resume OR a fork wrote the truncated
			// history into it): leave it untouched so replayForkedHistory /
			// replayResumedHistory can read the real content. Only a
			// BRAND-NEW session gets the placeholder (real alayacore
			// creates session.alaya on first start).
		} else {
			_ = os.WriteFile(sessionFile, []byte(`{"version":1}`), 0o644)
		}
	}

	// Version announcement (mirrors real alayacore's first boot SM
	// {"type":"version","data":{"message_version":N,"core_version":"..."}}).
	// The frontend-side startup probe (check_alayacore) reads this
	// frame and rejects binaries whose protocol has drifted; we MUST
	// match core.SupportedMessageVersion exactly, otherwise every
	// integration test that boots fakecore via create_session / probe
	// would surface a "wrong version" error and skip the session setup.
	// The frame is emitted BEFORE the task SM, matching real alayacore's
	// documented boot order: version → task → ... → session/ready.
	version, _ := json.Marshal(map[string]any{
		"type": "version",
		"data": map[string]any{
			"message_version": core.SupportedMessageVersion,
			"core_version":    "fakecore",
		},
	})
	writeFrame("SM", string(version))

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
			"tool_confirm":      *toolConfirmFlag,
			"system":            *systemFlag,
			"reasoning_level":   *reasoningLevelFlag,
		},
	})
	writeFrame("SM", string(boot))

	// Reasoning-level notification (mirrors real alayacore's SM
	// {"type":"reasoning","data":{"level":N}} boot frame): the frontend
	// reads the level (0|1|2) from it for the session bar's reasoning
	// select.
	rl := *reasoningLevelFlag
	if rl < 0 || rl > 2 {
		rl = 1
	}
	reasoning, _ := json.Marshal(map[string]any{"type": "reasoning", "data": map[string]any{"level": rl}})
	writeFrame("SM", string(reasoning))

	// Active-model notification (mirrors real alayacore's SM "model"
	// frame): the frontend reads context_limit from it for the session
	// bar's token readout.
	writeFrame("SM", `{"type":"model","data":{"active_id":1,"active_name":"fake-model-1","context_limit":8192}}`)

	// Boot SMs first, then replayed history content, then the explicit
	// readiness signal — mirrors alayacore v0.62.4+:
	//   SM {"type":"session","data":{"state":"ready"}}
	// arrives AFTER all replayed content. The frontend removes its replay
	// suppression marker ONLY on this frame (no fallback for older cores).
	if wasResume {
		replayForkedHistory()
		replayResumedHistory()
	}
	// ALAYACORE_DELAY_READY_MS delays the ready SM (and thus prompt
	// acceptance) so the E2E can exercise the frontend's readiness gate:
	// prompts sent before this point are rejected as MCP_NOT_READY.
	if ms := os.Getenv("ALAYACORE_DELAY_READY_MS"); ms != "" {
		if n, err := time.ParseDuration(ms + "ms"); err == nil {
			time.Sleep(n)
		}
	}
	readySent = true
	writeFrame("SM", `{"type":"session","data":{"state":"ready"}}`)

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
			if frame.Tag == "UT" {
				stagedText += frame.Value
				// Record the user message (echo id = current msgSeq, the
				// same id the echo carries) for fork-history replay.
				history = append(history, histMsg{"user", frame.Value, "hist-" + fmt.Sprint(msgSeq)})
			}
		case "UE":
			if staged > 0 {
				// Mirrors real alayacore: processing a prompt starts the
				// task (in_progress:true) before any reply — even when the
				// task later hangs. The runner gates TaskDone on having
				// seen this frame (so the boot in_progress:false is not a
				// completion), so a hung task can still be aborted by the
				// cancel-first close below (which emits in_progress:false).
				// Before the ready SM, prompts are REJECTED like real
				// alayacore's MCP_NOT_READY — the frontend's readiness
				// gate must hold them until then.
				if !readySent {
					writeFrame("SM", `{"type":"error","data":{"text":"MCP servers are still initializing. Please wait."}}`)
					staged = 0
					stagedText = ""
					continue
				}
				// SM-task-start per adapter-guide: in_progress:true with
				// current_step + context; step_tps / ttft_ms are absent
				// until a step with output tokens completes.
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
					case strings.Contains(stagedText, "load-run-plan"):
						// The Load-run E2E's one-task always-failing plan
						// (checked BEFORE the generic "plan" check since
						// the keyword contains "plan").
						loadRunPlanReply()
					case planMode && strings.Contains(stagedText, "plan"):
						// R2: EVERY session now carries the planner hint
						// (--system). The fake answers with a fenced plan
						// JSON whenever the user prompt asks for planning
						// (node task prompts — the fixture — do NOT
						// contain "plan", so nodes complete normally).
						// Every "plan" prompt gets one (multi-plan
						// sessions exercise plan-index binding).
						planReply()
					case strings.Contains(stagedText, "hang-once"):
						hangOnceReply()
					case strings.Contains(stagedText, "fail-once"):
						failOnceReply()
					case strings.Contains(stagedText, "fail-always"):
						failAlwaysReply()
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

// planSeq numbers plan documents emitted by planReply: the SECOND plan
// of a session gets a distinct name ("E2E Demo Beta") so the UI/e2e can
// tell the two plan windows apart (same fixture, different planId).
// Single-plan e2es (fork/plan/restart) are unaffected (first plan keeps
// "E2E Demo").
var planSeq int

// planReply emits a complete assistant text frame carrying a fenced plan
// JSON (the Create Plan offer detector scans the final AT content), then
// a normal reply and the task-done frame.
func planReply() {
	planSeq++
	name := "E2E Demo"
	if planSeq >= 2 {
		name = "E2E Demo Beta"
	}
	body := strings.Replace(planJSON, `"name": "E2E Demo"`, `"name": "`+name+`"`, 1)
	pid := nextReplyID()
	echoID("AT", pid, "Here is the plan:\n```json\n"+body+"\n```\nI'll wait for you to create it.")
	echoID("AR", nextReplyID(), "")
	history = append(history, histMsg{"assistant", "Here is the plan:\n```json\n" + body + "\n```\nI'll wait for you to create it.", pid})
	// Mark the task complete (in_progress:false) so the frontend leaves
	// "task running" state (send button back to Send) — without this a
	// session that creates a SECOND plan can never send it (the button
	// stays Cancel).
	writeFrame("SM", taskDoneFrame())
	// NOTE: deliberately NOT calling streamReply() afterwards — the plan
	// message must stay the session's LAST message so the frontend's
	// delayed auto-open (PlanOfferSettle) confirms it as the newest.
}

// truncateHistory returns the session's history up to AND INCLUDING the
// message with the given history id (the fork point) — the truncated
// history the fork replays. Missing id → the whole history.
func truncateHistory(historyID string) []histMsg {
	for i, m := range history {
		if m.ID == historyID {
			return history[:i+1]
		}
	}
	return history
}

// replayForkedHistory replays a session's real history (written by the
// source's `fork` — truncated — or by a later `save` — complete): user
// messages as UT echoes, assistant messages as At/AT content blocks —
// the same wire format as replayResumedHistory, so the client's replay
// suppression and status-bar binding are exercised against the real
// history. The replayed messages are ALSO recorded into `history`, so a
// later `save` writes the complete conversation (real alayacore appends
// everything to session.alaya); msgSeq/replySeq advance past the
// replayed ids so new messages cannot collide with them. No-op when the
// session file carries no history.
func replayForkedHistory() {
	if sessionFile == "" {
		return
	}
	var f struct {
		Forked  bool      `json:"forked"`
		History []histMsg `json:"history"`
	}
	b, err := os.ReadFile(sessionFile)
	if err != nil {
		return
	}
	if json.Unmarshal(b, &f) != nil || len(f.History) == 0 {
		return
	}
	// Same timing rationale as replayResumedHistory: real alayacore's
	// replay takes real time, so the frames land AFTER the client's
	// SessionCreated handler registered the fresh id — exercising the
	// replay-suppression path instead of the pending-event buffer.
	time.Sleep(400 * time.Millisecond)
	assistantCount := 0
	for _, m := range f.History {
		history = append(history, m)
		if m.Role == "assistant" {
			assistantCount++
		}
		switch m.Role {
		case "user":
			writeFrame("UT", "\x00"+m.ID+"\x00"+m.Content)
		case "assistant":
			writeFrame("At", "\x00"+m.ID+"\x00"+m.Content)
			writeFrame("AT", "\x00"+m.ID+"\x00")
		}
	}
	// New messages get ids AFTER the replayed ones (no collision: every
	// fakecore process numbers its own messages from 0).
	msgSeq = len(f.History)
	replySeq = assistantCount
}

// replayResumedHistory mirrors real alayacore's resume behavior: history
// content frames are replayed BEFORE the boot SM frame. The fake replays
// a canned plan-message history for LEGACY sessions (saved before
// fakecore kept a real history — restart-e2e). A session whose file
// carries a real history (a FORK wrote the truncated history, or a
// future save) replays THAT via replayForkedHistory instead, so the two
// never double-replay.
func replayResumedHistory() {
	if sessionFile == "" {
		return
	}
	var f struct {
		Forked  bool      `json:"forked"`
		History []histMsg `json:"history"`
	}
	if b, err := os.ReadFile(sessionFile); err == nil {
		if json.Unmarshal(b, &f) == nil && (f.Forked || len(f.History) > 0) {
			return
		}
	}
	// Real alayacore's history replay takes real time, so its content
	// frames typically arrive AFTER the resume RPC response (and after
	// the client's SessionCreated handler has registered the fresh id).
	// The fake mirrors that with a short delay — without it the frames
	// would all arrive before SessionCreated and be buffered, and the
	// E2E would never exercise the replay-suppression path.
	time.Sleep(400 * time.Millisecond)
	writeFrame("UT", "\x00u-replay\x00Give me a plan")
	echoID("At", "p-replay-1", "Here is the plan:\n```json\n"+planJSON+"\n```\nI'll wait for you to create it.")
	echoID("AT", "p-replay-1", "")
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
		// Task failure: SM `error` frame marks the failure (adapter-guide
		// §692: SM `error`/`notify` are reserved for non-command events
		// including task errors), followed by a bare task_end frame
		// (no step_tps/ttft_ms — the step produced no output tokens).
		writeFrame("SM", `{"type":"error","data":{"text":"fake-once failure"}}`)
		writeFrame("SM", taskDoneBareFrame())
		return
	}
	streamReply()
}

// failAlwaysReply simulates a task that FAILS on every attempt (used to
// reach a terminal Failed node: max_attempts=1 + fail-always). Unlike
// fail-once it needs no marker — the failure is permanent.
func failAlwaysReply() {
	// Same protocol as failOnceReply: SM `error` for the failure reason,
	// then a bare task_end (no step metrics for a non-producing step).
	writeFrame("SM", `{"type":"error","data":{"text":"permanent fake failure"}}`)
	writeFrame("SM", taskDoneBareFrame())
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

// loadRunPlanJSON is a ONE-task plan whose single node fails permanently
// (max_attempts=1 + fail-always): the Load-run E2E clicks "Load run" on
// the resulting FailedRun plan to verify the failed node is revived and
// relaunched.
const loadRunPlanJSON = `{
  "type": "alayaface-plan",
  "schema_version": 1,
  "name": "Load Run E2E",
  "goal": "verify Load run revives a failed node",
  "concurrency": 1,
  "default_max_attempts": 1,
  "tasks": [
    { "id": "t1", "title": "Always fails", "prompt": "always fails (fail-always marker)", "depends_on": [], "preset": "Simple", "max_attempts": 1 }
  ]
}`

// loadRunPlanReply emits the one-task always-failing plan (triggered by a
// user prompt containing "load-run-plan"). Mirrors planReply's framing:
// AT/AR streaming + history recording + task-done.
func loadRunPlanReply() {
	pid := nextReplyID()
	msg := "Here is the plan:\n```json\n" + loadRunPlanJSON + "\n```\nI'll wait for you to create it."
	echoID("AT", pid, msg)
	echoID("AR", nextReplyID(), "")
	history = append(history, histMsg{"assistant", msg, pid})
	writeFrame("SM", taskDoneFrame())
}
