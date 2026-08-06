//! Preset management Tauri commands.
//!
//! A preset is a named config directory (~/.alayaface/presets/<name>) holding
//! model.conf, runtime.conf, mcp.conf, settings.conf and themes/. Exactly one
//! preset is active at a time (recorded in ~/.alayaface/active-preset); new
//! sessions are created from a copy of the active preset's config, and the
//! model/MCP/settings editors operate on it.

use crate::dirs;
use serde::Serialize;

/// Serialized preset info for the frontend.
#[derive(Serialize)]
pub struct PresetInfo {
    pub name: String,
    pub is_active: bool,
}

/// List all presets, flagging the active one.
#[tauri::command]
pub async fn list_presets() -> Result<Vec<PresetInfo>, String> {
    dirs::ensure()?;
    let active = dirs::read_active_preset()?;
    let names = dirs::list_preset_names()?;
    Ok(names
        .into_iter()
        .map(|name| PresetInfo {
            is_active: name == active,
            name,
        })
        .collect())
}

/// Create a new preset as a copy of an existing source preset.
#[tauri::command]
pub async fn copy_preset(source: String, name: String) -> Result<(), String> {
    let source = validate_name(&source)?;
    let name = validate_name(&name)?;
    dirs::ensure()?;

    if source == name {
        return Err("Source and new preset have the same name".to_string());
    }
    let src = dirs::preset_dir(&source);
    if !src.exists() {
        return Err(format!("Preset not found: {source}"));
    }
    let dir = dirs::preset_dir(&name);
    if dir.exists() {
        return Err(format!("Preset already exists: {name}"));
    }

    dirs::clone_preset_dir(&src, &dir)?;
    log::info!("[presets] Copied preset {:?} → {:?}", source, name);
    Ok(())
}

/// Delete a preset. The active preset and the last remaining preset cannot be
/// deleted.
#[tauri::command]
pub async fn delete_preset(name: String) -> Result<(), String> {
    let name = validate_name(&name)?;
    dirs::ensure()?;

    let active = dirs::read_active_preset()?;
    if name == active {
        return Err("Cannot delete the active preset — switch to another preset first".to_string());
    }
    if dirs::list_preset_names()?.len() <= 1 {
        return Err("Cannot delete the last preset".to_string());
    }

    let dir = dirs::preset_dir(&name);
    if !dir.exists() {
        return Err(format!("Preset not found: {name}"));
    }
    std::fs::remove_dir_all(&dir)
        .map_err(|e| format!("Failed to delete preset: {e}"))?;
    log::info!("[presets] Deleted preset {:?}", name);
    Ok(())
}

/// Rename a preset. If the renamed preset was active, the active marker
/// follows the new name.
#[tauri::command]
pub async fn rename_preset(old_name: String, new_name: String) -> Result<(), String> {
    let old_name = validate_name(&old_name)?;
    let new_name = validate_name(&new_name)?;
    dirs::ensure()?;

    if old_name == new_name {
        return Ok(());
    }

    let old_dir = dirs::preset_dir(&old_name);
    if !old_dir.exists() {
        return Err(format!("Preset not found: {old_name}"));
    }
    let new_dir = dirs::preset_dir(&new_name);
    if new_dir.exists() {
        return Err(format!("Preset already exists: {new_name}"));
    }

    std::fs::rename(&old_dir, &new_dir)
        .map_err(|e| format!("Failed to rename preset: {e}"))?;

    let active = dirs::read_active_preset()?;
    if active == old_name {
        dirs::write_active_preset(&new_name)?;
    }
    log::info!("[presets] Renamed {:?} → {:?}", old_name, new_name);
    Ok(())
}

/// Make a preset the active one. New sessions and the editors use it from
/// now on; already-running sessions keep their own config copies.
#[tauri::command]
pub async fn set_active_preset(name: String) -> Result<(), String> {
    let name = validate_name(&name)?;
    dirs::ensure()?;

    let dir = dirs::preset_dir(&name);
    if !dir.exists() {
        return Err(format!("Preset not found: {name}"));
    }
    dirs::write_active_preset(&name)?;
    log::info!("[presets] Active preset set to {:?}", name);
    Ok(())
}

fn validate_name(name: &str) -> Result<String, String> {
    let name = name.trim();
    if !dirs::valid_preset_name(name) {
        return Err(format!(
            "Invalid preset name: {name:?} (use letters, digits, '-' or '_')"
        ));
    }
    Ok(name.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preset_lifecycle_roundtrip() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();

            // First run seeds the built-in presets and marks Default active.
            let list = rt.block_on(list_presets()).unwrap();
            assert_eq!(list.len(), 5, "expected Default/Fast/Deep/Data/Safe seeds");
            assert!(list.iter().any(|p| p.name == "Default" && p.is_active));
            assert!(list.iter().any(|p| p.name == "Safe" && !p.is_active));

            // Create a second preset by copying Default.
            rt.block_on(copy_preset("Default".to_string(), "work".to_string()))
                .unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            assert_eq!(list.len(), 6, "5 seeds + work");
            assert!(list.iter().any(|p| p.name == "work" && !p.is_active));

            // Copying a nonexistent source or an existing target is rejected.
            assert!(rt
                .block_on(copy_preset("nope".to_string(), "x".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Default".to_string(), "Default".to_string()))
                .is_err());

            // Switch active.
            rt.block_on(set_active_preset("work".to_string())).unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            assert!(list.iter().any(|p| p.name == "work" && p.is_active));
            assert!(list.iter().any(|p| p.name == "Default" && !p.is_active));

            // Renaming the active preset moves the marker too.
            rt.block_on(rename_preset("work".to_string(), "work2".to_string()))
                .unwrap();
            assert_eq!(dirs::read_active_preset().unwrap(), "work2");

            // Cannot delete the active preset.
            assert!(rt.block_on(delete_preset("work2".to_string())).is_err());

            // Cannot delete the last remaining preset.
            rt.block_on(set_active_preset("Default".to_string())).unwrap();
            assert!(rt.block_on(delete_preset("Default".to_string())).is_err());

            // Deleting a non-active preset works.
            rt.block_on(delete_preset("work2".to_string())).unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            assert_eq!(list.len(), 5, "back to the seeds");
            assert!(list.iter().any(|p| p.name == "Default" && p.is_active));
        });
    }

    #[test]
    fn invalid_names_rejected() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            assert!(rt
                .block_on(copy_preset("Default".to_string(), "a/b".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Default".to_string(), "..".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Default".to_string(), "has space".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Default".to_string(), "".to_string()))
                .is_err());
        });
    }
}
