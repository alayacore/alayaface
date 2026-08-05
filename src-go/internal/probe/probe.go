// Package probe runs throwaway alayacore processes to query configs
// without touching any running session. Port of the TempCore /
// run_temp_probe machinery in src-tauri/src/commands/models.rs.
package probe

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"os/exec"
	"time"

	"alayaface/src-go/internal/core"
	"alayaface/src-go/internal/session"
	"alayaface/src-go/internal/tlv"
)

// ProbeEnd is why a probe stopped reading.
type ProbeEnd int

const (
	// EndComplete means the target frame(s) arrived.
	EndComplete ProbeEnd = iota
	// EndTimeout means nothing arrived within the timeout.
	EndTimeout
	// EndEOF means alayacore closed stdout (exited).
	EndEOF
	// EndReadError means reading stdout failed.
	EndReadError
)

// ProbeCmd optionally sends one CI command first.
type ProbeCmd struct {
	CallID string
	Name   string
	Input  string
}

// ProbeResult is what a probe collected.
type ProbeResult struct {
	// Models is the first SM model_list payload, if seen.
	Models []json.RawMessage
	// CmdOutput is the full CO frame JSON matching the probe's call ID.
	CmdOutput json.RawMessage
	// End is why the read loop stopped.
	End ProbeEnd
}

// RunTempProbe spawns a temporary alayacore and optionally sends one CI
// command, then reads TLV frames until the SM model_list (and/or the
// matching CO) arrives or a 5s timeout elapses. modelCache, when given,
// is refreshed from any SM model_list seen (mirrors live sessions).
func RunTempProbe(bin, configPath string, cmd *ProbeCmd, modelCache *session.ModelCache) (*ProbeResult, error) {
	args := []string{"--rawio"}
	if configPath != "" {
		args = append(args, "--config-path", configPath)
	}
	c := exec.Command(bin, args...)
	stdin, err := c.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := c.StdoutPipe()
	if err != nil {
		return nil, err
	}
	c.Stderr = nil // discard (unlike live sessions, which inherit stderr)
	if err := c.Start(); err != nil {
		return nil, fmt.Errorf("Failed to start alayacore: %w", err)
	}
	defer core.KillChild(c)

	// Optionally send one command, then close stdin.
	if cmd != nil {
		payload, _ := json.Marshal(tlv.CmdMsg{ID: cmd.CallID, Name: cmd.Name, Input: cmd.Input})
		preview := string(payload)
		if len(preview) > 200 {
			preview = preview[:200]
		}
		log.Printf("[tlv] >> temp %s %db %s", tlv.TagCmdInput, len(payload), preview)
		_ = tlv.WriteFrame(stdin, tlv.TagCmdInput, string(payload))
	}
	_ = stdin.Close()

	start := time.Now()
	timeout := 5 * time.Second
	result := &ProbeResult{End: EndTimeout}

	reader := bufio.NewReader(stdout)
	for {
		if time.Since(start) > timeout {
			result.End = EndTimeout
			break
		}
		frame, err := tlv.ReadFrame(reader)
		if err != nil {
			result.End = EndReadError
			break
		}
		if frame == nil {
			result.End = EndEOF
			break
		}
		preview := frame.Value
		if len(preview) > 200 {
			preview = preview[:200]
		}
		log.Printf("[tlv] << temp %s %db %s", frame.Tag, len(frame.Value), preview)

		switch frame.Tag {
		case "SM":
			var env tlv.SystemMsgEnvelope
			if err := json.Unmarshal([]byte(frame.Value), &env); err == nil && env.Type == "model_list" {
				var data struct {
					Models []json.RawMessage `json:"models"`
				}
				if err := json.Unmarshal(env.Data, &data); err == nil && data.Models != nil {
					result.Models = data.Models
					if modelCache != nil {
						modelCache.Set(data.Models)
					}
				}
			}
			// Without a pending command the model list is all we need;
			// with a pending command we must keep reading for the CO.
			if cmd == nil && result.Models != nil {
				result.End = EndComplete
				goto done
			}
		case "CO":
			var v map[string]any
			if err := json.Unmarshal([]byte(frame.Value), &v); err == nil {
				isOurs := true
				if cmd != nil {
					isOurs = v["id"] == cmd.CallID
				}
				if isOurs {
					result.CmdOutput = json.RawMessage(frame.Value)
					result.End = EndComplete
					goto done
				}
			}
		}
	}
done:
	return result, nil
}
