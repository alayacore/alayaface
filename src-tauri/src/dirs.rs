//! Directory and file management for AlayaFace.
//!
//! Manages `~/.alayaface/` structure:
//!   ~/.alayaface/
//!     active-preset        — name of the currently active preset
//!     presets/
//!       <name>/            — one config directory per preset
//!         model.conf
//!         runtime.conf
//!         mcp.conf
//!         settings.conf    — AlayaFace-owned (tool_confirm etc.); NOT copied into sessions
//!         themes/
//!     sessions/
//!       <uuid>/
//!         config/          — copy of the active preset's config (minus settings.conf)
//!         session.alaya

use std::path::PathBuf;

/// Default model config template (key-value block format).
const DEFAULT_MODEL_CONF: &str = r##"name: "Placeholder"
protocol_type: "openai"
base_url: "https://api.openai.com/v1"
api_key: ""
model_name: "gpt-4o"
context_limit: 128000
max_tokens: 4096
"##;

/// Get alayaface's base directory (~/.alayaface).
pub fn alayaface_dir() -> PathBuf {
    let home = std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .unwrap_or_else(|_| ".".to_string());
    PathBuf::from(home).join(".alayaface")
}

/// Directory holding all presets (~/.alayaface/presets).
pub fn presets_root() -> PathBuf {
    alayaface_dir().join("presets")
}

/// File recording the active preset name (~/.alayaface/active-preset).
pub fn active_preset_file() -> PathBuf {
    alayaface_dir().join("active-preset")
}

/// A preset name is a short, filesystem-safe identifier.
pub fn valid_preset_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// Absolute path of a preset's config directory.
pub fn preset_dir(name: &str) -> PathBuf {
    presets_root().join(name)
}

/// Read the active preset name. Errors if the marker is missing/invalid.
pub fn read_active_preset() -> Result<String, String> {
    let path = active_preset_file();
    let text = std::fs::read_to_string(&path)
        .map_err(|e| format!("Failed to read active preset: {e}"))?;
    let name = text.trim().to_string();
    if !valid_preset_name(&name) {
        return Err(format!("Invalid active preset name: {name:?}"));
    }
    Ok(name)
}

/// Persist the active preset name (atomic: temp file + rename).
pub fn write_active_preset(name: &str) -> Result<(), String> {
    if !valid_preset_name(name) {
        return Err(format!("Invalid preset name: {name:?}"));
    }
    let path = active_preset_file();
    let tmp = alayaface_dir().join("active-preset.tmp");
    std::fs::write(&tmp, name)
        .map_err(|e| format!("Failed to write active preset: {e}"))?;
    std::fs::rename(&tmp, &path)
        .map_err(|e| format!("Failed to replace active preset: {e}"))?;
    Ok(())
}

/// Config directory of the active preset.
pub fn active_config_dir() -> Result<PathBuf, String> {
    Ok(preset_dir(&read_active_preset()?))
}

/// Resolve the config dir for a preset name. Empty/whitespace means the
/// active preset. Errors for unknown presets or invalid names.
pub fn resolve_config_dir(preset: &str) -> Result<PathBuf, String> {
    if preset.trim().is_empty() {
        let (config_dir, _) = ensure()?;
        return Ok(config_dir);
    }
    let name = preset.trim().to_string();
    if !valid_preset_name(&name) {
        return Err(format!("Invalid preset name: {name:?}"));
    }
    let dir = preset_dir(&name);
    if !dir.exists() {
        return Err(format!("Preset not found: {name}"));
    }
    Ok(dir)
}

/// List preset names (sorted). Missing presets root yields an empty list.
pub fn list_preset_names() -> Result<Vec<String>, String> {
    let presets = presets_root();
    if !presets.exists() {
        return Ok(Vec::new());
    }
    let mut names = Vec::new();
    for entry in std::fs::read_dir(&presets)
        .map_err(|e| format!("Cannot read presets dir: {e}"))?
    {
        let entry = entry.map_err(|e| format!("Read error: {e}"))?;
        if entry.path().is_dir() {
            if let Some(name) = entry.file_name().to_str() {
                if valid_preset_name(name) {
                    names.push(name.to_string());
                }
            }
        }
    }
    names.sort();
    Ok(names)
}

