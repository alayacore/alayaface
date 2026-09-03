package handlers

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"alayaface/src-go/internal/dirs"
)

func TestAsrConfigMissingYieldsDefault(t *testing.T) {
	isolatedHome(t, func() {
		cfg, err := readAsrConfig()
		if err != nil {
			t.Fatal(err)
		}
		if len(cfg.Profiles) != 0 || cfg.Active != "" {
			t.Errorf("defaults wrong: %+v", cfg)
		}
	})
}

func TestNormalizeAsrProfile(t *testing.T) {
	p := AsrProfile{Name: "  ", Protocol: "bogus", Model: "  ", Language: ""}
	NormalizeAsrProfile(&p)
	if p.ID == "" || p.Name != "ASR" || p.Protocol != ProtocolTranscriptions || p.Model != "whisper-1" || p.Language != "auto" {
		t.Errorf("normalize wrong: %+v", p)
	}
}

// TestDefaultAsrModelIsProtocolAware pins the bug where a step_audio
// profile with no explicit model was handed "whisper-1": the per-protocol
// fallback inside asrTranscribeStepAudio could never fire because every
// profile is normalized on read AND write, so normalize's (transcription)
// default always won. Mirrors Rust's default_model_is_protocol_aware.
func TestDefaultAsrModelIsProtocolAware(t *testing.T) {
	if got := DefaultAsrModel(ProtocolStepAudio); got != "stepaudio-2.5-asr" {
		t.Errorf("step_audio default model = %q, want stepaudio-2.5-asr", got)
	}
	if got := DefaultAsrModel(ProtocolTranscriptions); got != "whisper-1" {
		t.Errorf("transcriptions default model = %q, want whisper-1", got)
	}
	if got := DefaultAsrModel(ProtocolChatCompletions); got != "whisper-1" {
		t.Errorf("chat_completions default model = %q, want whisper-1", got)
	}

	p := AsrProfile{Protocol: ProtocolStepAudio, URL: "https://api.stepfun.com/asr", Model: "  "}
	NormalizeAsrProfile(&p)
	if p.Model != "stepaudio-2.5-asr" {
		t.Errorf("normalized step_audio model = %q, want stepaudio-2.5-asr", p.Model)
	}
	// An explicit model is never overwritten.
	p2 := AsrProfile{Protocol: ProtocolStepAudio, URL: "u", Model: "my-model"}
	NormalizeAsrProfile(&p2)
	if p2.Model != "my-model" {
		t.Errorf("explicit model was replaced: %q", p2.Model)
	}
}

func TestNormalizeAsrConfigActiveFallback(t *testing.T) {
	cfg := AsrConfig{
		Active: "missing",
		Profiles: []AsrProfile{
			{ID: "", Name: "A", Protocol: ProtocolChatCompletions, URL: "https://x/v1/chat/completions", Model: "m", Language: "zh"},
			{ID: "p2", Name: "B", URL: "http://y/v1/audio/transcriptions"},
		},
	}
	NormalizeAsrConfig(&cfg)
	if cfg.Profiles[0].ID == "" {
		t.Error("profile id must be generated")
	}
	// Active fell back to the first profile.
	if cfg.Active != cfg.Profiles[0].ID {
		t.Errorf("active = %q, want first profile id %q", cfg.Active, cfg.Profiles[0].ID)
	}
	if p := activeAsrProfile(&cfg); p == nil || p.ID != cfg.Active {
		t.Errorf("activeAsrProfile = %+v", p)
	}
	// Chat profile keeps its protocol.
	if cfg.Profiles[0].Protocol != ProtocolChatCompletions {
		t.Errorf("protocol = %q", cfg.Profiles[0].Protocol)
	}
}

func TestNormalizeAsrConfigKeepsValidActive(t *testing.T) {
	cfg := AsrConfig{
		Active:   "p1",
		Profiles: []AsrProfile{{ID: "p1", Name: "A", URL: "http://x"}},
	}
	NormalizeAsrConfig(&cfg)
	if cfg.Active != "p1" {
		t.Errorf("active = %q, want p1", cfg.Active)
	}
}

