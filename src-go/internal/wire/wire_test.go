package wire

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func readOne(t *testing.T, raw []byte) (*Frame, error) {
	t.Helper()
	return ReadFrame(bufio.NewReader(bytes.NewReader(raw)))
}

func TestEncodeReadRoundtrip(t *testing.T) {
	value := `{"type":"text","text":"hello world"}`
	var buf bytes.Buffer
	if err := WriteFrame(&buf, "UX", value); err != nil {
		t.Fatal(err)
	}

	frame, err := ReadFrame(bufio.NewReader(&buf))
	if err != nil {
		t.Fatal(err)
	}
	if frame == nil {
		t.Fatal("expected a frame, got EOF")
	}
	if frame.Tag != "UX" {
		t.Errorf("tag = %q, want UX", frame.Tag)
	}
	if frame.Value != value {
		t.Errorf("value = %q, want %q", frame.Value, value)
	}
	// A control frame carries no value.
	if err := WriteFrame(&buf, "UE", ""); err != nil {
		t.Fatal(err)
	}
	// Whole stream consumed: the next read is a clean EOF.
	next, err := ReadFrame(bufio.NewReader(&buf))
	if err != nil {
		t.Fatal(err)
	}
	if next == nil {
		t.Fatal("expected the UE control frame, got EOF")
	}
	if next.Tag != "UE" || next.Value != "" {
		t.Errorf("control frame = %+v, want UE with empty value", next)
	}
}

func TestEncodeIsTagValueNewline(t *testing.T) {
	value := `{"type":"text","text":"hi"}`
	buf, err := Encode("UX", value)
	if err != nil {
		t.Fatal(err)
	}
	// [tag 2][value][\n] — no length field, no separator.
	want := "UX" + value + "\n"
	if string(buf) != want {
		t.Errorf("encoded frame = %q, want %q", buf, want)
	}
}

func TestReadFrameEOFReturnsNil(t *testing.T) {
	frame, err := readOne(t, nil)
	if err != nil {
		t.Fatal(err)
	}
	if frame != nil {
		t.Errorf("expected EOF, got %+v", frame)
	}
}

func TestReadFrameTruncatedLineIsError(t *testing.T) {
	// A stream that ends mid-frame is a failure to report, not a frame.
	if _, err := readOne(t, []byte(`UX{"type":"text"`)); err == nil {
		t.Error("expected an error for an unterminated frame")
	}
}

func TestReadFrameBlankLineIsError(t *testing.T) {
	if _, err := readOne(t, []byte("\n")); err == nil {
		t.Error("expected an error for a blank line")
	}
}

func TestReadFrameShortTagIsError(t *testing.T) {
	if _, err := readOne(t, []byte("U\n")); err == nil {
		t.Error("expected an error for a one-letter tag")
	}
}

func TestReadFrameNonLetterTagIsError(t *testing.T) {
	if _, err := readOne(t, []byte(`1X{"type":"text"}`+"\n")); err == nil {
		t.Error("expected an error for a non-letter tag")
	}
}

func TestReadFrameValueNotJSONObjectIsError(t *testing.T) {
	if _, err := readOne(t, []byte("UXhello\n")); err == nil {
		t.Error("expected an error for a value that is not a JSON object")
	}
}

func TestReadFrameAcceptsTrailingCR(t *testing.T) {
	// A writer on a platform that translates line endings emits CRLF.
	frame, err := readOne(t, []byte(`UX{"type":"text","text":"hi"}`+"\r\n"))
	if err != nil {
		t.Fatal(err)
	}
	if frame == nil || frame.Tag != "UX" || frame.Value != `{"type":"text","text":"hi"}` {
		t.Errorf("CRLF frame = %+v", frame)
	}
}

func TestEncodeRejectsBadInput(t *testing.T) {
	cases := []struct {
		name  string
		tag   string
		value string
	}{
		{"short tag", "U", "{}"},
		{"non-letter tag", "1X", "{}"},
		{"value not an object", "UX", "hello"},
		{"value with raw LF", "UX", "{\n}"},
		{"value with raw CR", "UX", "{\r}"},
	}
	for _, tc := range cases {
		if _, err := Encode(tc.tag, tc.value); err == nil {
			t.Errorf("%s: expected an encode error", tc.name)
		}
	}
}

func TestEncodeRejectsOversizedFrame(t *testing.T) {
	// A frame is tag + value + terminator; one byte over the bound is refused
	// without building it.
	value := "{" + strings.Repeat("x", MaxFrameSize) + "}"
	if _, err := Encode("UX", value); err == nil {
		t.Error("expected an error for an oversized frame")
	}
}

// TestContentDataRoundtrip pins the v14+ content-frame body: a content item's
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

	cmd := CmdMsg{CommandID: "c1", Name: "save", Args: "/tmp/x"}
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
	if backCmd.Args != "/tmp/x" {
		t.Errorf("args = %q, want /tmp/x", backCmd.Args)
	}
	if backCmd.CommandID != "c1" {
		t.Errorf("command_id = %q, want c1", backCmd.CommandID)
	}
}
