//! AlayaFace's own UI-layout file (`~/.alayaface/ui.conf`).
//!
//! Holds what the canvas looked like when the app last closed: every window's
//! rect, the canvas pan/zoom, and which window was solo. AlayaFace-owned like
//! `global.conf` / `asr.conf`, so it follows `--config-path` (per-profile
//! isolation) with no extra plumbing.
//!
//! # The backends are storage, not schema
//!
//! `sync_ui_config` REPLACES the file. That is precisely the `model.conf` trap
//! written up in AGENTS.md: a struct that models the schema silently drops every
//! field it does not know, and the loss surfaces two hops away as "my window
//! came back without its size". So neither backend models the document.
//! `get_ui_config` hands back the stored JSON and `sync_ui_config` writes the
//! JSON it was given — a key added by a NEWER client survives an older backend
//! untouched. The schema lives in exactly one module:
//! `src-elm/src/App/UiConfig.elm`.
//!
//! What the backend does police are the two things that protect the FILE rather
//! than the schema, and both are constants the client mirrors (asserted by
//! `scripts/check-backend-parity.sh`):
//!
//! - `DEFAULT_UI_CONF_VERSION`: the version reported for an absent document, and
//!   the shape check that decides whether this file is a layout at all.
//! - `MAX_STORED_WINDOWS`: the bound on `windows`, so a runaway writer cannot
//!   grow the file without limit. Deciding WHICH entries to evict is the
//!   client's job — only it knows which windows are still open (F3's LRU-by-`t`
//!   rule) — so the backend refuses an oversized document instead of guessing.
//!
//! Reading never fails: a missing, empty, non-object or unparseable `ui.conf`
//! yields "no document" and the client falls back to its own defaults. Layout is
//! the least critical config file the app has, and "your window sizes were
//! unreadable, so the app won't start" is the wrong outcome. Writing DOES fail
//! on a payload that is not a layout document: refusing beats replacing a good
//! file with garbage.

use serde_json::Value;

/// Layout-document version this build writes, and the one an absent document is
/// reported as. Client twin: `UiConfig.version`. Go twin: `DefaultUiConfVersion`.
pub const DEFAULT_UI_CONF_VERSION: i64 = 1;

/// Upper bound on the number of entries in `windows`. Client twin:
/// `UiConfig.maxStoredWindows`. Go twin: `MaxStoredWindows`.
pub const MAX_STORED_WINDOWS: i64 = 200;

/// Path of the layout file (honours `--config-path` like every other
/// AlayaFace-owned conf).
pub fn ui_config_path() -> std::path::PathBuf {
    crate::dirs::alayaface_dir().join("ui.conf")
}

/// Read the stored layout document. `None` = no file, empty file, or a file that
/// is not a JSON object. A parse failure is logged, never surfaced as an error:
/// `ui.conf` is non-critical (unlike `global.conf`, whose corruption IS
/// reported, because it carries user settings rather than window positions).
pub fn read_ui_config() -> Option<Value> {
    let path = ui_config_path();
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(_) => return None,
    };
    if text.trim().is_empty() {
        return None;
    }
    match serde_json::from_str::<Value>(&text) {
        Ok(v) if v.is_object() => Some(v),
        Ok(other) => {
            eprintln!("[ui.conf] ignored: expected a JSON object, found {other}");
            None
        }
        Err(e) => {
            eprintln!("[ui.conf] ignored (not critical, layout falls back to defaults): {e}");
            None
        }
    }
}

/// Can this document replace the stored layout? `None` = accepted; `Some(reason)`
/// = refused. Only structure is checked — types of `version` and `windows` and
/// the window count — because anything deeper would mean the backend models the
/// schema, and then it starts deleting fields it has never heard of.
///
/// The shared fixture `testdata/serialization/ui_cases.json` runs this same
/// table in Go and in the Elm tests, because "a float version" is exactly the
/// kind of case one side accepts and the other refuses.
pub fn ui_config_reject_reason(doc: &Value) -> Option<String> {
    if !doc.is_object() {
        return Some("UI config must be a JSON object".to_string());
    }
    if let Some(v) = doc.get("version") {
        // Integral and >= 1, decided on the FLOAT (not `as_i64`, which rejects
        // a JSON `1.0` because serde stores it as a float): the Go side decodes
        // every JSON number as float64, and the shared fixture caught the two
        // backends disagreeing on exactly that case.
        match v.as_f64() {
            None => return Some("UI config 'version' must be an integer".to_string()),
            Some(f) => {
                if !f.is_finite() || f != f.trunc() {
                    return Some("UI config 'version' must be an integer".to_string());
                }
                if (f as i64) < 1 {
                    return Some("UI config 'version' must be >= 1".to_string());
                }
            }
        }
    }
    if let Some(w) = doc.get("windows") {
        match w.as_object() {
            None => return Some("UI config 'windows' must be an object".to_string()),
            Some(map) => {
                if (map.len() as i64) > MAX_STORED_WINDOWS {
                    return Some(format!(
                        "UI config holds {} windows, over the {MAX_STORED_WINDOWS} limit",
                        map.len()
                    ));
                }
            }
        }
    }
    None
}