func TestAsrConfigSyncRoundtrips(t *testing.T) {
	isolatedHome(t, func() {
		rr := call(t, SyncAsrConfig, map[string]any{
			"config": `{"profiles":[{"name":"MiMo","protocol":"chat_completions","url":"https://api.xiaomimimo.com/v1/chat/completions","api_key":"k","model":"","language":"zh"}]}`,
		})
		if rr.Code != 200 {
			t.Fatalf("sync status = %d, body %s", rr.Code, rr.Body.String())
		}
		var out AsrConfig
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if len(out.Profiles) != 1 || out.Profiles[0].ID == "" || out.Profiles[0].Name != "MiMo" || out.Profiles[0].Model != "whisper-1" {
			t.Errorf("sync returned %+v", out)
		}
		if out.Active != out.Profiles[0].ID {
			t.Errorf("active = %q, want first profile", out.Active)
		}
		cfg, err := readAsrConfig()
		if err != nil {
			t.Fatal(err)
		}
		if len(cfg.Profiles) != 1 || cfg.Profiles[0].APIKey != "k" || cfg.Active != cfg.Profiles[0].ID {
			t.Errorf("read back %+v", cfg)
		}
	})
}

func TestAsrConfigSyncRejectsInvalid(t *testing.T) {
	isolatedHome(t, func() {
		if err := callErr(t, SyncAsrConfig, map[string]any{"config": `{not json`}); err == nil {
			t.Error("expected error for invalid JSON")
		}
		if _, err := os.Stat(dirs.AsrConfigFile()); !os.IsNotExist(err) {
			t.Errorf("invalid sync must not create asr.conf (err=%v)", err)
		}
	})
}

// fakeAsrServer serves an OpenAI-compatible /audio/transcriptions
// endpoint: asserts the multipart fields, records the audio bytes, and
// answers {"text": "hello world"}.
func fakeAsrServer(t *testing.T) (*httptest.Server, *[]byte, *[]string) {
	t.Helper()
	var audio []byte
	var fields []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/audio/transcriptions" {
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(404)
			return
		}
		if got := r.Header.Get("Authorization"); got != "Bearer testkey" {
			t.Errorf("Authorization = %q, want Bearer testkey", got)
		}
		if err := r.ParseMultipartForm(1 << 20); err != nil {
			t.Error(err)
			w.WriteHeader(400)
			return
		}
		f, fh, err := r.FormFile("file")
		if err != nil {
			t.Errorf("missing file part: %v", err)
			w.WriteHeader(400)
			return
		}
		audio, _ = io.ReadAll(f)
		if fh.Filename != "audio.wav" {
			t.Errorf("filename = %q, want audio.wav", fh.Filename)
		}
		fields = append(fields, r.MultipartForm.Value["model"]...)
		fields = append(fields, r.MultipartForm.Value["language"]...)
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"text": "hello world"}`))
	}))
	return srv, &audio, &fields
}

func TestAsrTranscribeRemoteEndpoint(t *testing.T) {
	isolatedHome(t, func() {
		srv, audio, fields := fakeAsrServer(t)
		defer srv.Close()

		p := AsrProfile{
			ID:       "p1",
			Name:     "test",
			Protocol: ProtocolTranscriptions,
			URL:      srv.URL + "/v1/audio/transcriptions",
			APIKey:   "testkey",
			Model:    "whisper-1",
			Language: "zh",
		}
		res := asrTranscribeMultipart(p, []byte("RIFF-fake-wav"))
		if !res.Ok || res.Text != "hello world" || res.Error != "" {
			t.Errorf("result = %+v", res)
		}
		if string(*audio) != "RIFF-fake-wav" {
			t.Errorf("audio roundtrip failed: %q", *audio)
		}
		if len(*fields) != 2 || (*fields)[0] != "whisper-1" || (*fields)[1] != "zh" {
			t.Errorf("multipart fields = %v", *fields)
		}
	})
}

func TestAsrTranscribeSkipsAutoLanguage(t *testing.T) {
	isolatedHome(t, func() {
		srv, _, fields := fakeAsrServer(t)
		defer srv.Close()

		p := AsrProfile{ID: "p1", Protocol: ProtocolTranscriptions, URL: srv.URL + "/v1/audio/transcriptions", APIKey: "testkey", Language: "auto"}
		res := asrTranscribeMultipart(p, []byte("RIFF-fake-wav"))
		if !res.Ok {
			t.Errorf("result = %+v", res)
		}
		// Only the model field is sent; "auto" must be omitted.
		if len(*fields) != 1 || (*fields)[0] != "whisper-1" {
			t.Errorf("multipart fields = %v", *fields)
		}
	})
}

func TestAsrTranscribeUsesUrlVerbatim(t *testing.T) {
	isolatedHome(t, func() {
		// The configured URL must be used as-is — nothing appended.
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.URL.Path != "/custom/endpoint" {
				t.Errorf("path = %s, want /custom/endpoint", r.URL.Path)
				w.WriteHeader(404)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"text":"ok"}`))
		}))
		defer srv.Close()

		res := asrTranscribeMultipart(AsrProfile{Protocol: ProtocolTranscriptions, URL: srv.URL + "/custom/endpoint"}, []byte("RIFF-fake-wav"))
		if !res.Ok || res.Text != "ok" {
			t.Errorf("result = %+v", res)
		}
	})
}

