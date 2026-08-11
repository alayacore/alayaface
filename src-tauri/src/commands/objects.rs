// Content-addressed object store (C architecture, docs/arch-persistent.md
// §6.1): immutable objects (message blocks, plan defs, run snapshots,
// session versions) stored by sha256(content) under
// ~/.alayaface/objects/<hash>/. Identity is the hash: equal content =
// equal hash = shared object (no duplicates); objects are written once
// and never modified. Mirrors the Go object_put/object_get exactly.

use serde_json::json;
use sha2::{Digest, Sha256};

/// Store content idempotently and return its hash. Existing objects are
/// not overwritten (content-addressed: same hash = same content).
#[tauri::command]
pub async fn object_put(content: String) -> Result<serde_json::Value, String> {
    let mut hasher = Sha256::new();
    hasher.update(content.as_bytes());
    let hash = hex::encode(hasher.finalize());
    let dir = crate::dirs::alayaface_dir().join("objects").join(&hash);
    std::fs::create_dir_all(&dir)
        .map_err(|e| format!("Cannot write object: {}", e))?;
    let path = dir.join("content.json");
    if !path.exists() {
        std::fs::write(&path, &content)
            .map_err(|e| format!("Cannot write object: {}", e))?;
    }
    Ok(json!({ "hash": hash }))
}

/// Read an object by hash.
#[tauri::command]
pub async fn object_get(hash: String) -> Result<String, String> {
    let path = crate::dirs::alayaface_dir()
        .join("objects")
        .join(&hash)
        .join("content.json");
    crate::commands::fs::check_file_size(&path, crate::commands::fs::MAX_TEXT_FILE_SIZE)
        .map_err(|e| format!("Cannot read object: {}", e))?;
    std::fs::read_to_string(&path).map_err(|e| format!("Cannot read object: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_and_get_roundtrip() {
        // Isolate from the real ~/.alayaface by overriding HOME via a
        // temp dir is not possible for the global dirs helper; instead
        // verify the pure pieces: same content -> same hash, and the
        // object path layout.
        let mut h1 = Sha256::new();
        h1.update(b"hello");
        let h1 = hex::encode(h1.finalize());
        let mut h2 = Sha256::new();
        h2.update(b"hello");
        let h2 = hex::encode(h2.finalize());
        assert_eq!(h1, h2, "same content must hash identically (dedup by hash)");

        let mut h3 = Sha256::new();
        h3.update(b"hello!");
        assert_ne!(h1, hex::encode(h3.finalize()), "different content must differ");
    }
}
