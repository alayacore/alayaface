//! Voice input ASR (automatic speech recognition) support.
//!
//! The webview records microphone audio (16-bit PCM WAV, mono) and sends
//! it base64-encoded to `asr_transcribe`; the recognized text is inserted
//! at the input cursor by the UI.
//!
//! Two wire protocols are supported (config `protocol`):
//! - "transcriptions" — OpenAI-compatible `/audio/transcriptions`
//!   (multipart/form-data with file+model+language). Default; local and
//!   remote ASR using this protocol only differ by URL.
//! - "chat_completions" — OpenAI chat-completions style ASR (e.g. MiMo):
//!   JSON body with `messages[].content[].input_audio` base64, `api-key`
//!   header, `stream: true`; the transcript is read from the SSE delta
//!   stream (plain JSON is also accepted).
//!
//! Config lives in `~/.alayaface/asr.conf` (global, cross-preset, like
//! global.conf):
//! ```json
//! {
//!   "protocol": "transcriptions",
//!   "url": "http://127.0.0.1:8080/v1/audio/transcriptions",
//!   "api_key": "",
//!   "model": "whisper-1",
//!   "language": "auto"
//! }
//! ```
//! `url` is the FULL endpoint address and is used verbatim — nothing is
//! appended. `model` is passed through verbatim (the endpoint decides
//! how to use it); `language` is a hint ("auto" = autodetect).

use base64::Engine;
use serde::Serialize;

/// Wire protocol: "transcriptions" (multipart /audio/transcriptions,
/// default) or "chat_completions" (JSON chat-completions ASR, MiMo
/// style).
pub const PROTOCOL_TRANSCRIPTIONS: &str = "transcriptions";
pub const PROTOCOL_CHAT_COMPLETIONS: &str = "chat_completions";

/// Voice-input ASR config (~/.alayaface/asr.conf).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AsrConfig {
    /// Wire protocol: "transcriptions" (default) or "chat_completions".
    #[serde(default)]
    pub protocol: String,
    /// FULL endpoint address, e.g.
    /// "http://127.0.0.1:8080/v1/audio/transcriptions" (local) or
    /// "https://api.openai.com/v1/audio/transcriptions" /
    /// "https://api.xiaomimimo.com/v1/chat/completions" (remote). Used
    /// verbatim — nothing is appended.
    #[serde(default)]
    pub url: String,
    /// API key. transcriptions: Authorization: Bearer; chat_completions:
    /// api-key header. Empty = no header (local endpoints usually don't
    /// require one).
    #[serde(default)]
    pub api_key: String,
    /// Model id passed through to the endpoint (default "whisper-1").
    #[serde(default)]
    pub model: String,
    /// Language hint; "auto" (default) = autodetect.
    #[serde(default)]
    pub language: String,
}

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            protocol: PROTOCOL_TRANSCRIPTIONS.to_string(),
            url: String::new(),
            api_key: String::new(),
            model: "whisper-1".to_string(),
            language: "auto".to_string(),
        }
    }
}

/// Normalize a config: unknown protocols fall back to "transcriptions",
/// empty model becomes "whisper-1", empty language becomes "auto".
pub fn normalize_asr_config(cfg: &mut AsrConfig) {
    if cfg.protocol != PROTOCOL_CHAT_COMPLETIONS {
        cfg.protocol = PROTOCOL_TRANSCRIPTIONS.to_string();
    }
    if cfg.model.trim().is_empty() {
        cfg.model = "whisper-1".to_string();
    }
    if cfg.language.trim().is_empty() {
        cfg.language = "auto".to_string();
    }
}

/// Read the ASR config; a missing/empty file yields defaults. Parse
/// errors are reported (a corrupt asr.conf must not be silently ignored).
pub fn read_asr_config() -> Result<AsrConfig, String> {
    let path = crate::dirs::alayaface_dir().join("asr.conf");
    match std::fs::read_to_string(&path) {
        Ok(text) if !text.trim().is_empty() => {
            let mut cfg: AsrConfig = serde_json::from_str(&text)
                .map_err(|e| format!("Failed to parse asr.conf: {e}"))?;
            normalize_asr_config(&mut cfg);
            Ok(cfg)
        }
        _ => Ok(AsrConfig::default()),
    }
}

