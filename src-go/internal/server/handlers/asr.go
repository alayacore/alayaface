package handlers

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"os"
	"strings"
	"time"

	"alayaface/src-go/internal/dirs"
)

// AsrConfig is the voice-input ASR config (~/.alayaface/asr.conf). Like
// global.conf, this file applies to every preset. Two wire protocols are
// supported (Protocol):
//   - "transcriptions" — OpenAI-compatible /audio/transcriptions
//     (multipart/form-data with file+model+language). Default; local
//     and remote ASR using it only differ by URL.
//   - "chat_completions" — chat-completions style ASR (e.g. MiMo): JSON
//     body with messages[].content[].input_audio base64, api-key header,
//     stream: true; the transcript is read from the SSE delta stream
//     (plain JSON is also accepted).
type AsrConfig struct {
	// Wire protocol: "transcriptions" (default) or "chat_completions".
	Protocol string `json:"protocol"`
	// FULL endpoint address, e.g.
	// "http://127.0.0.1:8080/v1/audio/transcriptions" (local) or
	// "https://api.openai.com/v1/audio/transcriptions" /
	// "https://api.xiaomimimo.com/v1/chat/completions" (remote). Used
	// verbatim — nothing is appended.
	URL string `json:"url"`
	// API key. transcriptions: Authorization: Bearer; chat_completions:
	// api-key header. Empty = no header (local endpoints usually don't
	// require one).
	APIKey string `json:"api_key"`
	// Model id passed through to the endpoint (default "whisper-1").
	Model string `json:"model"`
	// Language hint; "auto" (default) = autodetect.
	Language string `json:"language"`
}

// Wire protocol constants.
const (
	ProtocolTranscriptions = "transcriptions"
	ProtocolChatCompletions = "chat_completions"
)

// DefaultAsrConfig is used when asr.conf is missing or the value is
// absent/out of range.
func DefaultAsrConfig() AsrConfig {
	return AsrConfig{
		Protocol: ProtocolTranscriptions,
		URL:      "",
		APIKey:   "",
		Model:    "whisper-1",
		Language: "auto",
	}
}

// NormalizeAsrConfig fixes a config: unknown protocols fall back to
// "transcriptions", empty model becomes "whisper-1", empty language
// becomes "auto".
func NormalizeAsrConfig(cfg *AsrConfig) {
	if cfg.Protocol != ProtocolChatCompletions {
		cfg.Protocol = ProtocolTranscriptions
	}
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
	// Log the outgoing request (audio base64 truncated to a short
	// preview) so ASR endpoint issues are diagnosable from the backend.
	head := args.AudioBase64
	if len(head) > 120 {
		head = head[:120]
	}
	log.Printf("[asr] transcribe session=%s payload=%db head=%s…", args.SessionID, len(args.AudioBase64), head)
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
	var res AsrTranscribeResult
	if cfg.Protocol == ProtocolChatCompletions {
		res = asrTranscribeChat(cfg, args.AudioBase64, wav)
	} else {
		res = asrTranscribeMultipart(cfg, wav)
	}
	return writeResult(w, res)
}

// asrTranscribeMultipart POSTs the WAV as multipart to the configured
// endpoint URL (used verbatim) and parses {"text": ...}.
func asrTranscribeMultipart(cfg AsrConfig, wav []byte) AsrTranscribeResult {
	url := strings.TrimSpace(cfg.URL)
	if url == "" {
		return AsrTranscribeResult{Ok: false, Error: "ASR not configured: set the endpoint URL in the ASR config"}
	}
	model := strings.TrimSpace(cfg.Model)
	if model == "" {
		model = "whisper-1"
	}
	lang := strings.TrimSpace(cfg.Language)

	// The wire format is multipart/form-data; the hex head shows the WAV
	// begins with "RIFF" (52 49 46 46) when the encoder produced a valid
	// file.
	wavHead := ""
	if len(wav) > 16 {
		wavHead = fmt.Sprintf("%x", wav[:16])
	} else {
		wavHead = fmt.Sprintf("%x", wav)
	}
	log.Printf("[asr] POST %s model=%s lang=%s wav=%db head=%s", url, model, lang, len(wav), wavHead)

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
	res := doAsrRequest(req, "multipart")
	if !res.Ok || res.Error != "" {
		return res
	}
	var out struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal([]byte(res.Text), &out); err != nil {
		return AsrTranscribeResult{Ok: false, Error: "Bad ASR response: " + err.Error()}
	}
	return AsrTranscribeResult{Ok: true, Text: strings.TrimSpace(out.Text)}
}

