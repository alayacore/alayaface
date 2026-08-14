package handlers

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"strings"
	"time"

	"alayaface/src-go/internal/dirs"
)

// AsrConfig is the voice-input ASR config (~/.alayaface/asr.conf).
// ASR is an OpenAI-compatible /audio/transcriptions endpoint — local and
// remote ASR are the same protocol, they only differ by URL. Like
// global.conf, this file applies to every preset.
type AsrConfig struct {
	// FULL OpenAI-compatible /audio/transcriptions endpoint address,
	// e.g. "http://127.0.0.1:8080/v1/audio/transcriptions" (local) or
	// "https://api.openai.com/v1/audio/transcriptions" (remote). Used
	// verbatim — nothing is appended.
	URL string `json:"url"`
	// API key sent as Authorization: Bearer (empty = no header; local
	// endpoints usually don't require one).
	APIKey string `json:"api_key"`
	// Model id passed through to the endpoint (default "whisper-1").
	Model string `json:"model"`
	// Language hint; "auto" (default) = omit the field / autodetect.
	Language string `json:"language"`
}

// DefaultAsrConfig is used when asr.conf is missing or the value is
// absent/out of range.
func DefaultAsrConfig() AsrConfig {
	return AsrConfig{
		URL:      "",
		APIKey:   "",
		Model:    "whisper-1",
		Language: "auto",
	}
}

// NormalizeAsrConfig fixes a config: empty model becomes "whisper-1",
// empty language becomes "auto".
func NormalizeAsrConfig(cfg *AsrConfig) {
	if strings.TrimSpace(cfg.Model) == "" {
		cfg.Model = "whisper-1"
	}
	if strings.TrimSpace(cfg.Language) == "" {
		cfg.Language = "auto"
	}
}

// readAsrConfig reads the ASR config; a missing/empty file yields
// defaults. Parse errors are reported (a corrupt asr.conf must not be
// silently ignored).
func readAsrConfig() (AsrConfig, error) {
	path := dirs.AsrConfigFile()
	text, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return DefaultAsrConfig(), nil
		}
		return AsrConfig{}, err
	}
	if strings.TrimSpace(string(text)) == "" {
		return DefaultAsrConfig(), nil
	}
	var cfg AsrConfig
	if err := json.Unmarshal(text, &cfg); err != nil {
		return AsrConfig{}, fmt.Errorf("Failed to parse asr.conf: %w", err)
	}
	NormalizeAsrConfig(&cfg)
	return cfg, nil
}

// GetAsrConfig returns the ASR config overlay.
func GetAsrConfig(h *Handler, w http.ResponseWriter, r *http.Request) error {
	cfg, err := readAsrConfig()
	if err != nil {
		return err
	}
	return writeJSON(w, cfg)
}

// SyncAsrConfig replaces the ASR config overlay. Accepts the AsrConfig
// JSON (any subset of fields); writes atomically. The normalized config
// is returned so the frontend can adopt the effective values.
func SyncAsrConfig(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		Config string `json:"config"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	var cfg AsrConfig
	if err := json.Unmarshal([]byte(args.Config), &cfg); err != nil {
		return fmt.Errorf("Invalid ASR config JSON: %w", err)
	}
	NormalizeAsrConfig(&cfg)

	if _, err := dirs.Ensure(); err != nil {
		return err
	}
	path := dirs.AsrConfigFile()
	tmp := path + ".tmp"
	text, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, text, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return writeResult(w, cfg)
}

// AsrTranscribeResult is the transcription outcome. Ok is true when the
// endpoint responded with a transcript (possibly empty text for
// silence); Error carries the human-readable reason otherwise.
type AsrTranscribeResult struct {
	Ok    bool   `json:"ok"`
	Text  string `json:"text"`
	Error string `json:"error"`
}

// AsrTranscribe transcribes base64-encoded WAV audio via the configured
// OpenAI-compatible endpoint. The session id is used for logging only —
// transcription is stateless.
func AsrTranscribe(h *Handler, w http.ResponseWriter, r *http.Request) error {
	var args struct {
		AudioBase64 string `json:"audioBase64"`
		SessionID   string `json:"sessionId"`
	}
	if err := decodeArgs(r, &args); err != nil {
		return err
	}
	wav, err := base64.StdEncoding.DecodeString(args.AudioBase64)
	if err != nil {
		return fmt.Errorf("Invalid audio payload: %w", err)
	}
	if len(wav) == 0 {
		return writeResult(w, AsrTranscribeResult{Ok: false, Error: "Empty audio"})
	}
	cfg, err := readAsrConfig()
	if err != nil {
		return err
	}
	res := asrTranscribe(cfg, wav)
	return writeResult(w, res)
}

// asrTranscribe POSTs the WAV as multipart to the configured endpoint
// URL (used verbatim) and parses {"text": ...}.
func asrTranscribe(cfg AsrConfig, wav []byte) AsrTranscribeResult {
	url := strings.TrimSpace(cfg.URL)
	if url == "" {
		return AsrTranscribeResult{Ok: false, Error: "ASR not configured: set the endpoint URL in the ASR config"}
	}
	model := strings.TrimSpace(cfg.Model)
	if model == "" {
		model = "whisper-1"
	}

	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	fw, err := mw.CreateFormFile("file", "audio.wav")
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: err.Error()}
	}
	if _, err := fw.Write(wav); err != nil {
		return AsrTranscribeResult{Ok: false, Error: err.Error()}
	}
	if err := mw.WriteField("model", model); err != nil {
		return AsrTranscribeResult{Ok: false, Error: err.Error()}
	}
	lang := strings.TrimSpace(cfg.Language)
	if lang != "" && lang != "auto" {
		if err := mw.WriteField("language", lang); err != nil {
			return AsrTranscribeResult{Ok: false, Error: err.Error()}
		}
	}
	if err := mw.Close(); err != nil {
		return AsrTranscribeResult{Ok: false, Error: err.Error()}
	}

	req, err := http.NewRequest(http.MethodPost, url, &buf)
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: err.Error()}
	}
	req.Header.Set("Content-Type", mw.FormDataContentType())
	if key := strings.TrimSpace(cfg.APIKey); key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: "ASR request failed: " + err.Error()}
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: "ASR response read failed: " + err.Error()}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		preview := string(body)
		if len(preview) > 300 {
			preview = preview[:300]
		}
		return AsrTranscribeResult{Ok: false, Error: fmt.Sprintf("ASR API returned %s: %s", resp.Status, preview)}
	}
	var out struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		return AsrTranscribeResult{Ok: false, Error: "Bad ASR response: " + err.Error()}
	}
	return AsrTranscribeResult{Ok: true, Text: strings.TrimSpace(out.Text)}
}
