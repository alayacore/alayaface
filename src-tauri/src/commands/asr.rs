//! Voice input ASR (automatic speech recognition) support.
//!
//! The webview records microphone audio (16-bit PCM WAV, mono) and sends
//! it base64-encoded to `asr_transcribe`; the recognized text is inserted
//! at the input cursor by the UI.
//!
//! ASR is an OpenAI-compatible `/audio/transcriptions` endpoint — local
//! and remote ASR are the same protocol, they only differ by URL. The
//! config lives in `~/.alayaface/asr.conf` (global, cross-preset, like
//! global.conf):
//! ```json
//! {
//!   "url": "http://127.0.0.1:8080/v1/audio/transcriptions",
//!   "api_key": "",
//!   "model": "whisper-1",
//!   "language": "auto"
//! }
//! ```
//! `url` is the FULL endpoint address (including the
//! `/audio/transcriptions` path) and is used verbatim — nothing is
//! appended. `asr_transcribe` POSTs the WAV as multipart to it
//! (Authorization: Bearer when an api_key is set) and parses
//! `{"text": ...}`. `model` is passed through verbatim (the endpoint
//! decides how to use it); `language` is omitted when "auto".

use base64::Engine;
use serde::Serialize;

/// Voice-input ASR config (~/.alayaface/asr.conf).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct AsrConfig {
    /// FULL OpenAI-compatible /audio/transcriptions endpoint address,
    /// e.g. "http://127.0.0.1:8080/v1/audio/transcriptions" (local) or
    /// "https://api.openai.com/v1/audio/transcriptions" (remote). Used
    /// verbatim — nothing is appended.
    #[serde(default)]
    pub url: String,
    /// API key sent as Authorization: Bearer (empty = no header; local
    /// endpoints usually don't require one).
    #[serde(default)]
    pub api_key: String,
    /// Model id passed through to the endpoint (default "whisper-1").
    #[serde(default)]
    pub model: String,
    /// Language hint; "auto" (default) = omit the field / autodetect.
    #[serde(default)]
    pub language: String,
}

impl Default for AsrConfig {
    fn default() -> Self {
        Self {
            url: String::new(),
            api_key: String::new(),
            model: "whisper-1".to_string(),
            language: "auto".to_string(),
        }
    }
}

/// Normalize a config: empty model becomes "whisper-1", empty language
/// becomes "auto".
pub fn normalize_asr_config(cfg: &mut AsrConfig) {
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
    log::info!(
        "[asr] transcribe session={session_id} payload={}b",
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
    transcribe(&cfg, &wav).await
}

/// Multipart POST to the configured endpoint URL (used verbatim).
async fn transcribe(cfg: &AsrConfig, wav: &[u8]) -> Result<AsrTranscribeResult, String> {
    let url = cfg.url.trim().to_string();
    if url.is_empty() {
        return Ok(AsrTranscribeResult {
            ok: false,
            text: String::new(),
            error: "ASR not configured: set the endpoint URL in the ASR config".to_string(),
        });
    }
    let model = cfg.model.trim();

    let file = reqwest::multipart::Part::bytes(wav.to_vec())
        .file_name("audio.wav")
        .mime_str("audio/wav")
        .map_err(|e| format!("Audio part error: {e}"))?;
    let mut form = reqwest::multipart::Form::new()
        .part("file", file)
        .text("model", model.to_string());
    let lang = cfg.language.trim();
    if !lang.is_empty() && lang != "auto" {
        form = form.text("language", lang.to_string());
    }

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
    if !status.is_success() {
        let preview: String = body.chars().take(300).collect();
        return Ok(AsrTranscribeResult {
            ok: false,
            text: String::new(),
            error: format!("ASR API returned {status}: {preview}"),
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_yields_default() {
        crate::dirs::isolated_home(|| {
            let cfg = read_asr_config().unwrap();
            assert_eq!(cfg.model, "whisper-1");
            assert_eq!(cfg.language, "auto");
            assert!(cfg.url.is_empty());
            assert!(cfg.api_key.is_empty());
        });
    }

    #[test]
    fn normalize_fixes_model_and_language() {
        let mut cfg = AsrConfig {
            model: "  ".to_string(),
            language: String::new(),
            ..AsrConfig::default()
        };
        normalize_asr_config(&mut cfg);
        assert_eq!(cfg.model, "whisper-1");
        assert_eq!(cfg.language, "auto");
    }

    #[test]
    fn sync_roundtrips() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            let cfg = rt
                .block_on(sync_asr_config(
                    r#"{"url":"http://127.0.0.1:8080/v1/audio/transcriptions","api_key":"k","language":"zh","model":""}"#
                        .to_string(),
                ))
                .unwrap();
            assert_eq!(cfg.url, "http://127.0.0.1:8080/v1/audio/transcriptions");
            assert_eq!(cfg.language, "zh");
            assert_eq!(cfg.model, "whisper-1");
            let cfg = read_asr_config().unwrap();
            assert_eq!(cfg.url, "http://127.0.0.1:8080/v1/audio/transcriptions");
            assert_eq!(cfg.api_key, "k");
        });
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
