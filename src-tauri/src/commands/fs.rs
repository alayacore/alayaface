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

/// List the contents of a directory. A non-existent directory returns an
/// EMPTY list (not an error): the plans dir may not exist until the first
/// plan is auto-created, and callers (plan meta index rebuild, manager,
/// browser) treat a missing directory as "nothing here".
#[command]
pub async fn fs_list_dir(path: String) -> Result<Vec<DirEntry>, String> {
    let dir = std::path::Path::new(&path);
    if !dir.exists() {
        return Ok(vec![]);
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

/// Guess MIME type from a file extension.
///
/// The extension is lowercased first: real recordings and camera files
/// carry uppercase suffixes (`.JPG`, `.PNG`, `.MOV`), and Go's `guessMime`
/// already matched case-insensitively — without this the same attachment
/// resolved to `image/jpeg` on the Go backend but
/// `application/octet-stream` here, so a `.PNG` preview broke only in the
/// Tauri app (and a prompt built from it carried the wrong content type).
fn guess_mime(path: &std::path::Path) -> &'static str {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match ext.as_str() {
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

/// File-size caps for the fs commands (mirrors Go). Reading a file fully
/// into memory (data URIs base64-encode it, ~1.33×) and shipping it over
/// IPC must not OOM the backend — a multi-GB media file would otherwise
/// be loaded whole.
const MAX_DATA_URI_FILE_SIZE: u64 = 64 << 20; // 64 MiB
pub const MAX_TEXT_FILE_SIZE: u64 = 16 << 20; // 16 MiB

/// Verify a file is within `limit` before reading it whole.
pub fn check_file_size(path: &std::path::Path, limit: u64) -> Result<(), String> {
    let meta = std::fs::metadata(path).map_err(|e| format!("Cannot read file: {}", e))?;
    if meta.len() > limit {
        return Err(format!(
            "Cannot read file: file too large ({} bytes, limit {} MiB)",
            meta.len(),
            limit >> 20
        ));
    }
    Ok(())
}

/// Read a file and return it as a data URI string.
#[command]
pub async fn fs_read_file_data_uri(path: String) -> Result<String, String> {
    let p = std::path::Path::new(&path);
    check_file_size(p, MAX_DATA_URI_FILE_SIZE)?;
    let data = std::fs::read(p)
        .map_err(|e| format!("Cannot read file: {}", e))?;
    let mime = guess_mime(p);
    let b64 = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, &data);
    Ok(format!("data:{};base64,{}", mime, b64))
}

/// Write a UTF-8 text file. `create_parents` (default false) creates the
/// parent directory chain first. Used by Plan Mode to save plan/run JSON.
#[command]
pub async fn fs_write_file_text(
    path: String,
    content: String,
    create_parents: Option<bool>,
) -> Result<(), String> {
    let p = std::path::Path::new(&path);
    if create_parents.unwrap_or(false) {
        if let Some(parent) = p.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)
                    .map_err(|e| format!("Cannot write file: {}", e))?;
            }
        }
    }
    std::fs::write(p, content).map_err(|e| format!("Cannot write file: {}", e))
}

/// Read a UTF-8 text file. Used by Plan Mode to load plan/run JSON.
#[command]
pub async fn fs_read_file_text(path: String) -> Result<String, String> {
    let p = std::path::Path::new(&path);
    check_file_size(p, MAX_TEXT_FILE_SIZE)?;
    std::fs::read_to_string(p).map_err(|e| format!("Cannot read file: {}", e))
}