func TestAsrTranscribeUnconfigured(t *testing.T) {
	isolatedHome(t, func() {
		res := asrTranscribeMultipart(AsrProfile{Protocol: ProtocolTranscriptions}, []byte("RIFF-fake-wav"))
		if res.Ok || !strings.Contains(res.Error, "not configured") {
			t.Errorf("result = %+v", res)
		}
	})
}

func TestAsrTranscribeHTTPError(t *testing.T) {
	isolatedHome(t, func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(401)
			w.Write([]byte(`{"error": "bad key"}`))
		}))
		defer srv.Close()

		res := asrTranscribeMultipart(AsrProfile{Protocol: ProtocolTranscriptions, URL: srv.URL, APIKey: "bad"}, []byte("RIFF-fake-wav"))
		if res.Ok || !strings.Contains(res.Error, "401") {
			t.Errorf("result = %+v", res)
		}
	})
}

// fakeChatAsrServer serves a chat-completions style ASR endpoint (MiMo):
// asserts the api-key header and JSON body shape, records the audio
// base64, and answers an SSE stream.
func fakeChatAsrServer(t *testing.T) (*httptest.Server, *string) {
	t.Helper()
	var audioBase64 string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/chat/completions" {
			t.Errorf("unexpected path %s", r.URL.Path)
			w.WriteHeader(404)
			return
		}
		if got := r.Header.Get("api-key"); got != "testkey" {
			t.Errorf("api-key header = %q, want testkey", got)
		}
		if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			t.Errorf("Content-Type = %q, want application/json", ct)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("bad JSON body: %v", err)
			w.WriteHeader(400)
			return
		}
		if body["model"] != "mimo-v2.5-asr" {
			t.Errorf("model = %v", body["model"])
		}
		if body["stream"] != true {
			t.Errorf("stream = %v, want true", body["stream"])
		}
		messages, _ := body["messages"].([]any)
		if len(messages) != 1 {
			t.Errorf("messages = %v", body["messages"])
		}
		content, _ := messages[0].(map[string]any)["content"].([]any)
		if len(content) != 1 {
			t.Errorf("content = %v", content)
		}
		part := content[0].(map[string]any)
		if part["type"] != "input_audio" {
			t.Errorf("part type = %v", part["type"])
		}
		ia, _ := part["input_audio"].(map[string]any)
		audioBase64, _ = ia["data"].(string)
		if ia["format"] != "wav" {
			t.Errorf("format = %v", ia["format"])
		}
		if ao, _ := body["asr_options"].(map[string]any); ao["language"] != "zh" {
			t.Errorf("asr_options = %v", body["asr_options"])
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n" +
			"data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n" +
			"data: [DONE]\n\n"))
	}))
	return srv, &audioBase64
}

