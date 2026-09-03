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

/// Report whether hash is a sha256 hex digest as produced by object_put (64
/// lowercase hex chars). object_get joins its argument straight into
/// ~/.alayaface/objects/<hash>/content.json, so without this a caller could
/// walk out of the object store with "../../sessions/x/config" and read any
/// file named content.json. Mirrors Go's validObjectHash.
fn valid_object_hash(hash: &str) -> bool {
    hash.len() == 64
        && hash
            .chars()
            .all(|c| c.is_ascii_digit() || ('a'..='f').contains(&c))
}

/// Read an object by hash.
#[tauri::command]
pub async fn object_get(hash: String) -> Result<String, String> {
    if !valid_object_hash(&hash) {
        return Err(format!("Cannot read object: invalid hash {:?}", hash));
    }
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

        // object_get joins its argument straight into
        // ~/.alayaface/objects/<hash>/content.json, so an unvalidated hash can
        // walk out of the store with "../../sessions/x/config" and read any
        // file named content.json. Mirrors Go's
        // TestObjectGetRejectsNonHashPaths.
        let sha = |s: &str| {
            let mut h = Sha256::new();
            h.update(s.as_bytes());
            hex::encode(h.finalize())
        };
        assert!(valid_object_hash(&sha("x")));
        let bad: Vec<String> = vec![
            String::new(),
            "..".to_string(),
            "../../sessions/x/config".to_string(),
            "ab".repeat(31) + "z", // 64 chars, not hex
            "AB".repeat(32),       // 64 chars, wrong case (digests are lowercase)
            "ab".repeat(32) + "0", // 65 chars
        ];
        for b in &bad {
            assert!(!valid_object_hash(b), "accepted hash {b:?}");
        }
    }
}
