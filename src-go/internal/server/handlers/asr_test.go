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