func TestAsrTranscribeChatSSE(t *testing.T) {
	isolatedHome(t, func() {
		srv, audioBase64 := fakeChatAsrServer(t)
		defer srv.Close()

		p := AsrProfile{
			ID:       "p1",
			Protocol: ProtocolChatCompletions,
			URL:      srv.URL + "/v1/chat/completions",
			APIKey:   "testkey",
			Model:    "mimo-v2.5-asr",
			Language: "zh",
		}
		res := asrTranscribeChat(p, base64.StdEncoding.EncodeToString([]byte("RIFF-fake-wav")), []byte("RIFF-fake-wav"))
		if !res.Ok || res.Text != "hello" {
			t.Errorf("result = %+v", res)
		}
		decoded, err := base64.StdEncoding.DecodeString(*audioBase64)
		if err != nil || string(decoded) != "RIFF-fake-wav" {
			t.Errorf("audio base64 roundtrip failed: %q err=%v", *audioBase64, err)
		}
	})
}

func TestAsrTranscribeChatPlainJsonFallback(t *testing.T) {
	isolatedHome(t, func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte(`{"choices":[{"message":{"content":"plain hello"}}]}`))
		}))
		defer srv.Close()

		res := asrTranscribeChat(AsrProfile{Protocol: ProtocolChatCompletions, URL: srv.URL}, "QUk=", []byte("RIFF-fake-wav"))
		if !res.Ok || res.Text != "plain hello" {
			t.Errorf("result = %+v", res)
		}
	})
}

func TestAsrTranscribeChatHTTPError(t *testing.T) {
	isolatedHome(t, func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(400)
			w.Write([]byte(`{"error":{"message":"Invalid JSON in request body"}}`))
		}))
		defer srv.Close()

		res := asrTranscribeChat(AsrProfile{Protocol: ProtocolChatCompletions, URL: srv.URL}, "QUk=", []byte("RIFF-fake-wav"))
		if res.Ok || !strings.Contains(res.Error, "400") {
			t.Errorf("result = %+v", res)
		}
	})
}

// makeWav builds a minimal 16-bit mono PCM WAV with the given sample
// rate and payload.
func makeWav(rate uint32, payload []byte) []byte {
	wav := make([]byte, 0, 44+len(payload))
	wav = append(wav, []byte("RIFF")...)
	size := 36 + uint32(len(payload))
	wav = append(wav, byte(size), byte(size>>8), byte(size>>16), byte(size>>24))
	wav = append(wav, []byte("WAVE")...)
	wav = append(wav, []byte("fmt ")...)
	wav = append(wav, 16, 0, 0, 0) // fmt size
	wav = append(wav, 1, 0)        // PCM
	wav = append(wav, 1, 0)        // mono
	wav = append(wav, byte(rate), byte(rate>>8), byte(rate>>16), byte(rate>>24))
	byteRate := rate * 2
	wav = append(wav, byte(byteRate), byte(byteRate>>8), byte(byteRate>>16), byte(byteRate>>24))
	wav = append(wav, 2, 0)  // block align
	wav = append(wav, 16, 0) // bits
	wav = append(wav, []byte("data")...)
	dataSize := uint32(len(payload))
	wav = append(wav, byte(dataSize), byte(dataSize>>8), byte(dataSize>>16), byte(dataSize>>24))
	wav = append(wav, payload...)
	return wav
}

