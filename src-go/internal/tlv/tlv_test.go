package tlv

import (
	"bytes"
	"encoding/json"
	"testing"
)

func TestEncodeReadRoundtrip(t *testing.T) {
	var buf bytes.Buffer
	if err := WriteFrame(&buf, "UX", "hello \u0000 world"); err != nil {
		t.Fatal(err)
	}

	frame, err := ReadFrame(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if frame == nil {
		t.Fatal("expected a frame, got EOF")
	}
	if frame.Tag != "UX" {
		t.Errorf("tag = %q, want UX", frame.Tag)
	}
	if frame.Value != "hello \u0000 world" {
		t.Errorf("value = %q, want %q", frame.Value, "hello \u0000 world")
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
	buf := Encode("UX", value)
	// [tag 2][len 4][value]
	if string(buf[0:2]) != "UX" {
		t.Errorf("tag = %q, want UX", buf[0:2])
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
	frame, err := ReadFrame(bytes.NewReader([]byte("UX\x00\x01")))
	if err != nil {
		t.Fatal(err)
	}
	if frame != nil {
		t.Errorf("expected EOF, got %+v", frame)
	}
}

func TestReadFrameShortValueIsError(t *testing.T) {
	// Build manually: tag UX, len 10, then only 3 value bytes.
	raw := append(Encode("UX", "0123456789")[:6], []byte("abc")...)
	if _, err := ReadFrame(bytes.NewReader(raw)); err == nil {
		t.Error("expected protocol error for short value read")
	}
}

func TestReadFrameTooLargeIsError(t *testing.T) {
	// Header claims MaxFrameSize+1 bytes; must be rejected without
	// allocating the frame.
	tooBig := uint32(MaxFrameSize) + 1
	raw := []byte{'U', 'X', byte(tooBig >> 24), byte(tooBig >> 16), byte(tooBig >> 8), byte(tooBig)}
	if _, err := ReadFrame(bytes.NewReader(raw)); err == nil {
		t.Error("expected error for oversized frame")
	}
}

// TestContentDataRoundtrip pins the v14 content-frame body: a content item's
// kind travels in "type", the history id in "id", and the message time in
// "time".
func TestContentDataRoundtrip(t *testing.T) {
	data := ContentData{
		ContentMeta: ContentMeta{ID: "7", Time: "2026-10-14T02:06:07Z"},
		ContentItem: ContentItem{Type: "text", Text: "hi"},
	}
	b, err := json.Marshal(data)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != `{"id":"7","time":"2026-10-14T02:06:07Z","type":"text","text":"hi"}` {
		t.Errorf("content body = %s", b)
	}
	var back ContentData
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if back.ID != "7" || back.Type != "text" || back.Text != "hi" {
		t.Errorf("roundtrip = %+v", back)
	}
}

func TestJSONPayloadsRoundtrip(t *testing.T) {
	out := ToolOutputData{
		CallID: "t5",
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
	if back.CallID != "t5" {
		t.Errorf("call_id = %q, want t5", back.CallID)
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

	cmd := CmdMsg{CallID: "c1", Name: "save", Input: "/tmp/x"}
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
	if backCmd.CallID != "c1" {
		t.Errorf("call_id = %q, want c1", backCmd.CallID)
	}
}
