//! Global AlayaFace settings.
//!
//! Stored as JSON at `~/.alayaface/config/settings.conf`. This file is
//! AlayaFace-owned — alayacore does not read it (unlike model.conf /
//! runtime.conf which are copied into each session dir).

use std::collections::HashSet;

/// Global app settings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct GlobalSettings {
    /// Comma-separated (no spaces) tool IDs pre-approved at session start,
    /// passed to alayacore as `--tool-confirm=id1,id2,...`.
    /// Empty/absent means no pre-confirmation.
    #[serde(default)]
    pub tool_confirm: String,
}

fn settings_path() -> Result<std::path::PathBuf, String> {
    let (config_dir, _) = crate::dirs::ensure()?;
    Ok(config_dir.join("settings.conf"))
}

/// Read global settings; a missing/empty file yields defaults.
pub fn read_global_settings() -> Result<GlobalSettings, String> {
    let path = settings_path()?;
    match std::fs::read_to_string(&path) {
        Ok(text) if !text.trim().is_empty() => serde_json::from_str(&text)
            .map_err(|e| format!("Failed to parse settings.conf: {e}")),
        _ => Ok(GlobalSettings::default()),
    }
}

/// Normalize a comma-separated tool list: trim each id, drop empties,
/// reject duplicates and ids containing whitespace.
pub fn normalize_tool_confirm(raw: &str) -> Result<String, String> {
    let mut seen = HashSet::new();
    let mut out: Vec<String> = Vec::new();
    for part in raw.split(',') {
        let id = part.trim();
        if id.is_empty() {
            continue;
        }
        if id.chars().any(|c| c.is_whitespace()) {
            return Err(format!("Tool id must not contain spaces: {id}"));
        }
        if !seen.insert(id.to_string()) {
            return Err(format!("Duplicate tool id: {id}"));
        }
        out.push(id.to_string());
    }
    Ok(out.join(","))
}

/// The effective global tool-confirm list (normalized; may be empty).
pub fn effective_tool_confirm() -> Result<String, String> {
    let s = read_global_settings()?;
    normalize_tool_confirm(&s.tool_confirm)
}

/// Read current global settings (tool-confirm normalized).
#[tauri::command]
pub async fn get_global_settings() -> Result<serde_json::Value, String> {
    let s = read_global_settings()?;
    let normalized = normalize_tool_confirm(&s.tool_confirm)?;
    Ok(serde_json::json!({ "tool_confirm": normalized }))
}

/// Replace global settings. Accepts `{"tool_confirm": "id1,id2"}`;
/// writes atomically (temp file + rename) like sync_default_mcp.
#[tauri::command]
pub async fn sync_global_settings(config: String) -> Result<(), String> {
    let value: serde_json::Value = serde_json::from_str(&config)
        .map_err(|e| format!("Invalid settings JSON: {e}"))?;
    let raw = value.get("tool_confirm").and_then(|v| v.as_str()).unwrap_or("");
    let normalized = normalize_tool_confirm(raw)?;
    let settings = GlobalSettings {
        tool_confirm: normalized,
    };

    let (config_dir, _) = crate::dirs::ensure()?;
    let path = config_dir.join("settings.conf");
    let tmp = config_dir.join("settings.conf.tmp");
    let text = serde_json::to_string_pretty(&settings)
        .map_err(|e| format!("Failed to serialize settings: {e}"))?;
    std::fs::write(&tmp, &text).map_err(|e| format!("Failed to write settings.conf: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Failed to replace settings.conf: {e}"))?;
    log::info!("[settings] Wrote tool_confirm={:?}", settings.tool_confirm);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_trims_and_drops_empty() {
        assert_eq!(normalize_tool_confirm("").unwrap(), "");
        assert_eq!(normalize_tool_confirm("  ").unwrap(), "");
        assert_eq!(
            normalize_tool_confirm(" execute_command , search_files ,").unwrap(),
            "execute_command,search_files"
        );
    }

    #[test]
    fn normalize_rejects_duplicates_and_spaces() {
        assert!(normalize_tool_confirm("a,a").is_err());
        assert!(normalize_tool_confirm("a b").is_err());
        assert!(normalize_tool_confirm("a\tb").is_err());
    }

    #[test]
    fn missing_file_yields_defaults() {
        let _guard = HOME_LOCK.lock().unwrap();
        let old_home = std::env::var_os("HOME");
        let tmp = std::env::temp_dir().join(format!(
            "alayaface-settings-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        ));
        std::env::set_var("HOME", &tmp);
        let settings = read_global_settings().unwrap();
        match old_home {
            Some(h) => std::env::set_var("HOME", h),
            None => std::env::remove_var("HOME"),
        }
        let _ = std::fs::remove_dir_all(&tmp);
        assert_eq!(settings.tool_confirm, "");
    }

    #[test]
    fn sync_roundtrips() {
        let _guard = HOME_LOCK.lock().unwrap();
        let old_home = std::env::var_os("HOME");
        let tmp = std::env::temp_dir().join(format!(
            "alayaface-settings-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
        ));
        std::env::set_var("HOME", &tmp);

        let rt = tokio::runtime::Runtime::new().unwrap();
        let ok = rt.block_on(sync_global_settings(
            r#"{"tool_confirm":"execute_command, search_files "}"#.to_string(),
        ));
        assert!(ok.is_ok());
        let settings = read_global_settings().unwrap();
        assert_eq!(settings.tool_confirm, "execute_command,search_files");

        // Invalid input must be rejected and must not clobber the file
        assert!(rt
            .block_on(sync_global_settings(r#"{"tool_confirm":"a a"}"#.to_string()))
            .is_err());
        let settings = read_global_settings().unwrap();
        assert_eq!(settings.tool_confirm, "execute_command,search_files");

        match old_home {
            Some(h) => std::env::set_var("HOME", h),
            None => std::env::remove_var("HOME"),
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }

    static HOME_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
    static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
}