// fakeStepAudioServer serves a StepFun StepAudio endpoint: asserts the
// headers (Content-Type/Accept/Authorization), the JSON body shape
// (format from the WAV header, raw PCM base64 in audio.data), and
// answers an SSE stream with delta/done events.
func fakeStepAudioServer(t *testing.T) (*httptest.Server, *string) {
	t.Helper()
	var audioBase64 string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if ct := r.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
			t.Errorf("Content-Type = %q", ct)
		}
		if got := r.Header.Get("Accept"); got != "text/event-stream" {
			t.Errorf("Accept = %q, want text/event-stream", got)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer stepkey" {
			t.Errorf("Authorization = %q, want Bearer stepkey", got)
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("bad JSON body: %v", err)
			w.WriteHeader(400)
			return
		}
		audio, _ := body["audio"].(map[string]any)
		audioBase64, _ = audio["data"].(string)
		input, _ := audio["input"].(map[string]any)
		tr, _ := input["transcription"].(map[string]any)
		if tr["model"] != "stepaudio-2.5-asr" || tr["language"] != "zh" {
			t.Errorf("transcription = %v", tr)
		}
		if tr["enable_itn"] != true || tr["enable_timestamp"] != true {
			t.Errorf("enable flags = %v", tr)
		}
		f, _ := input["format"].(map[string]any)
		if f["type"] != "pcm" || f["codec"] != "pcm_s16le" || f["rate"] != float64(16000) || f["bits"] != float64(16) || f["channel"] != float64(1) {
			t.Errorf("format = %v", f)
		}
		w.Header().Set("Content-Type", "text/event-stream")
		w.Write([]byte("data: {\"type\":\"transcript.text.delta\",\"delta\":\"识别\"}\n\n" +
			"data: {\"type\":\"transcript.text.delta\",\"delta\":\"的文字\"}\n\n" +
			"data: {\"type\":\"transcript.text.done\",\"text\":\"识别的完整文字\"}\n\n"))
	}))
	return srv, &audioBase64
}

func TestAsrTranscribeStepAudio(t *testing.T) {
	isolatedHome(t, func() {
		srv, audioBase64 := fakeStepAudioServer(t)
		defer srv.Close()

		payload := []byte{0, 0, 1, 0, 2, 0, 3, 0}
		wav := makeWav(16000, payload)
		p := AsrProfile{
			ID:       "p1",
			Name:     "step",
			Protocol: ProtocolStepAudio,
			URL:      srv.URL,
			APIKey:   "stepkey",
			Model:    "",
			Language: "zh",
		}
		res := asrTranscribeStepAudio(p, wav)
		if !res.Ok || res.Text != "识别的完整文字" {
			t.Errorf("result = %+v", res)
		}
		// The payload is RAW PCM: the WAV header is stripped.
		decoded, err := base64.StdEncoding.DecodeString(*audioBase64)
		if err != nil || string(decoded) != string(payload) {
			t.Errorf("pcm roundtrip failed: %q err=%v", *audioBase64, err)
		}
	})
}

func TestAsrTranscribeStepAudioErrorEvent(t *testing.T) {
	isolatedHome(t, func() {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "text/event-stream")
			w.Write([]byte("data: {\"type\":\"error\",\"message\":\"invalid audio\"}\n\n"))
		}))
		defer srv.Close()

		res := asrTranscribeStepAudio(AsrProfile{Protocol: ProtocolStepAudio, URL: srv.URL}, makeWav(16000, []byte{0, 1, 2, 3}))
		if res.Ok || !strings.Contains(res.Error, "invalid audio") {
			t.Errorf("result = %+v", res)
		}
	})
}

func TestAsrTranscribeStepAudioRejectsNonPcmWav(t *testing.T) {
	isolatedHome(t, func() {
		res := asrTranscribeStepAudio(AsrProfile{Protocol: ProtocolStepAudio, URL: "http://x"}, []byte("not a wav"))
		if res.Ok || !strings.Contains(res.Error, "Invalid WAV") {
			t.Errorf("result = %+v", res)
		}
	})
}

func TestWavParamsStripsTrailingChunks(t *testing.T) {
	// A WAV with a LIST metadata chunk AFTER the data chunk: the data
	// chunk's own size (not "everything after the header") defines the
	// PCM payload.
	payload := []byte{1, 0, 2, 0, 3, 0}
	wav := makeWav(16000, payload)
	wav = append(wav, []byte("LIST")...)
	wav = append(wav, 4, 0, 0, 0) // chunk size = 4
	wav = append(wav, []byte("INFO")...)

	rate, channels, bits, offset, size, ok := wavParams(wav)
	if !ok || rate != 16000 || channels != 1 || bits != 16 {
		t.Fatalf("wavParams = %d/%d/%d/%d/%d/%v", rate, channels, bits, offset, size, ok)
	}
	if offset != 44 {
		t.Errorf("data offset = %d, want 44", offset)
	}
	if size != len(payload) {
		t.Errorf("data size = %d, want %d (trailing chunk must not be included)", size, len(payload))
	}
	if string(wav[offset:offset+size]) != string(payload) {
		t.Errorf("sliced payload = %q, want %q", wav[offset:offset+size], payload)
	}
}