/// Read the ASR config overlay.
#[tauri::command]
pub async fn get_asr_config() -> Result<AsrConfig, String> {
    read_asr_config()
}

/// Replace the ASR config overlay. Accepts the AsrConfig JSON (any
/// subset of fields); writes atomically. The normalized config is
/// returned so the frontend can adopt the effective values.
#[tauri::command]
pub async fn sync_asr_config(config: String) -> Result<AsrConfig, String> {
    let mut cfg: AsrConfig = serde_json::from_str(&config)
        .map_err(|e| format!("Invalid ASR config JSON: {e}"))?;
    normalize_asr_config(&mut cfg);

    let dir = crate::dirs::alayaface_dir();
    crate::dirs::ensure()?;
    let path = dir.join("asr.conf");
    let tmp = path.with_extension("conf.tmp");
    let text = serde_json::to_string_pretty(&cfg)
        .map_err(|e| format!("Failed to serialize ASR config: {e}"))?;
    std::fs::write(&tmp, text).map_err(|e| format!("Failed to write asr.conf: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Failed to replace asr.conf: {e}"))?;
    Ok(cfg)
}

/// Result of a transcription attempt. `ok` is true when the endpoint
/// responded with a transcript (possibly empty text for silence);
/// `error` carries the human-readable reason otherwise.
#[derive(Serialize)]
pub struct AsrTranscribeResult {
    pub ok: bool,
    pub text: String,
    pub error: String,
}

/// Transcribe base64-encoded WAV audio via the configured OpenAI-
/// compatible endpoint. The session id is used for logging only —
/// transcription is stateless.
#[tauri::command]
pub async fn asr_transcribe(
    audio_base64: String,
    session_id: String,
) -> Result<AsrTranscribeResult, String> {
    // Log the outgoing request (audio base64 truncated to a short
    // preview) so ASR endpoint issues are diagnosable from the backend.
    let head: String = audio_base64.chars().take(120).collect();
    log::info!(
        "[asr] transcribe session={session_id} payload={}b head={head}…",
        audio_base64.len()
    );
    let wav = base64::engine::general_purpose::STANDARD
        .decode(audio_base64.as_bytes())
        .map_err(|e| format!("Invalid audio payload: {e}"))?;
    if wav.is_empty() {
        return Ok(AsrTranscribeResult {
            ok: false,
            text: String::new(),
            error: "Empty audio".to_string(),
        });
    }
    let cfg = read_asr_config()?;
    if cfg.protocol == PROTOCOL_CHAT_COMPLETIONS {
        transcribe_chat(&cfg, &audio_base64, &wav).await
    } else {
        transcribe_multipart(&cfg, &wav).await
    }
}