/// Ensure `~/.alayaface/` exists with the preset structure.
/// On first run, seeds the built-in presets (Default/Fast/Deep/Data/Safe)
/// and marks Default active.
/// Returns `(active_config_dir, sessions_dir)`.
pub fn ensure() -> Result<(PathBuf, PathBuf), String> {
    let base = alayaface_dir();
    let presets = presets_root();
    let sessions = base.join("sessions");

    std::fs::create_dir_all(&presets)
        .map_err(|e| format!("Cannot create {:?}: {}", presets, e))?;
    std::fs::create_dir_all(&sessions)
        .map_err(|e| format!("Cannot create {:?}: {}", sessions, e))?;

    // Seed built-in presets on first run (idempotent per preset).
    for name in SEED_PRESETS {
        let dir = presets.join(name);
        if !dir.exists() {
            create_preset_defaults(&dir, name)?;
        }
    }

    if !active_preset_file().exists() {
        write_active_preset("Default")?;
    }

    let active = read_active_preset()?;
    let config = preset_dir(&active);
    Ok((config, sessions))
}

/// Built-in presets seeded on first run. Each is a config template
/// (model/mcp placeholders); users fill keys and can copy/rename.
pub const SEED_PRESETS: [&str; 5] = ["Default", "Fast", "Deep", "Data", "Safe"];

/// Create a session directory with a copy of the active preset's config.
/// The session.alaya file itself is created by alayacore when the session starts.
/// settings.conf is AlayaFace-owned and intentionally NOT copied into sessions.
pub fn create_session_dir(sessions_dir: &PathBuf, uuid: &str) -> Result<PathBuf, String> {
    create_session_dir_from(sessions_dir, uuid, "")
}

/// Create a session directory from a specific preset's config
/// (`preset` empty = active preset). Used by Plan Mode so different DAG
/// nodes can run under different presets. settings.conf is excluded.
pub fn create_session_dir_from(
    sessions_dir: &PathBuf,
    uuid: &str,
    preset: &str,
) -> Result<PathBuf, String> {
    ensure()?; // guarantee presets exist + active marker set
    let session_dir = sessions_dir.join(uuid);
    let dst_config = session_dir.join("config");
    let template = if preset.is_empty() {
        active_config_dir()?
    } else {
        let dir = preset_dir(preset);
        if !dir.exists() {
            return Err(format!("Preset not found: {preset}"));
        }
        dir
    };

    copy_dir_excluding(&template, &dst_config, &["settings.conf"])?;

    Ok(session_dir)
}

// ─── Internal Helpers ────────────────────────────────────────────────

/// Recursively copy a whole preset directory (including settings.conf) —
/// used when cloning the active preset to create a new one.
pub fn clone_preset_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    copy_dir(src, dst)
}

/// Seed a new preset's config with built-in defaults. `name` selects the
/// template: the Safe preset disables execute_command via settings.conf.
pub fn create_preset_defaults(dir: &std::path::Path, name: &str) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .map_err(|e| format!("Cannot create {:?}: {}", dir, e))?;
    write_defaults(&dir.to_path_buf(), name)
}

fn write_defaults(config: &PathBuf, name: &str) -> Result<(), String> {
    std::fs::write(config.join("model.conf"), DEFAULT_MODEL_CONF)
        .map_err(|e| format!("Cannot write model.conf: {e}"))?;
    std::fs::write(config.join("runtime.conf"), "{}")
        .map_err(|e| format!("Cannot write runtime.conf: {e}"))?;
    std::fs::create_dir_all(config.join("themes"))
        .map_err(|e| format!("Cannot create themes dir: {e}"))?;
    if name == "Safe" {
        // No execute_command: read/write/edit/search only.
        std::fs::write(
            config.join("settings.conf"),
            "{\n  \"tool_confirm\": \"\",\n  \"builtin_tools\": \"read_file,write_file,edit_file,search_content\"\n}\n",
        )
        .map_err(|e| format!("Cannot write settings.conf: {e}"))?;
    }
    Ok(())
}

