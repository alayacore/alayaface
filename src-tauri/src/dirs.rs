//! Directory and file management for AlayaFace.
//!
//! Manages `~/.alayaface/` structure:
//!   ~/.alayaface/
//!     config/
//!       model.conf
//!       runtime.conf
//!       themes/
//!     sessions/
//!       <uuid>/
//!         config/   (copy of template)
//!         session.md

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

/// Ensure `~/.alayaface/` exists with default configs.
/// Returns `(config_dir, sessions_dir)`.
pub fn ensure() -> Result<(PathBuf, PathBuf), String> {
    let base = alayaface_dir();
    let config = base.join("config");
    let sessions = base.join("sessions");

    std::fs::create_dir_all(&config)
        .map_err(|e| format!("Cannot create {:?}: {}", config, e))?;
    std::fs::create_dir_all(&sessions)
        .map_err(|e| format!("Cannot create {:?}: {}", sessions, e))?;

    // First run: copy from ~/.alayacore/ or write defaults
    let model_conf = config.join("model.conf");
    if !model_conf.exists() {
        let alayacore_dir = {
            let home = std::env::var("HOME")
                .or_else(|_| std::env::var("USERPROFILE"))
                .unwrap_or_else(|_| ".".to_string());
            PathBuf::from(home).join(".alayacore")
        };

        if alayacore_dir.exists() {
            copy_from_alayacore(&alayacore_dir, &config)?;
        } else {
            write_defaults(&config)?;
        }
    }

    Ok((config, sessions))
}

/// Create a session directory with config copy and empty session.md.
pub fn create_session_dir(sessions_dir: &PathBuf, uuid: &str) -> Result<PathBuf, String> {
    let session_dir = sessions_dir.join(uuid);
    let dst_config = session_dir.join("config");
    let session_file = session_dir.join("session.md");

    let template = sessions_dir
        .parent()
        .map(|p| p.join("config"))
        .unwrap_or_else(|| alayaface_dir().join("config"));

    copy_dir(&template, &dst_config)?;
    std::fs::write(&session_file, "")
        .map_err(|e| format!("Cannot create {:?}: {}", session_file, e))?;

    Ok(session_dir)
}

// ─── Internal Helpers ────────────────────────────────────────────────

fn copy_from_alayacore(src: &PathBuf, dst: &PathBuf) -> Result<(), String> {
    let src_model = src.join("model.conf");
    if src_model.exists() {
        std::fs::copy(&src_model, dst.join("model.conf"))
            .map_err(|e| format!("Cannot copy model.conf: {e}"))?;
    } else {
        std::fs::write(dst.join("model.conf"), DEFAULT_MODEL_CONF)
            .map_err(|e| format!("Cannot write model.conf: {e}"))?;
    }

    let src_runtime = src.join("runtime.conf");
    if src_runtime.exists() {
        std::fs::copy(&src_runtime, dst.join("runtime.conf"))
            .map_err(|e| format!("Cannot copy runtime.conf: {e}"))?;
    } else {
        std::fs::write(dst.join("runtime.conf"), "{}")
            .map_err(|e| format!("Cannot write runtime.conf: {e}"))?;
    }

    let src_themes = src.join("themes");
    let dst_themes = dst.join("themes");
    if src_themes.exists() {
        copy_dir(&src_themes, &dst_themes)?;
    } else {
        std::fs::create_dir_all(&dst_themes)
            .map_err(|e| format!("Cannot create themes dir: {e}"))?;
    }
    Ok(())
}

fn write_defaults(config: &PathBuf) -> Result<(), String> {
    std::fs::write(config.join("model.conf"), DEFAULT_MODEL_CONF)
        .map_err(|e| format!("Cannot write model.conf: {e}"))?;
    std::fs::write(config.join("runtime.conf"), "{}")
        .map_err(|e| format!("Cannot write runtime.conf: {e}"))?;
    std::fs::create_dir_all(config.join("themes"))
        .map_err(|e| format!("Cannot create themes dir: {e}"))?;
    Ok(())
}

fn copy_dir(src: &std::path::Path, dst: &std::path::Path) -> Result<(), String> {
    std::fs::create_dir_all(dst)
        .map_err(|e| format!("Cannot create {:?}: {}", dst, e))?;
    for entry in std::fs::read_dir(src).map_err(|e| format!("Cannot read {:?}: {}", src, e))? {
        let entry = entry.map_err(|e| format!("Read error: {}", e))?;
        let ty = entry.file_type().map_err(|e| format!("Stat error: {}", e))?;
        let name = entry.file_name();
        if ty.is_dir() {
            copy_dir(&entry.path(), &dst.join(&name))?;
        } else {
            std::fs::copy(&entry.path(), &dst.join(&name))
                .map_err(|e| format!("Copy error: {}", e))?;
        }
    }
    Ok(())
}
