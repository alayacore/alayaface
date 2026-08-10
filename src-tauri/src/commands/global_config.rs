//! Cross-preset global config overlay (`~/.alayaface/global.conf`).
//!
//! Unlike per-preset settings.conf, this file applies to every preset.
//! Currently holds `recursion_limit` (default 8): the Plan Mode recursion
//! bound — node sessions of a plan whose depth exceeds it get no plan
//! system prompt, so the model stops delegating sub-plans.

/// Global config overlay.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct GlobalConfig {
    /// Maximum Plan Mode recursion depth (top-level plan = depth 1,
    /// each sub-plan +1). Below 1 falls back to the default.
    #[serde(default)]
    pub recursion_limit: i64,
}

/// Default recursion limit (used when global.conf is missing or the
/// value is absent/out of range).
pub const DEFAULT_RECURSION_LIMIT: i64 = 8;

impl Default for GlobalConfig {
    fn default() -> Self {
        Self {
            recursion_limit: DEFAULT_RECURSION_LIMIT,
        }
    }
}

/// Normalize a recursion limit: values below 1 fall back to the default
/// (0 = absent = default; a limit must let at least the top-level plan run).
pub fn normalize_recursion_limit(n: i64) -> i64 {
    if n < 1 {
        DEFAULT_RECURSION_LIMIT
    } else {
        n
    }
}

/// Read the global config; a missing/empty file yields defaults. Parse
/// errors are reported (a corrupt global.conf must not be silently ignored).
pub fn read_global_config() -> Result<GlobalConfig, String> {
    let path = crate::dirs::alayaface_dir().join("global.conf");
    match std::fs::read_to_string(&path) {
        Ok(text) if !text.trim().is_empty() => {
            let mut cfg: GlobalConfig = serde_json::from_str(&text)
                .map_err(|e| format!("Failed to parse global.conf: {e}"))?;
            cfg.recursion_limit = normalize_recursion_limit(cfg.recursion_limit);
            Ok(cfg)
        }
        _ => Ok(GlobalConfig::default()),
    }
}

/// Read the global config overlay.
#[tauri::command]
pub async fn get_global_config() -> Result<GlobalConfig, String> {
    read_global_config()
}

/// Replace the global config overlay. Accepts
/// `{"recursion_limit": N}`; writes atomically. The normalized config is
/// returned so the frontend can adopt the effective values.
#[tauri::command]
pub async fn sync_global_config(config: String) -> Result<GlobalConfig, String> {
    let mut cfg: GlobalConfig = serde_json::from_str(&config)
        .map_err(|e| format!("Invalid global config JSON: {e}"))?;
    cfg.recursion_limit = normalize_recursion_limit(cfg.recursion_limit);

    let dir = crate::dirs::alayaface_dir();
    crate::dirs::ensure()?;
    let path = dir.join("global.conf");
    let tmp = path.with_extension("conf.tmp");
    let text = serde_json::to_string_pretty(&cfg)
        .map_err(|e| format!("Failed to serialize global config: {e}"))?;
    std::fs::write(&tmp, text).map_err(|e| format!("Failed to write global.conf: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| format!("Failed to replace global.conf: {e}"))?;
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_yields_default() {
        crate::dirs::isolated_home(|| {
            let cfg = read_global_config().unwrap();
            assert_eq!(cfg.recursion_limit, DEFAULT_RECURSION_LIMIT);
        });
    }

    #[test]
    fn normalize_below_one_falls_back_to_default() {
        assert_eq!(normalize_recursion_limit(0), DEFAULT_RECURSION_LIMIT);
        assert_eq!(normalize_recursion_limit(-3), DEFAULT_RECURSION_LIMIT);
        assert_eq!(normalize_recursion_limit(1), 1);
        assert_eq!(normalize_recursion_limit(12), 12);
    }

    #[test]
    fn sync_roundtrips() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            let cfg = rt
                .block_on(sync_global_config(r#"{"recursion_limit": 12}"#.to_string()))
                .unwrap();
            assert_eq!(cfg.recursion_limit, 12);
            let cfg = read_global_config().unwrap();
            assert_eq!(cfg.recursion_limit, 12);
        });
    }

    #[test]
    fn sync_rejects_invalid() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            assert!(rt
                .block_on(sync_global_config(r#"{"recursion_limit": "many"}"#.to_string()))
                .is_err());
        });
    }

    #[test]
    fn global_config_serialization_matches_shared_fixture() {
        // M1 truth table (D3): global.conf must normalize + serialize to
        // the exact bytes in testdata/serialization/global_cases.json —
        // the same fixture the Go side (handlers/serialization_test.go)
        // is tested against.
        #[derive(serde::Deserialize)]
        struct Fixture {
            cases: Vec<Case>,
        }
        #[derive(serde::Deserialize)]
        struct Case {
            name: String,
            input: Input,
            normalized: Normalized,
            expected_file: String,
        }
        #[derive(serde::Deserialize)]
        struct Input {
            recursion_limit: i64,
        }
        #[derive(serde::Deserialize)]
        struct Normalized {
            recursion_limit: i64,
        }

        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../testdata/serialization/global_cases.json");
        let text = std::fs::read_to_string(&path).expect("read global_cases.json fixture");
        let fx: Fixture = serde_json::from_str(&text).expect("parse global_cases.json fixture");

        for c in fx.cases {
            let n = normalize_recursion_limit(c.input.recursion_limit);
            assert_eq!(n, c.normalized.recursion_limit, "case {}: normalized", c.name);
            let cfg = GlobalConfig {
                recursion_limit: n,
            };
            let got = serde_json::to_string_pretty(&cfg).unwrap();
            assert_eq!(got, c.expected_file, "case {}: file text", c.name);
        }
    }
}
