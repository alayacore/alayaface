package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// M1 truth table (D3): event payload serialization must produce the
// exact JSON bytes recorded in the shared fixture
// testdata/serialization/event_cases.json — the same fixture the Rust
// side (src-tauri/src/event.rs) is tested against. Any field-name,
// key-order or null-semantics drift between the backends breaks one of
// the two suites. See REFACTOR.md M1.

type eventFixture struct {
	Frame  []frameCase  `json:"frame"`
	Delta  []deltaCase  `json:"delta"`
	Status []statusCase `json:"status"`
}

type frameCase struct {
	Name     string     `json:"name"`
	Input    frameInput `json:"input"`
	Expected string     `json:"expected"`
}

type frameInput struct {
	SessionID       string  `json:"session_id"`
	Tag             string  `json:"tag"`
	RawValue        string  `json:"raw_value"`
	HistoryID       *string `json:"history_id"`
	Content         *string `json:"content"`
	JSON            *string `json:"json"` // raw JSON text, or null
	UserContentType *string `json:"user_content_type"`
}

type deltaCase struct {
	Name     string      `json:"name"`
	Input    deltaInput  `json:"input"`
	Expected string      `json:"expected"`
}

type deltaInput struct {
	SessionID string `json:"session_id"`
	HistoryID string `json:"history_id"`
	Content   string `json:"content"`
	Tag       string `json:"tag"`
}

type statusCase struct {
	Name     string       `json:"name"`
	Input    statusInput  `json:"input"`
	Expected string       `json:"expected"`
}

type statusInput struct {
	SessionID string `json:"session_id"`
	Connected bool   `json:"connected"`
	Message   string `json:"message"`
}

func loadEventFixture(t *testing.T) eventFixture {
	t.Helper()
	path := filepath.Join("..", "..", "..", "testdata", "serialization", "event_cases.json")
	text, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var fx eventFixture
	if err := json.Unmarshal(text, &fx); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	return fx
}

func TestFrameEventSerializationMatchesSharedFixture(t *testing.T) {
	fx := loadEventFixture(t)
	for _, c := range fx.Frame {
		t.Run(c.Name, func(t *testing.T) {
			var jm json.RawMessage
			if c.Input.JSON != nil {
				jm = json.RawMessage(*c.Input.JSON)
			}
			ev := FrameEvent{
				SessionID:       c.Input.SessionID,
				Tag:             c.Input.Tag,
				RawValue:        c.Input.RawValue,
				HistoryID:       c.Input.HistoryID,
				Content:         c.Input.Content,
				JSON:            jm,
				UserContentType: c.Input.UserContentType,
			}
			got, err := json.Marshal(ev)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != c.Expected {
				t.Errorf("FrameEvent JSON mismatch\ngot:  %s\nwant: %s", got, c.Expected)
			}
		})
	}
}

func TestDeltaEventSerializationMatchesSharedFixture(t *testing.T) {
	fx := loadEventFixture(t)
	for _, c := range fx.Delta {
		t.Run(c.Name, func(t *testing.T) {
			ev := DeltaEvent{
				SessionID: c.Input.SessionID,
				HistoryID: c.Input.HistoryID,
				Content:   c.Input.Content,
				Tag:       c.Input.Tag,
			}
			got, err := json.Marshal(ev)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != c.Expected {
				t.Errorf("DeltaEvent JSON mismatch\ngot:  %s\nwant: %s", got, c.Expected)
			}
		})
	}
}

func TestStatusEventSerializationMatchesSharedFixture(t *testing.T) {
	fx := loadEventFixture(t)
	for _, c := range fx.Status {
		t.Run(c.Name, func(t *testing.T) {
			ev := StatusEvent{
				SessionID: c.Input.SessionID,
				Connected: c.Input.Connected,
				Message:   c.Input.Message,
			}
			got, err := json.Marshal(ev)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if string(got) != c.Expected {
				t.Errorf("StatusEvent JSON mismatch\ngot:  %s\nwant: %s", got, c.Expected)
			}
		})
	}
}