// asrTranscribeChat POSTs a chat-completions style ASR request (e.g.
// MiMo): JSON body carrying the audio base64 as an input_audio content
// part, api-key header, streamed response. The transcript is read from
// the SSE delta stream; a plain JSON response is accepted as a fallback.
func asrTranscribeChat(cfg AsrConfig, audioBase64 string, wav []byte) AsrTranscribeResult {
	url := strings.TrimSpace(cfg.URL)
	if url == "" {
		return AsrTranscribeResult{Ok: false, Error: "ASR not configured: set the endpoint URL in the ASR config"}
	}
	model := strings.TrimSpace(cfg.Model)
	if model == "" {
		model = "whisper-1"
	}
	lang := strings.TrimSpace(cfg.Language)
	if lang == "" {
		lang = "auto"
	}

	body, err := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]any{
			{
				"role": "user",
				"content": []map[string]any{
					{
						"type": "input_audio",
						"input_audio": map[string]any{
							"data":   audioBase64,
							"format": "wav",
						},
					},
				},
			},
		},
		"asr_options": map[string]any{"language": lang},
		"stream":      true,
	})
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: err.Error()}
	}

	wavHead := ""
	if len(wav) > 16 {
		wavHead = fmt.Sprintf("%x", wav[:16])
	} else {
		wavHead = fmt.Sprintf("%x", wav)
	}
	log.Printf("[asr] POST %s protocol=chat_completions model=%s lang=%s wav=%db head=%s", url, model, lang, len(wav), wavHead)

	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: err.Error()}
	}
	req.Header.Set("Content-Type", "application/json")
	if key := strings.TrimSpace(cfg.APIKey); key != "" {
		req.Header.Set("api-key", key)
	}
	res := doAsrRequest(req, "chat_completions")
	if !res.Ok || res.Error != "" {
		return res
	}
	return AsrTranscribeResult{Ok: true, Text: extractChatText(res.Text), Error: ""}
}

// doAsrRequest runs the request, logs the response, and returns either
// an error result (non-2xx / read failure) or the raw body in Text.
func doAsrRequest(req *http.Request, proto string) AsrTranscribeResult {
	client := &http.Client{Timeout: 120 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: "ASR request failed: " + err.Error()}
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return AsrTranscribeResult{Ok: false, Error: "ASR response read failed: " + err.Error()}
	}
	preview := string(raw)
	if len(preview) > 300 {
		preview = preview[:300]
	}
	log.Printf("[asr] response %s body=%s", resp.Status, preview)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return AsrTranscribeResult{Ok: false, Error: fmt.Sprintf("ASR API returned %s: %s", resp.Status, preview)}
	}
	return AsrTranscribeResult{Ok: true, Text: string(raw), Error: ""}
}

// extractChatText extracts the transcript from a chat-completions
// response: SSE `data:` lines (delta/message content, stopped by
// `data: [DONE]`), falling back to a plain JSON body.
func extractChatText(body string) string {
	var text strings.Builder
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		payload, ok := strings.CutPrefix(line, "data:")
		if !ok {
			continue
		}
		payload = strings.TrimSpace(payload)
		if payload == "[DONE]" {
			break
		}
		var v struct {
			Choices []struct {
				Delta   map[string]any `json:"delta"`
				Message map[string]any `json:"message"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(payload), &v); err != nil {
			continue
		}
		for _, c := range v.Choices {
			if s, _ := c.Delta["content"].(string); s != "" {
				text.WriteString(s)
			} else if s, _ := c.Message["content"].(string); s != "" {
				text.WriteString(s)
			}
		}
	}
	if text.Len() == 0 {
		// Not an SSE stream (some servers ignore `stream`): plain JSON.
		var v struct {
			Choices []struct {
				Message map[string]any `json:"message"`
			} `json:"choices"`
		}
		if err := json.Unmarshal([]byte(body), &v); err == nil {
			for _, c := range v.Choices {
				if s, _ := c.Message["content"].(string); s != "" {
					text.WriteString(s)
				}
			}
		}
	}
	return strings.TrimSpace(text.String())
}