func TestWavParamsRejectsDataBeforeFmt(t *testing.T) {
	// A malformed WAV with the data chunk BEFORE fmt: the format fields
	// would be zero, so it must be rejected instead of accepted with
	// bogus metadata.
	wav := []byte("RIFF")
	wav = append(wav, 44, 0, 0, 0)
	wav = append(wav, []byte("WAVE")...)
	wav = append(wav, []byte("data")...)
	wav = append(wav, 4, 0, 0, 0)
	wav = append(wav, 1, 0, 2, 0)

	if _, _, _, _, _, ok := wavParams(wav); ok {
		t.Error("wavParams accepted a data-before-fmt WAV")
	}
}

func TestWavParamsTruncatedDataChunk(t *testing.T) {
	// The declared data size overruns the buffer (truncated file):
	// parsing reports the declared size; the CALLER clamps the slice.
	payload := []byte{1, 0, 2, 0}
	wav := makeWav(16000, payload)
	// Shrink the buffer so the declared data size (4) exceeds the
	// remaining bytes.
	wav = wav[:len(wav)-2]

	rate, channels, bits, offset, size, ok := wavParams(wav)
	if !ok || rate != 16000 || channels != 1 || bits != 16 {
		t.Fatalf("wavParams = %d/%d/%d/%d/%d/%v", rate, channels, bits, offset, size, ok)
	}
	if size != 4 {
		t.Errorf("data size = %d, want declared 4", size)
	}
}

func TestAsrTranscribeStepAudioClampsTruncatedData(t *testing.T) {
	isolatedHome(t, func() {
		srv, audioBase64 := fakeStepAudioServer(t)
		defer srv.Close()

		payload := []byte{5, 0, 6, 0, 7, 0}
		wav := makeWav(16000, payload)
		// Declared data size (6) overruns the buffer by 2 bytes.
		wav = wav[:len(wav)-2]

		p := AsrProfile{
			ID:       "p1",
			Name:     "step",
			Protocol: ProtocolStepAudio,
			URL:      srv.URL,
			APIKey:   "stepkey",
			Language: "zh",
		}
		res := asrTranscribeStepAudio(p, wav)
		if !res.Ok {
			t.Fatalf("result = %+v", res)
		}
		decoded, err := base64.StdEncoding.DecodeString(*audioBase64)
		if err != nil {
			t.Fatal(err)
		}
		want := string(payload[:len(payload)-2])
		if string(decoded) != want {
			t.Errorf("pcm roundtrip = %q, want %q (truncated file must clamp, not overrun)", decoded, want)
		}
	})
}

func TestAsrTranscribeStepAudioStripsTrailingChunks(t *testing.T) {
	isolatedHome(t, func() {
		srv, audioBase64 := fakeStepAudioServer(t)
		defer srv.Close()

		payload := []byte{9, 0, 8, 0, 7, 0}
		wav := makeWav(16000, payload)
		// Trailing LIST metadata after the audio: must NOT be sent as PCM.
		wav = append(wav, []byte("LIST")...)
		wav = append(wav, 4, 0, 0, 0)
		wav = append(wav, []byte("INFO")...)

		p := AsrProfile{
			ID:       "p1",
			Name:     "step",
			Protocol: ProtocolStepAudio,
			URL:      srv.URL,
			APIKey:   "stepkey",
			Language: "zh",
		}
		res := asrTranscribeStepAudio(p, wav)
		if !res.Ok {
			t.Fatalf("result = %+v", res)
		}
		decoded, err := base64.StdEncoding.DecodeString(*audioBase64)
		if err != nil {
			t.Fatal(err)
		}
		if string(decoded) != string(payload) {
			t.Errorf("pcm roundtrip = %q, want %q (trailing chunk leaked into the stream)", decoded, payload)
		}
	})
}
