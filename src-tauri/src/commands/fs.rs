//! File system Tauri commands.
//!
//! Commands for listing directories, reading files as data URIs,
//! resolving paths, and getting the home directory.

use serde::Serialize;
use tauri::command;

#[derive(Serialize)]
pub struct DirEntry {
    pub name: String,
    #[serde(rename = "isDir")]
    pub is_dir: bool,
}

/// List the contents of a directory.
#[command]
pub async fn fs_list_dir(path: String) -> Result<Vec<DirEntry>, String> {
    let dir = std::path::Path::new(&path);
    if !dir.exists() {
        return Err(format!("Path does not exist: {}", path));
    }
    if !dir.is_dir() {
        return Err(format!("Not a directory: {}", path));
    }

    let mut entries = std::fs::read_dir(dir)
        .map_err(|e| format!("Cannot read directory: {}", e))?
        .filter_map(|e| e.ok())
        .collect::<Vec<_>>();
    entries.sort_by_key(|e| e.file_name());

    let mut result = Vec::with_capacity(entries.len() + 1);

    // Add ".." parent entry for all directories except root
    if path != "/" {
        result.push(DirEntry {
            name: "..".to_string(),
            is_dir: true,
        });
    }

    // Separate dirs and files for sorting: dirs first, then files
    let mut dirs: Vec<DirEntry> = Vec::new();
    let mut files: Vec<DirEntry> = Vec::new();

    for entry in entries {
        let name = entry.file_name().to_string_lossy().to_string();
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        let de = DirEntry { name, is_dir };
        if is_dir {
            dirs.push(de);
        } else {
            files.push(de);
        }
    }

    // Directories first (sorted), then files (sorted)
    dirs.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
    files.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    result.extend(dirs);
    result.extend(files);

    Ok(result)
}

/// Get the user's home directory path.
#[command]
pub async fn fs_home_dir() -> Result<String, String> {
    std::env::var("HOME")
        .or_else(|_| std::env::var("USERPROFILE"))
        .map_err(|_| "Cannot determine home directory".to_string())
}

/// Resolve a path (handles ~, ., ..) and return info.
#[derive(Serialize)]
pub struct ResolvedPath {
    pub resolved: String,
    pub exists: bool,
    #[serde(rename = "isDir")]
    pub is_dir: bool,
}

#[command]
pub async fn fs_resolve_path(path: String) -> Result<ResolvedPath, String> {
    let resolved = if path.starts_with('~') {
        let home = std::env::var("HOME")
            .or_else(|_| std::env::var("USERPROFILE"))
            .unwrap_or_else(|_| ".".to_string());
        std::path::PathBuf::from(home).join(&path[1..])
    } else if path.starts_with('/') {
        std::path::PathBuf::from(&path)
    } else {
        // Relative: resolve from current dir
        let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."));
        cwd.join(&path)
    };

    // Normalize (resolve . and ..)
    let normalized = if let Ok(canon) = std::fs::canonicalize(&resolved) {
        canon
    } else {
        // If path doesn't exist, do our best to normalize
        let mut components: Vec<&str> = Vec::new();
        for component in resolved.components() {
            match component {
                std::path::Component::Normal(c) => components.push(c.to_str().unwrap_or("")),
                std::path::Component::ParentDir => { components.pop(); }
                _ => {}
            }
        }
        let base = if path.starts_with('~') || path.starts_with('/') {
            std::path::PathBuf::from("/")
        } else {
            std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("."))
        };
        base.join(components.join("/"))
    };

    let exists = normalized.exists();
    let is_dir = exists && normalized.is_dir();

    Ok(ResolvedPath {
        resolved: normalized.to_string_lossy().to_string(),
        exists,
        is_dir,
    })
}

/// Guess MIME type from file extension.
fn guess_mime(path: &std::path::Path) -> &str {
    match path.extension().and_then(|e| e.to_str()).unwrap_or("") {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "mp3" => "audio/mpeg",
        "wav" => "audio/wav",
        "ogg" | "oga" => "audio/ogg",
        "flac" => "audio/flac",
        "m4a" => "audio/mp4",
        "mp4" => "video/mp4",
        "webm" => "video/webm",
        "avi" => "video/x-msvideo",
        "mov" => "video/quicktime",
        "mkv" => "video/x-matroska",
        "pdf" => "application/pdf",
        "txt" | "md" => "text/plain",
        "json" => "application/json",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        "js" => "text/javascript",
        "ts" => "text/typescript",
        "rs" => "text/rust",
        "py" => "text/x-python",
        "go" => "text/x-go",
        "java" => "text/x-java",
        "c" => "text/x-c",
        "cpp" | "cc" | "cxx" => "text/x-c++",
        "h" | "hpp" => "text/x-header",
        "yaml" | "yml" => "text/yaml",
        "toml" => "text/toml",
        "xml" => "text/xml",
        _ => "application/octet-stream",
    }
}

/// Read a file and return it as a data URI string.
#[command]
pub async fn fs_read_file_data_uri(path: String) -> Result<String, String> {
    let p = std::path::Path::new(&path);
    let data = std::fs::read(p)
        .map_err(|e| format!("Cannot read file: {}", e))?;
    let mime = guess_mime(p);
    let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &data);
    Ok(format!("data:{};base64,{}", mime, b64))
}
