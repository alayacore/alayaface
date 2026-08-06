//! Global AlayaFace settings.
//!
//! Stored as JSON at `~/.alayaface/presets/<name>/settings.conf` (the active
//! preset's config dir). This file is AlayaFace-owned — alayacore does not
//! read it (unlike model.conf / runtime.conf which are copied into each
//! session dir), and it is not copied into sessions.

use std::collections::HashSet;

/// Global app settings.
#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
pub struct GlobalSettings {
    /// Comma-separated (no spaces) tool IDs pre-approved at session start,
    /// passed to alayacore as `--tool-confirm=id1,id2,...`.
    /// Empty/absent means no pre-confirmation.
    #[serde(default)]
    pub tool_confirm: String,

    /// Comma-separated (no spaces) built-in tool IDs enabled for sessions,
    /// passed to alayacore as `--builtin-tools=id1,id2,...`.
    /// Empty/absent means DO NOT pass the flag (alayacore default: all tools).
    #[serde(default)]
    pub builtin_tools: String,
}

/// Read settings from a specific config dir; a missing/empty file yields defaults.
fn read_settings_from(config_dir: &std::path::Path) -> Result<GlobalSettings, String> {
    let path = config_dir.join("settings.conf");
    match std::fs::read_to_string(&path) {
        Ok(text) if !text.trim().is_empty() => serde_json::from_str(&text)
            .map_err(|e| format!("Failed to parse settings.conf: {e}")),
        _ => Ok(GlobalSettings::default()),
    }
}

/// Read global settings (active preset); a missing/empty file yields defaults.
pub fn read_global_settings() -> Result<GlobalSettings, String> {
    let (config_dir, _) = crate::dirs::ensure()?;
    read_settings_from(&config_dir)
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

/// The effective global built-in tools list (normalized; may be empty =
/// don't pass the flag = all tools).
pub fn effective_builtin_tools() -> Result<String, String> {
    let s = read_global_settings()?;
    normalize_tool_confirm(&s.builtin_tools)
}

/// Read a preset's settings (tool-confirm + builtin-tools normalized).
/// `preset` empty = active.
#[tauri::command]
pub async fn get_global_settings(preset: String) -> Result<serde_json::Value, String> {
    let config_dir = crate::dirs::resolve_config_dir(&preset)?;
    let s = read_settings_from(&config_dir)?;
    let normalized_tc = normalize_tool_confirm(&s.tool_confirm)?;
    let normalized_bt = normalize_tool_confirm(&s.builtin_tools)?;
    Ok(serde_json::json!({
        "tool_confirm": normalized_tc,
        "builtin_tools": normalized_bt,
    }))
}

/// Replace a preset's settings (`preset` empty = active). Accepts
/// `{"tool_confirm": "id1,id2", "builtin_tools": "id1,id2"}`; writes
/// atomically (temp file + rename) like sync_default_mcp.
#[tauri::command]
pub async fn sync_global_settings(config: String, preset: String) -> Result<(), String> {
    let value: serde_json::Value = serde_json::from_str(&config)
        .map_err(|e| format!("Invalid settings JSON: {e}"))?;
    let raw_tc = value.get("tool_confirm").and_then(|v| v.as_str()).unwrap_or("");
    let raw_bt = value.get("builtin_tools").and_then(|v| v.as_str()).unwrap_or("");
    let normalized_tc = normalize_tool_confirm(raw_tc)?;
    let normalized_bt = normalize_tool_confirm(raw_bt)?;
    let settings = GlobalSettings {
        tool_confirm: normalized_tc,
        builtin_tools: normalized_bt,
    };

    let config_dir = crate::dirs::resolve_config_dir(&preset)?;
    let path = config_dir.join("settings.conf");
    let tmp = config_dir.join("settings.conf.tmp");
    let text = serde_json::to_string_pretty(&settings)
        .map_err(|e| format!("Failed to serialize settings: {e}"))?;
    std::fs::write(&tmp, &text).map_err(|e| format!("Failed to write settings.conf: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Failed to replace settings.conf: {e}"))?;
    log::info!("[settings] Wrote tool_confirm={:?} builtin_tools={:?}", settings.tool_confirm, settings.builtin_tools);
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
        crate::dirs::isolated_home(|| {
            let settings = read_global_settings().unwrap();
            assert_eq!(settings.tool_confirm, "");
        });
    }

    #[test]
    fn sync_roundtrips() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            let ok = rt.block_on(sync_global_settings(
                r#"{"tool_confirm":"execute_command, search_files "}"#.to_string(),
                "".to_string(),
            ));
            assert!(ok.is_ok());
            let settings = read_global_settings().unwrap();
            assert_eq!(settings.tool_confirm, "execute_command,search_files");

            // Invalid input must be rejected and must not clobber the file
            assert!(rt
                .block_on(sync_global_settings(r#"{"tool_confirm":"a a"}"#.to_string(), "".to_string()))
                .is_err());
            let settings = read_global_settings().unwrap();
            assert_eq!(settings.tool_confirm, "execute_command,search_files");
        });
    }

    #[test]
    fn builtin_tools_roundtrips() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            // Seed the built-in presets first.
            let _ = crate::dirs::ensure().unwrap();

            // Safe seed preset already carries builtin_tools.
            let safe = rt.block_on(get_global_settings("Safe".to_string())).unwrap();
            assert_eq!(safe["builtin_tools"], "read_file,write_file,edit_file,search_content");

            // Default is empty (all tools).
            let def = rt.block_on(get_global_settings("".to_string())).unwrap();
            assert_eq!(def["builtin_tools"], "");

            // Sync a subset and read it back (per-preset).
            let ok = rt.block_on(sync_global_settings(
                r#"{"builtin_tools":"read_file,write_file"}"#.to_string(),
                "Data".to_string(),
            ));
            assert!(ok.is_ok());
            let data = rt.block_on(get_global_settings("Data".to_string())).unwrap();
            assert_eq!(data["builtin_tools"], "read_file,write_file");

            // effective_builtin_tools reads the active preset (Default → "").
            assert_eq!(effective_builtin_tools().unwrap(), "");
        });
    }
}