/// Multipart POST to the configured endpoint URL (used verbatim).
async fn transcribe_multipart(cfg: &AsrConfig, wav: &[u8]) -> Result<AsrTranscribeResult, String> {
    let url = cfg.url.trim().to_string();
    if url.is_empty() {
        return Ok(AsrTranscribeResult {
            ok: false,
            text: String::new(),
            error: "ASR not configured: set the endpoint URL in the ASR config".to_string(),
        });
    }
    let model = cfg.model.trim();
    let lang = cfg.language.trim();

    let file = reqwest::multipart::Part::bytes(wav.to_vec())
        .file_name("audio.wav")
        .mime_str("audio/wav")
        .map_err(|e| format!("Audio part error: {e}"))?;
    let mut form = reqwest::multipart::Form::new()
        .part("file", file)
        .text("model", model.to_string());
    if !lang.is_empty() && lang != "auto" {
        form = form.text("language", lang.to_string());
    }

    // The wire format is multipart/form-data; the base64 head shows the
    // WAV begins with "RIFF" when the encoder produced a valid file.
    let wav_head: String = wav
        .iter()
        .take(16)
        .map(|b| format!("{b:02x}"))
        .collect();
    log::info!(
        "[asr] POST {url} model={model} lang={lang} wav={}b head={wav_head}",
        wav.len()
    );

    let mut req = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("HTTP client error: {e}"))?
        .post(&url)
        .multipart(form)
        .timeout(std::time::Duration::from_secs(120));
    let key = cfg.api_key.trim();
    if !key.is_empty() {
        req = req.header("Authorization", format!("Bearer {key}"));
    }

    let resp = req
        .send()
        .await
        .map_err(|e| format!("ASR request failed: {e}"))?;
    let status = resp.status();
    let body = resp
        .text()
        .await
        .map_err(|e| format!("ASR response read failed: {e}"))?;
    let body_preview: String = body.chars().take(300).collect();
    log::info!("[asr] response {status} body={body_preview}");
    if !status.is_success() {
        return Ok(AsrTranscribeResult {
            ok: false,
            text: String::new(),
            error: format!("ASR API returned {status}: {body_preview}"),
        });
    }
    let v: serde_json::Value =
        serde_json::from_str(&body).map_err(|e| format!("Bad ASR response: {e}"))?;
    let text = v
        .get("text")
        .and_then(|t| t.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    Ok(AsrTranscribeResult {
        ok: true,
        text,
        error: String::new(),
    })
}

/// Chat-completions style ASR (e.g. MiMo): JSON body carrying the audio
/// base64 as an `input_audio` content part, `api-key` header, streamed
/// response. The transcript is read from the SSE delta stream; a plain
/// JSON response is accepted as a fallback.
async fn transcribe_chat(
    cfg: &AsrConfig,
    audio_base64: &str,
    wav: &[u8],
) -> Result<AsrTranscribeResult, String> {
    let url = cfg.url.trim().to_string();
    if url.is_empty() {
        return Ok(AsrTranscribeResult {
            ok: false,
            text: String::new(),
            error: "ASR not configured: set the endpoint URL in the ASR config".to_string(),
        });
    }
    let model = if cfg.model.trim().is_empty() {
        "whisper-1"
    } else {
        cfg.model.trim()
    };
    let lang = if cfg.language.trim().is_empty() {
        "auto"
    } else {
        cfg.language.trim()
    };
    let body = serde_json::json!({
        "model": model,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_audio",
                        "input_audio": {
                            "data": audio_base64,
                            "format": "wav"
                        }
                    }
                ]
            }
        ],
        "asr_options": { "language": lang },
        "stream": true
    });
    let wav_head: String = wav
        .iter()
        .take(16)
        .map(|b| format!("{b:02x}"))
        .collect();
    log::info!(
        "[asr] POST {url} protocol=chat_completions model={model} lang={lang} wav={}b head={wav_head}",
        wav.len()
    );

    let mut req = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("HTTP client error: {e}"))?
        .post(&url)
        .json(&body)
        .timeout(std::time::Duration::from_secs(120));
    let key = cfg.api_key.trim();
    if !key.is_empty() {
        req = req.header("api-key", key);
    }

    let resp = req
        .send()
        .await
        .map_err(|e| format!("ASR request failed: {e}"))?;
    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("ASR response read failed: {e}"))?;
    let body_preview: String = text.chars().take(300).collect();
    log::info!("[asr] response {status} body={body_preview}");
    if !status.is_success() {
        return Ok(AsrTranscribeResult {
            ok: false,
            text: String::new(),
            error: format!("ASR API returned {status}: {body_preview}"),
        });
    }
    Ok(AsrTranscribeResult {
        ok: true,
        text: extract_chat_text(&text),
        error: String::new(),
    })
}