/// Recursively copy a directory, skipping any files whose names are in `exclude`.
fn copy_dir_excluding(
    src: &std::path::Path,
    dst: &std::path::Path,
    exclude: &[&str],
) -> Result<(), String> {
    std::fs::create_dir_all(dst)
        .map_err(|e| format!("Cannot create {:?}: {}", dst, e))?;
    for entry in std::fs::read_dir(src).map_err(|e| format!("Cannot read {:?}: {}", src, e))? {
        let entry = entry.map_err(|e| format!("Read error: {}", e))?;
        let ty = entry.file_type().map_err(|e| format!("Stat error: {}", e))?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy().to_string();
        if !ty.is_dir() && exclude.contains(&name_str.as_str()) {
            continue;
        }
        if ty.is_dir() {
            copy_dir_excluding(&entry.path(), &dst.join(&name), exclude)?;
        } else {
            std::fs::copy(&entry.path(), &dst.join(&name))
                .map_err(|e| format!("Copy error: {}", e))?;
        }
    }
    Ok(())
}

/// Recursively copy a directory (everything).
fn copy_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    copy_dir_excluding(src, dst, &[])
}

#[cfg(test)]
pub(crate) static TEST_HOME_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

#[cfg(test)]
static TEST_COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

/// Run a closure with HOME pointed at a fresh isolated temp dir, under a
/// process-wide lock. All tests that mutate the HOME env var MUST go through
/// this helper — HOME is process-global, so per-module locks are not enough.
#[cfg(test)]
pub(crate) fn isolated_home<F: FnOnce() -> R, R>(f: F) -> R {
    let _guard = TEST_HOME_LOCK.lock().unwrap();
    let old_home = std::env::var_os("HOME");
    let tmp = std::env::temp_dir().join(format!(
        "alayaface-test-{}-{}",
        std::process::id(),
        TEST_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
    ));
    std::env::set_var("HOME", &tmp);
    let result = f();
    match old_home {
        Some(h) => std::env::set_var("HOME", h),
        None => std::env::remove_var("HOME"),
    }
    let _ = std::fs::remove_dir_all(&tmp);
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preset_name_validation() {
        assert!(valid_preset_name("Default"));
        assert!(valid_preset_name("work-a_b2"));
        assert!(!valid_preset_name(""));
        assert!(!valid_preset_name("a/b"));
        assert!(!valid_preset_name(".."));
        assert!(!valid_preset_name("with space"));
        assert!(!valid_preset_name(&"x".repeat(65)));
    }

    #[test]
    fn ensure_seeds_defaults() {
        isolated_home(|| {
            let (config, _) = ensure().unwrap();
            assert!(config.join("model.conf").exists());
            assert!(config.join("runtime.conf").exists());
            assert!(config.join("themes").is_dir());
            assert_eq!(read_active_preset().unwrap(), "Default");

            // All seed presets exist; Safe disables execute_command.
            for name in SEED_PRESETS {
                assert!(preset_dir(name).is_dir(), "missing seed preset {name}");
            }
            let safe_settings =
                std::fs::read_to_string(preset_dir("Safe").join("settings.conf")).unwrap();
            assert!(safe_settings.contains("read_file,write_file,edit_file,search_content"));
            assert!(!safe_settings.contains("execute_command"));
        });
    }

    #[test]
    fn session_dir_copy_excludes_settings_conf() {
        isolated_home(|| {
            let (config, sessions) = ensure().unwrap();
            // Put a settings.conf in the active preset; it must not be copied.
            std::fs::write(config.join("settings.conf"), "{\"tool_confirm\":\"x\"}").unwrap();

            let session_dir = create_session_dir(&sessions, "abc").unwrap();
            assert!(session_dir.join("config").join("model.conf").exists());
            assert!(!session_dir.join("config").join("settings.conf").exists());
        });
    }

    #[test]
    fn create_session_dir_from_specific_preset() {
        isolated_home(|| {
            let (_, sessions) = ensure().unwrap();
            // Safe's settings.conf must not leak into the session config.
            let dir = create_session_dir_from(&sessions, "xyz", "Safe").unwrap();
            assert!(dir.join("config").join("model.conf").exists());
            assert!(!dir.join("config").join("settings.conf").exists());

            // Unknown preset is rejected.
            assert!(create_session_dir_from(&sessions, "q", "nope").is_err());
        });
    }
}
