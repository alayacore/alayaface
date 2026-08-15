//! Preset management Tauri commands.
//!
//! A preset is a named config directory (~/.alayaface/presets/<name>) holding
//! model.conf, runtime.conf, mcp.conf, settings.conf and themes/. Every
//! session is created under an EXPLICITLY chosen preset (the frontend always
//! passes one — there is no active preset), and the model/MCP/settings
//! editors operate on a specific preset.

use crate::dirs;
use serde::Serialize;

/// Serialized preset info for the frontend.
#[derive(Serialize)]
pub struct PresetInfo {
    pub name: String,
    pub is_seed: bool,
}

/// List all presets.
#[tauri::command]
pub async fn list_presets() -> Result<Vec<PresetInfo>, String> {
    dirs::ensure()?;
    let names = dirs::list_preset_names()?;
    Ok(names
        .into_iter()
        .map(|name| PresetInfo {
            is_seed: dirs::is_seed_preset(&name),
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

/// Delete a preset. Built-in seed presets (Simple/Complex) cannot be
/// deleted (the seeded plan contract references them), and the last
/// remaining preset cannot be deleted either.
#[tauri::command]
pub async fn delete_preset(name: String) -> Result<(), String> {
    let name = validate_name(&name)?;
    dirs::ensure()?;

    if dirs::is_seed_preset(&name) {
        return Err(format!("Cannot delete the built-in preset: {name}"));
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

/// Rename a preset. Built-in seed presets (Simple/Complex) cannot be
/// renamed — the seeded plan contract references them by name.
#[tauri::command]
pub async fn rename_preset(old_name: String, new_name: String) -> Result<(), String> {
    let old_name = validate_name(&old_name)?;
    let new_name = validate_name(&new_name)?;
    dirs::ensure()?;

    if dirs::is_seed_preset(&old_name) {
        return Err(format!("Cannot rename the built-in preset: {old_name}"));
    }

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
    log::info!("[presets] Renamed {:?} → {:?}", old_name, new_name);
    Ok(())
}

/// Persist a user-defined preset display order (Preset Manager
/// drag-to-reorder). Accepts the full ordered name list; unknown names
/// are ignored and presets missing from the list are appended in sorted
/// order, so the file can never hide a preset.
#[tauri::command]
pub async fn reorder_presets(names: Vec<String>) -> Result<(), String> {
    dirs::ensure()?;
    let existing = dirs::list_preset_names()?;
    let existing_set: std::collections::HashSet<&String> = existing.iter().collect();
    let mut seen = std::collections::HashSet::new();
    let mut ordered = Vec::with_capacity(existing.len());
    for raw in names {
        let n = raw.trim().to_string();
        if existing_set.contains(&n) && seen.insert(n.clone()) {
            ordered.push(n);
        }
    }
    for n in existing {
        if !seen.contains(&n) {
            ordered.push(n);
        }
    }
    dirs::write_preset_order(&ordered)?;
    log::info!("[presets] Reordered preset list");
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

            // First run seeds the built-in presets (Simple/Complex).
            let list = rt.block_on(list_presets()).unwrap();
            assert_eq!(list.len(), 2, "expected Simple/Complex seeds");
            assert!(list.iter().any(|p| p.name == "Simple" && p.is_seed));
            assert!(list.iter().any(|p| p.name == "Complex" && p.is_seed));

            // Renaming a built-in seed is rejected (the seeded plan
            // contract references the names).
            assert!(rt
                .block_on(rename_preset("Simple".to_string(), "foo".to_string()))
                .is_err());
            assert!(rt
                .block_on(rename_preset("Complex".to_string(), "bar".to_string()))
                .is_err());

            // Create a second preset by copying Simple.
            rt.block_on(copy_preset("Simple".to_string(), "work".to_string()))
                .unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            assert_eq!(list.len(), 3, "2 seeds + work");
            assert!(list.iter().any(|p| p.name == "work" && !p.is_seed));

            // Copying a nonexistent source or an existing target is rejected.
            assert!(rt
                .block_on(copy_preset("nope".to_string(), "x".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Simple".to_string(), "Simple".to_string()))
                .is_err());

            // A copy is NOT a seed → renameable.
            rt.block_on(rename_preset("work".to_string(), "work2".to_string()))
                .unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            assert!(list.iter().any(|p| p.name == "work2"));
            assert!(!list.iter().any(|p| p.name == "work"));

            // Deleting a non-seed preset works.
            rt.block_on(delete_preset("work2".to_string())).unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            assert_eq!(list.len(), 2, "back to the seeds");

            // Deleting a built-in seed is rejected (the seeded plan
            // contract references the names).
            assert!(rt.block_on(delete_preset("Simple".to_string())).is_err());
            assert!(rt.block_on(delete_preset("Complex".to_string())).is_err());
        });
    }

    #[test]
    fn reorder_presets_roundtrip() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(copy_preset("Simple".to_string(), "work".to_string()))
                .unwrap();

            // Default order is alphabetical: Complex Simple work.
            let list = rt.block_on(list_presets()).unwrap();
            let names: Vec<&str> = list.iter().map(|p| p.name.as_str()).collect();
            assert_eq!(names, vec!["Complex", "Simple", "work"]);

            // Full reorder is persisted.
            rt.block_on(reorder_presets(vec![
                "work".to_string(),
                "Simple".to_string(),
                "Complex".to_string(),
            ]))
            .unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            let names: Vec<&str> = list.iter().map(|p| p.name.as_str()).collect();
            assert_eq!(names, vec!["work", "Simple", "Complex"]);

            // Unknown names are dropped, missing presets appended
            // (sorted) — the file never hides a preset.
            rt.block_on(reorder_presets(vec![
                "nope".to_string(),
                "Complex".to_string(),
                "work".to_string(),
            ]))
            .unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            let names: Vec<&str> = list.iter().map(|p| p.name.as_str()).collect();
            assert_eq!(names, vec!["Complex", "work", "Simple"]);

            // A new preset lands at the end.
            rt.block_on(copy_preset("Simple".to_string(), "aaa".to_string()))
                .unwrap();
            let list = rt.block_on(list_presets()).unwrap();
            let names: Vec<&str> = list.iter().map(|p| p.name.as_str()).collect();
            assert_eq!(names, vec!["Complex", "work", "Simple", "aaa"]);
        });
    }

    #[test]
    fn invalid_names_rejected() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            assert!(rt
                .block_on(copy_preset("Simple".to_string(), "a/b".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Simple".to_string(), "..".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Simple".to_string(), "has space".to_string()))
                .is_err());
            assert!(rt
                .block_on(copy_preset("Simple".to_string(), "".to_string()))
                .is_err());
        });
    }
}