/// Extract the transcript from a chat-completions response: SSE
/// `data:` lines (delta/message content, stopped by `data: [DONE]`),
/// falling back to a plain JSON body.
fn extract_chat_text(body: &str) -> String {
    let mut text = String::new();
    for line in body.lines() {
        let line = line.trim();
        let Some(payload) = line.strip_prefix("data:") else {
            continue;
        };
        let payload = payload.trim();
        if payload == "[DONE]" {
            break;
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(payload) {
            if let Some(delta) = v
                .pointer("/choices/0/delta/content")
                .and_then(|c| c.as_str())
            {
                text.push_str(delta);
            } else if let Some(msg) = v
                .pointer("/choices/0/message/content")
                .and_then(|c| c.as_str())
            {
                text.push_str(msg);
            }
        }
    }
    if text.is_empty() {
        // Not an SSE stream (some servers ignore `stream`): plain JSON.
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(body) {
            if let Some(msg) = v
                .pointer("/choices/0/message/content")
                .and_then(|c| c.as_str())
            {
                text.push_str(msg);
            }
        }
    }
    text.trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_yields_default() {
        crate::dirs::isolated_home(|| {
            let cfg = read_asr_config().unwrap();
            assert_eq!(cfg.protocol, PROTOCOL_TRANSCRIPTIONS);
            assert_eq!(cfg.model, "whisper-1");
            assert_eq!(cfg.language, "auto");
            assert!(cfg.url.is_empty());
            assert!(cfg.api_key.is_empty());
        });
    }

    #[test]
    fn normalize_fixes_protocol_model_language() {
        let mut cfg = AsrConfig {
            protocol: "bogus".to_string(),
            model: "  ".to_string(),
            language: String::new(),
            ..AsrConfig::default()
        };
        normalize_asr_config(&mut cfg);
        assert_eq!(cfg.protocol, PROTOCOL_TRANSCRIPTIONS);
        assert_eq!(cfg.model, "whisper-1");
        assert_eq!(cfg.language, "auto");

        let mut cfg = AsrConfig {
            protocol: PROTOCOL_CHAT_COMPLETIONS.to_string(),
            ..AsrConfig::default()
        };
        normalize_asr_config(&mut cfg);
        assert_eq!(cfg.protocol, PROTOCOL_CHAT_COMPLETIONS);
    }

    #[test]
    fn sync_roundtrips() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            let cfg = rt
                .block_on(sync_asr_config(
                    r#"{"protocol":"chat_completions","url":"https://api.xiaomimimo.com/v1/chat/completions","api_key":"k","language":"zh","model":""}"#
                        .to_string(),
                ))
                .unwrap();
            assert_eq!(cfg.protocol, PROTOCOL_CHAT_COMPLETIONS);
            assert_eq!(cfg.url, "https://api.xiaomimimo.com/v1/chat/completions");
            assert_eq!(cfg.language, "zh");
            assert_eq!(cfg.model, "whisper-1");
            let cfg = read_asr_config().unwrap();
            assert_eq!(cfg.protocol, PROTOCOL_CHAT_COMPLETIONS);
            assert_eq!(cfg.api_key, "k");
        });
    }

    #[test]
    fn extract_chat_text_joins_sse_deltas() {
        let body = "data: {\"choices\":[{\"delta\":{\"content\":\"hel\"}}]}\n\n\
                    data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}]}\n\n\
                    data: [DONE]\n\n";
        assert_eq!(extract_chat_text(body), "hello");
    }

    #[test]
    fn extract_chat_text_falls_back_to_plain_json() {
        let body = r#"{"choices":[{"message":{"content":"plain hello"}}]}"#;
        assert_eq!(extract_chat_text(body), "plain hello");
    }

    #[test]
    fn extract_chat_text_empty_on_no_content() {
        assert_eq!(extract_chat_text("data: [DONE]\n\n"), "");
        assert_eq!(extract_chat_text(""), "");
    }

    #[test]
    fn sync_rejects_invalid() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            assert!(rt
                .block_on(sync_asr_config(r#"{not json"#.to_string()))
                .is_err());
        });
    }
}