/// Read the stored layout. Envelope: `{ ok, version, config, error }` —
/// `config` is the stored document verbatim, or `null` when there is none (the
/// client treats that as "use defaults"); `version` is the document's own
/// version, or `DEFAULT_UI_CONF_VERSION` when absent.
#[tauri::command]
pub async fn get_ui_config() -> Result<Value, String> {
    let version = |doc: &Value| {
        doc.get("version")
            .and_then(Value::as_i64)
            .unwrap_or(DEFAULT_UI_CONF_VERSION)
    };
    Ok(match read_ui_config() {
        Some(doc) => {
            let v = version(&doc);
            serde_json::json!({ "ok": true, "version": v, "config": doc, "error": "" })
        }
        None => serde_json::json!({
            "ok": true,
            "version": DEFAULT_UI_CONF_VERSION,
            "config": Value::Null,
            "error": "",
        }),
    })
}

/// Replace the stored layout with `config` — the WHOLE document, exactly as
/// `UiConfig.encode` produced it. Atomic write via the shared
/// `write_file_atomic` (unique temp name); a payload that is not a layout
/// document is refused rather than written.
#[tauri::command]
pub async fn sync_ui_config(config: String) -> Result<Value, String> {
    let doc: Value = serde_json::from_str(&config).map_err(|e| format!("Invalid UI config JSON: {e}"))?;
    if let Some(why) = ui_config_reject_reason(&doc) {
        return Err(why);
    }
    crate::dirs::ensure()?;
    let text = serde_json::to_string_pretty(&doc).map_err(|e| format!("Failed to serialize UI config: {e}"))?;
    crate::dirs::write_file_atomic(&ui_config_path(), &text).map_err(|e| format!("Failed to write ui.conf: {e}"))?;
    Ok(serde_json::json!({ "ok": true, "written": text.len() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Runtime::new().unwrap()
    }

    #[test]
    fn absent_file_reads_as_no_document() {
        crate::dirs::isolated_home(|| {
            assert!(!ui_config_path().exists());
            assert!(read_ui_config().is_none());
            let got = runtime().block_on(get_ui_config()).expect("get must not fail");
            assert_eq!(got["ok"], true);
            assert!(got["config"].is_null());
            assert_eq!(got["version"], DEFAULT_UI_CONF_VERSION);
        });
    }

    #[test]
    fn round_trip_keeps_every_key_including_unknown_ones() {
        // THE reason the backends do not model the schema: a field only a newer
        // client knows about must survive an older backend's replace.
        crate::dirs::isolated_home(|| {
            let rt = runtime();
            let doc = serde_json::json!({
                "version": 1,
                "soloWin": "sess-1",
                "canvasOffset": { "x": 10, "y": 20 },
                "canvasScale": 1.5,
                "windows": { "sess-1": { "x": 1, "y": 2, "w": 560, "h": 640, "t": 7 } },
                "futureField": { "not": "understood", "here": true }
            });
            rt.block_on(sync_ui_config(doc.to_string())).expect("sync");
            let got = rt.block_on(get_ui_config()).expect("get");
            assert_eq!(got["config"], doc, "the stored document must come back unchanged");
            assert_eq!(got["version"], 1);
        });
    }

    #[test]
    fn corrupt_file_is_not_fatal() {
        crate::dirs::isolated_home(|| {
            std::fs::create_dir_all(crate::dirs::alayaface_dir()).unwrap();
            std::fs::write(ui_config_path(), "{ not json at all").unwrap();
            assert!(read_ui_config().is_none());
            let got = runtime().block_on(get_ui_config()).expect("get must not fail");
            assert_eq!(got["ok"], true);
            assert!(got["config"].is_null());
            // …and a later save still works (the junk file is replaced).
            runtime()
                .block_on(sync_ui_config(serde_json::json!({ "version": 1 }).to_string()))
                .expect("sync over a corrupt file");
            assert!(read_ui_config().is_some());
        });
    }

    #[test]
    fn ui_config_validation_matches_shared_fixture() {
        // M1 truth table (D3): the SAME accept/refuse table drives the Go side
        // (handlers/ui_config_test.go) and the Elm decoder tests.
        #[derive(serde::Deserialize)]
        struct Case {
            name: String,
            input: Value,
            accept: bool,
        }
        #[derive(serde::Deserialize)]
        struct Fixture {
            cases: Vec<Case>,
        }

        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../testdata/serialization/ui_cases.json");
        let text = std::fs::read_to_string(&path).expect("read ui_cases.json fixture");
        let fx: Fixture = serde_json::from_str(&text).expect("parse ui_cases.json fixture");
        assert!(fx.cases.len() >= 8, "fixture too small — a rename? fix the fixture, do not delete the check");

        for c in fx.cases {
            match ui_config_reject_reason(&c.input) {
                None => assert!(c.accept, "case '{}' must be accepted", c.name),
                Some(why) => assert!(!c.accept, "case '{}' must be accepted, refused: {why}", c.name),
            }
        }
    }

    #[test]
    fn non_object_bodies_are_refused_before_they_can_destroy_the_file() {
        crate::dirs::isolated_home(|| {
            let rt = runtime();
            for junk in ["[1,2,3]", "\"windows\"", "42", "null", "not json"] {
                assert!(
                    rt.block_on(sync_ui_config(junk.to_string())).is_err(),
                    "must refuse {junk}"
                );
            }
            assert!(read_ui_config().is_none(), "a refused write must leave no file");
        });
    }

    #[test]
    fn window_count_beyond_the_cap_is_refused() {
        crate::dirs::isolated_home(|| {
            let rt = runtime();
            let mut windows = serde_json::Map::new();
            for i in 0..=MAX_STORED_WINDOWS {
                windows.insert(
                    format!("w{i}"),
                    serde_json::json!({ "x": 0, "y": 0, "w": 560, "h": 640, "t": i }),
                );
            }
            let over = serde_json::json!({ "version": 1, "windows": windows });
            let err = rt.block_on(sync_ui_config(over.to_string())).unwrap_err();
            assert!(err.contains("over the"), "unexpected refusal: {err}");

            let mut at_cap = windows.clone();
            at_cap.remove(&format!("w{MAX_STORED_WINDOWS}"));
            let ok = serde_json::json!({ "version": 1, "windows": at_cap });
            assert!(rt.block_on(sync_ui_config(ok.to_string())).is_ok(), "exactly at the cap must write");
        });
    }

    #[test]
    fn config_path_override_isolates_the_file() {
        // ui.conf belongs to the profile, not to $HOME: two --config-path values
        // must not see each other's layout. Same isolation the other confs test.
        crate::dirs::isolated_home(|| {
            let rt = runtime();
            rt.block_on(sync_ui_config(serde_json::json!({ "version": 1, "soloWin": "x" }).to_string()))
                .expect("sync");
            assert!(ui_config_path().exists(), "written under the profile dir");

            let other = std::env::temp_dir().join("alayaface-ui-other-profile");
            crate::dirs::set_override(other.clone());
            assert!(read_ui_config().is_none(), "the second profile must start empty");
            crate::dirs::set_override(std::path::PathBuf::new());
            let _ = std::fs::remove_dir_all(&other);
        });
    }

    #[test]
    fn writes_leave_no_temp_files_behind() {
        // The unique-temp-name rule (a shared `.tmp` name already bit this repo
        // once, with two clients interleaving into it).
        crate::dirs::isolated_home(|| {
            let rt = runtime();
            for i in 1..=3 {
                let doc = serde_json::json!({ "version": 1, "canvasScale": 0.5 + f64::from(i) * 0.25 });
                rt.block_on(sync_ui_config(doc.to_string())).expect("sync");
            }
            assert_eq!(read_ui_config().unwrap()["canvasScale"], 1.25);
            let leftovers: Vec<_> = std::fs::read_dir(ui_config_path().parent().unwrap())
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
                .collect();
            assert!(leftovers.is_empty(), "temp files left behind: {leftovers:?}");
        });
    }
}