/// Delete a file. Used by Plan Mode to remove saved plans.
#[command]
pub async fn fs_delete_file(path: String) -> Result<(), String> {
    let p = std::path::Path::new(&path);
    if !p.exists() {
        return Err("Cannot delete file: Path does not exist".to_string());
    }
    if p.is_dir() {
        return Err("Cannot delete file: Is a directory".to_string());
    }
    std::fs::remove_file(p).map_err(|e| format!("Cannot delete file: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_path(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "alayaface-fs-test-{}-{}",
            std::process::id(),
            name
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[tokio::test]
    async fn write_read_roundtrip() {
        let dir = temp_path("roundtrip");
        let file = dir.join("a.txt");
        let path = file.to_string_lossy().to_string();
        fs_write_file_text(path.clone(), "hello world".to_string(), Some(false)).await.unwrap();
        let out = fs_read_file_text(path).await.unwrap();
        assert_eq!(out, "hello world");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn create_parents_creates_directories() {
        let dir = temp_path("parents");
        let file = dir.join("deep").join("nested").join("b.txt");
        let path = file.to_string_lossy().to_string();
        fs_write_file_text(path.clone(), "x".to_string(), Some(true)).await.unwrap();
        assert!(file.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn write_without_parents_fails_cleanly() {
        let dir = temp_path("noparents");
        let file = dir.join("missing").join("c.txt");
        let path = file.to_string_lossy().to_string();
        let err = fs_write_file_text(path.clone(), "x".to_string(), Some(false))
            .await
            .unwrap_err();
        assert!(err.starts_with("Cannot write file:"), "got: {err}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn read_missing_file_fails_cleanly() {
        let dir = temp_path("missingread");
        let file = dir.join("nope.txt");
        let path = file.to_string_lossy().to_string();
        let err = fs_read_file_text(path).await.unwrap_err();
        assert!(err.starts_with("Cannot read file:"), "got: {err}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn delete_file_roundtrip() {
        let dir = temp_path("delete");
        let file = dir.join("d.txt");
        let path = file.to_string_lossy().to_string();
        fs_write_file_text(path.clone(), "x".to_string(), Some(false)).await.unwrap();
        fs_delete_file(path.clone()).await.unwrap();
        assert!(!file.exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn delete_missing_file_fails_cleanly() {
        let dir = temp_path("deletemissing");
        let file = dir.join("nope.txt");
        let path = file.to_string_lossy().to_string();
        let err = fs_delete_file(path).await.unwrap_err();
        assert_eq!(err, "Cannot delete file: Path does not exist");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn read_file_rejects_oversized_files() {
        let dir = temp_path("oversize");
        // Sparse files via set_len — no multi-MB writes.
        let big = dir.join("big.bin");
        let f = std::fs::File::create(&big).unwrap();
        f.set_len(MAX_DATA_URI_FILE_SIZE + 1).unwrap();
        drop(f);
        let err = fs_read_file_data_uri(big.to_string_lossy().to_string())
            .await
            .unwrap_err();
        assert!(err.contains("file too large"), "data URI oversized: {err}");

        let big_text = dir.join("big.txt");
        let f = std::fs::File::create(&big_text).unwrap();
        f.set_len(MAX_TEXT_FILE_SIZE + 1).unwrap();
        drop(f);
        let err = fs_read_file_text(big_text.to_string_lossy().to_string())
            .await
            .unwrap_err();
        assert!(err.contains("file too large"), "text oversized: {err}");

        // Small files still read fine.
        let small = dir.join("small.txt");
        std::fs::write(&small, "hello").unwrap();
        let out = fs_read_file_text(small.to_string_lossy().to_string()).await.unwrap();
        assert_eq!(out, "hello");
        let _ = std::fs::remove_dir_all(&dir);
    }    #[tokio::test]
    async fn delete_directory_fails_cleanly() {
        let dir = temp_path("deletedir");
        let path = dir.to_string_lossy().to_string();
        let err = fs_delete_file(path).await.unwrap_err();
        assert_eq!(err, "Cannot delete file: Is a directory");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn guess_mime_is_case_insensitive() {
        // Camera/phone files carry uppercase suffixes. Go's guessMime
        // lowercases; matching it keeps a .PNG previewing identically on
        // both backends instead of degrading to octet-stream here.
        assert_eq!(guess_mime(std::path::Path::new("/x/a.PNG")), "image/png");
        assert_eq!(guess_mime(std::path::Path::new("/x/a.JPG")), "image/jpeg");
        assert_eq!(guess_mime(std::path::Path::new("/x/a.MOV")), "video/quicktime");
        assert_eq!(guess_mime(std::path::Path::new("/x/a.mp4")), "video/mp4");
        assert_eq!(guess_mime(std::path::Path::new("/x/no-suffix")), "application/octet-stream");
        assert_eq!(guess_mime(std::path::Path::new("/x/a.weIrD")), "application/octet-stream");
    }
}
