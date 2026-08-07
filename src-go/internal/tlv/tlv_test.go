package tlv

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestEncodeReadRoundtrip(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteFrame(&buf, "UT", "hello \x00 world"); err != nil {
		t.Fatal(err)
	}

	frame, err := ReadFrame(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if frame == nil {
		t.Fatal("expected a frame, got EOF")
	}
	if frame.Tag != "UT" {
		t.Errorf("tag = %q, want UT", frame.Tag)
	}
	if frame.Value != "hello \x00 world" {
		t.Errorf("value = %q, want %q", frame.Value, "hello \x00 world")
	}
	// Whole buffer consumed.
	next, err := ReadFrame(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if next != nil {
		t.Errorf("expected EOF, got frame %+v", next)
	}
}

func TestEncodeUsesBigEndianLength(t *testing.T) {
	value := ""
	for i := 0; i < 300; i++ {
		value += "x"
	}
	buf := Encode("UT", value)
	// [tag 2][len 4][value]
	if string(buf[0:2]) != "UT" {
		t.Errorf("tag = %q, want UT", buf[0:2])
	}
	length := uint32(buf[2])<<24 | uint32(buf[3])<<16 | uint32(buf[4])<<8 | uint32(buf[5])
	if length != 300 {
		t.Errorf("length = %d, want 300", length)
	}
	if !bytes.Equal(buf[6:], []byte(value)) {
		t.Error("value mismatch")
	}
}

func TestReadFrameEOFReturnsNil(t *testing.T) {
	frame, err := ReadFrame(bytes.NewReader(nil))
	if err != nil {
		t.Fatal(err)
	}
	if frame != nil {
		t.Errorf("expected EOF, got %+v", frame)
	}
}

func TestReadFrameShortHeaderIsEOF(t *testing.T) {
	// Only 3 bytes of header available.
	frame, err := ReadFrame(bytes.NewReader([]byte("UT\x00\x01")))
	if err != nil {
		t.Fatal(err)
	}
	if frame != nil {
		t.Errorf("expected EOF, got %+v", frame)
	}
}

func TestReadFrameShortValueIsError(t *testing.T) {
	// Build manually: tag UT, len 10, then only 3 value bytes.
	raw := append(Encode("UT", "0123456789")[:6], []byte("abc")...)
	if _, err := ReadFrame(bytes.NewReader(raw)); err == nil {
		t.Error("expected protocol error for short value read")
	}
}

func TestUnwrapDeltaWithoutNulPrefix(t *testing.T) {
	parts := UnwrapDelta("plain")
	if parts.HasDelta {
		t.Error("expected HasDelta=false")
	}
	if parts.HistoryID != "" {
		t.Errorf("history_id = %q, want empty", parts.HistoryID)
	}
	if parts.Content != "plain" {
		t.Errorf("content = %q, want plain", parts.Content)
	}
}

func TestUnwrapDeltaEmptyValue(t *testing.T) {
	parts := UnwrapDelta("")
	if parts.HasDelta {
		t.Error("expected HasDelta=false")
	}
	if parts.Content != "" {
		t.Errorf("content = %q, want empty", parts.Content)
	}
}

func TestUnwrapDeltaWithEmptyID(t *testing.T) {
	parts := UnwrapDelta("\x00\x00content")
	if parts.HasDelta {
		t.Error("expected HasDelta=false for empty id")
	}
	if parts.Content != "\x00\x00content" {
		t.Errorf("content = %q, want original value", parts.Content)
	}
}

func TestUnwrapDeltaValid(t *testing.T) {
	parts := UnwrapDelta("\x00abc-123\x00{\"id\":\"t1\"}")
	if !parts.HasDelta {
		t.Fatal("expected HasDelta=true")
	}
	if parts.HistoryID != "abc-123" {
		t.Errorf("history_id = %q, want abc-123", parts.HistoryID)
	}
	if parts.Content != "{\"id\":\"t1\"}" {
		t.Errorf("content = %q, want %q", parts.Content, "{\"id\":\"t1\"}")
	}
}

func TestUnwrapDeltaKeepsEmbeddedNulsInContent(t *testing.T) {
	// Content after the history ID may itself contain NULs (raw values).
	parts := UnwrapDelta("\x00id\x00a\x00b")
	if !parts.HasDelta {
		t.Fatal("expected HasDelta=true")
	}
	if parts.HistoryID != "id" {
		t.Errorf("history_id = %q, want id", parts.HistoryID)
	}
	if parts.Content != "a\x00b" {
		t.Errorf("content = %q, want %q", parts.Content, "a\x00b")
	}
}

func TestWrapDeltaRoundtrips(t *testing.T) {
	wrapped := "\x00h1\x00payload"
	parts := UnwrapDelta(wrapped)
	if !parts.HasDelta {
		t.Fatal("expected HasDelta=true")
	}
	if parts.HistoryID != "h1" {
		t.Errorf("history_id = %q, want h1", parts.HistoryID)
	}
	if parts.Content != "payload" {
		t.Errorf("content = %q, want payload", parts.Content)
	}
}

func TestReadFrameTooLargeIsError(t *testing.T) {
	// Header claims MaxFrameSize+1 bytes; must be rejected without
	// allocating the frame.
	tooBig := uint32(MaxFrameSize) + 1
	raw := []byte{'U', 'T', byte(tooBig >> 24), byte(tooBig >> 16), byte(tooBig >> 8), byte(tooBig)}
	if _, err := ReadFrame(bytes.NewReader(raw)); err == nil {
		t.Error("expected error for oversized frame")
	}
}

func TestJSONPayloadsRoundtrip(t *testing.T) {
	out := ToolOutputData{
		ID:     "t5",
		Output: json.RawMessage(`[{"type": "text", "text": "ok"}]`),
	}
	s, err := json.Marshal(out)
	if err != nil {
		t.Fatal(err)
	}
	var back ToolOutputData
	if err := json.Unmarshal(s, &back); err != nil {
		t.Fatal(err)
	}
	if back.ID != "t5" {
		t.Errorf("id = %q, want t5", back.ID)
	}
	if back.IsError {
		t.Error("is_error should default to false")
	}
	var arr []map[string]any
	if err := json.Unmarshal(back.Output, &arr); err != nil {
		t.Fatal(err)
	}
	if arr[0]["text"] != "ok" {
		t.Errorf("output[0].text = %v, want ok", arr[0]["text"])
	}

	cmd := CmdMsg{ID: "c1", Name: "save", Input: "/tmp/x"}
	s, err = json.Marshal(cmd)
	if err != nil {
		t.Fatal(err)
	}
	var backCmd CmdMsg
	if err := json.Unmarshal(s, &backCmd); err != nil {
		t.Fatal(err)
	}
	if backCmd.Name != "save" {
		t.Errorf("name = %q, want save", backCmd.Name)
	}
	if backCmd.Input != "/tmp/x" {
		t.Errorf("input = %q, want /tmp/x", backCmd.Input)
	}
}
