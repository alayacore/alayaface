package handlers

import (
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
		if cfg.Model != "whisper-1" || cfg.Language != "auto" || cfg.URL != "" || cfg.APIKey != "" {
			t.Errorf("defaults wrong: %+v", cfg)
		}
	})
}

func TestNormalizeAsrConfig(t *testing.T) {
	cfg := AsrConfig{Model: "  ", Language: ""}
	NormalizeAsrConfig(&cfg)
	if cfg.Model != "whisper-1" || cfg.Language != "auto" {
		t.Errorf("normalize wrong: %+v", cfg)
	}
}

func TestAsrConfigSyncRoundtrips(t *testing.T) {
	isolatedHome(t, func() {
		rr := call(t, SyncAsrConfig, map[string]any{
			"config": `{"url":"http://127.0.0.1:8080/v1","api_key":"k","language":"zh","model":""}`,
		})
		if rr.Code != 200 {
			t.Fatalf("sync status = %d, body %s", rr.Code, rr.Body.String())
		}
		var out map[string]any
		if err := json.Unmarshal(rr.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		if out["url"] != "http://127.0.0.1:8080/v1" || out["language"] != "zh" || out["model"] != "whisper-1" {
			t.Errorf("sync returned %v", out)
		}
		cfg, err := readAsrConfig()
		if err != nil {
			t.Fatal(err)
		}
		if cfg.URL != "http://127.0.0.1:8080/v1" || cfg.APIKey != "k" || cfg.Language != "zh" {
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

		cfg := AsrConfig{
			URL:      srv.URL + "/v1/audio/transcriptions",
			APIKey:   "testkey",
			Model:    "whisper-1",
			Language: "zh",
		}
		res := asrTranscribe(cfg, []byte("RIFF-fake-wav"))
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

		cfg := AsrConfig{URL: srv.URL + "/v1/audio/transcriptions", APIKey: "testkey", Language: "auto"}
		res := asrTranscribe(cfg, []byte("RIFF-fake-wav"))
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

		res := asrTranscribe(AsrConfig{URL: srv.URL + "/custom/endpoint"}, []byte("RIFF-fake-wav"))
		if !res.Ok || res.Text != "ok" {
			t.Errorf("result = %+v", res)
		}
	})
}

func TestAsrTranscribeUnconfigured(t *testing.T) {
	isolatedHome(t, func() {
		res := asrTranscribe(AsrConfig{}, []byte("RIFF-fake-wav"))
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

		res := asrTranscribe(AsrConfig{URL: srv.URL, APIKey: "bad"}, []byte("RIFF-fake-wav"))
		if res.Ok || !strings.Contains(res.Error, "401") {
			t.Errorf("result = %+v", res)
		}
	})
}
