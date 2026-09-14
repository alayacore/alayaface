//! Session label (G-series, docs/session-identity.md): the user-visible name
//! of a session, stored as `<sessionDir>/session.label.json`.
//!
//! # The backend stores a document it does not model
//!
//! Same rule as `ui.conf`: the CLIENT owns the schema
//! (`src-elm/src/Session/Labels.elm`), so nothing here decodes the label into a
//! struct and writes the struct back — that is the AGENTS.md trap where an
//! unmodelled field is silently deleted on the next save. What IS policed is the
//! structure that protects the file: the id must be one path component, the
//! target must be a real top-level session, and `label` must be a string within
//! `MAX_LABEL_CHARS`.
//!
//! # Why a command of its own (SD-G16)
//!
//! The write could have ridden `fs_write_file_text`, and the design doc said it
//! would. That port's reply is `{ok, error}` and nothing else — no path, no
//! reqId — so a second writer's failure would be attributed to the first (today:
//! a failed rename would clear the ACTIVE PLAN WINDOW's `saving` flag and file
//! the error under the plan's error list). A name a user cannot see the failure
//! of is a name that silently never saved, so this command answers with its own
//! result. Go twin: `internal/server/handlers/label.go`.

use serde_json::{json, Value};

/// Refusal messages the client displays verbatim. Twins of the Go consts in
/// handlers/label.go, asserted by scripts/check-backend-parity.sh's error-string
/// section and by the shared fixture's write_cases — a divergent string is
/// invisible to a command-name check and user-visible on exactly one deployment.
const LABEL_ERR_BAD_ID: &str = "Session id is not a single path component";
const LABEL_ERR_NOT_TOP: &str = "Not a top-level session";
const LABEL_ERR_DOC_SHAPE: &str = "Session label document must be a JSON object";
const LABEL_ERR_NO_LABEL: &str = "Session label document has no 'label'";
const LABEL_ERR_TYPE: &str = "Session label 'label' must be a string";
const LABEL_ERR_TOO_LONG: &str = "Session label is over the character limit";

/// Can this document be stored? `None` = accepted; `Some(reason)` = refused.
/// Takes the RAW payload the client sent — the same bytes that get stored — so
/// the shape question is asked once, about the value actually written.
///
/// `label` is the only key inspected: `v` and `auto` are the client's business
/// (SD-G5), and an unmodelled key must never make a name fail to save.
///
/// The shared fixture `testdata/serialization/label_cases.json` runs this table
/// against the Go side too, because "120 hanzi is 360 bytes" is exactly the
/// sort of case one backend accepts while the other refuses.
pub fn label_reject_reason(raw: &str) -> Option<String> {
    match serde_json::from_str::<Value>(raw) {
        Ok(doc) => reject_doc(&doc),
        Err(_) => Some(LABEL_ERR_DOC_SHAPE.to_string()),
    }
}

fn reject_doc(doc: &Value) -> Option<String> {
    let obj = match doc.as_object() {
        Some(o) => o,
        // `null` and `[1,2]` parse fine and are still not a document.
        None => return Some(LABEL_ERR_DOC_SHAPE.to_string()),
    };
    let raw = match obj.get("label") {
        Some(v) => v,
        None => return Some(LABEL_ERR_NO_LABEL.to_string()),
    };
    let text = match raw.as_str() {
        Some(s) => s,
        None => return Some(LABEL_ERR_TYPE.to_string()),
    };
    // CHARACTERS, not bytes (SD-G10) — the same unit read_session_label counts.
    if text.chars().count() > crate::dirs::MAX_LABEL_CHARS {
        return Some(LABEL_ERR_TOO_LONG.to_string());
    }
    None
}

/// Read `label` back from a document `label_reject_reason` already accepted.
/// Never call it on an unchecked document: a missing or mistyped key reads as
/// `""` here, which would then DELETE the file instead of refusing it.
fn label_of(doc: &Value) -> String {
    doc.get("label").and_then(Value::as_str).unwrap_or_default().to_string()
}

/// Store the client's label document, or remove the file when the label is
/// blank (SD-G15's "no name" is the absence of a file, not a tombstone).
#[tauri::command]
pub async fn sync_session_label(session_id: String, document: String) -> Result<Value, String> {
    // The id arrives from the client and becomes a path component, so a
    // traversal must be refused rather than sanitised away (the same rule
    // delete_session_dir relies on for RemoveAll).
    if !crate::dirs::safe_path_component(&session_id) {
        return Err(LABEL_ERR_BAD_ID.to_string());
    }
    let dir = crate::dirs::alayaface_dir().join("sessions").join(&session_id);
    // A directory is not a session: require what list_session_dirs requires.
    // This also enforces SD-G15 — plan node sessions live deeper and cannot be
    // named even by a client that tried.
    if !dir.join("session.alaya").exists() {
        return Err(LABEL_ERR_NOT_TOP.to_string());
    }
    if let Some(why) = label_reject_reason(&document) {
        return Err(why);
    }
    let doc: Value = serde_json::from_str(&document).map_err(|e| e.to_string())?;
    crate::dirs::ensure()?;
    if label_of(&doc).trim().is_empty() {
        crate::dirs::remove_session_label(&dir)?;
        return Ok(json!({ "ok": true, "removed": true }));
    }
    // Stored VERBATIM: the client owns the document, and re-marshalling here
    // would let the two backends write different bytes for the same name (Go
    // sorts map keys, serde_json keeps insertion order) — a difference no reader
    // cares about and every diff tool would have to explain.
    crate::dirs::write_session_label(&dir, &document)?;
    Ok(json!({ "ok": true, "written": document.len() }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(label: &str) -> String {
        json!({ "v": 1, "label": label, "auto": false }).to_string()
    }

    #[test]
    fn accepts_a_name_up_to_the_cap_in_characters() {
        assert_eq!(label_reject_reason(&doc("refactor the parser")), None);
        // 120 HANZI = 360 BYTES and must be accepted (SD-G10's unit).
        assert_eq!(label_reject_reason(&doc(&"中".repeat(120))), None);
        assert_eq!(label_reject_reason(&doc(&"a".repeat(120))), None);
    }

    #[test]
    fn refuses_over_the_cap_and_wrong_shapes() {
        assert_eq!(
            label_reject_reason(&doc(&"中".repeat(121))),
            Some(LABEL_ERR_TOO_LONG.to_string())
        );
        assert_eq!(
            label_reject_reason(r#"{"v":1}"#),
            Some(LABEL_ERR_NO_LABEL.to_string())
        );
        assert_eq!(
            label_reject_reason(r#"{"label":42}"#),
            Some(LABEL_ERR_TYPE.to_string())
        );
        assert_eq!(
            label_reject_reason("[1,2]"),
            Some(LABEL_ERR_DOC_SHAPE.to_string())
        );
        assert_eq!(
            label_reject_reason("null"),
            Some(LABEL_ERR_DOC_SHAPE.to_string())
        );
        assert_eq!(
            label_reject_reason("not json"),
            Some(LABEL_ERR_DOC_SHAPE.to_string())
        );
    }

    /// An unmodelled key must never block a save, whatever its type: a newer
    /// client may add fields this build has never heard of.
    #[test]
    fn ignores_fields_it_does_not_model() {
        assert_eq!(
            label_reject_reason(r#"{"v":99,"label":"ok","auto":"yes","future":[1,2]}"#),
            None
        );
    }

    #[test]
    fn label_of_only_runs_on_accepted_documents() {
        let ok = serde_json::from_str::<Value>(&doc("重构 parser")).unwrap();
        assert_eq!(label_of(&ok), "重构 parser");
        let blank = serde_json::from_str::<Value>(&doc("   ")).unwrap();
        assert!(label_of(&blank).trim().is_empty(), "blank means remove-the-file");
    }

    /// The Go side runs the SAME table
    /// (`TestLabelWriteTableMatchesSharedFixture`); a divergent refusal string
    /// is user-visible on one deployment only, and no command-name check can
    /// see it.
    #[test]
    fn write_table_matches_shared_fixture() {
        #[derive(serde::Deserialize)]
        struct WriteCase {
            name: String,
            document: Value,
            expected: String,
        }
        #[derive(serde::Deserialize)]
        struct Fixture {
            write_cases: Vec<WriteCase>,
        }
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../testdata/serialization/label_cases.json");
        let text = std::fs::read_to_string(&path).expect("read label_cases.json fixture");
        let fx: Fixture = serde_json::from_str(&text).expect("parse label_cases.json fixture");
        assert!(!fx.write_cases.is_empty(), "write_cases is empty");
        for c in fx.write_cases {
            let got = match label_reject_reason(&c.document.to_string()) {
                Some(reason) => reason,
                None => "ok".to_string(),
            };
            assert_eq!(got, c.expected, "write case {}", c.name);
        }
    }

    /// The command's own guards, on a real temp store: a name is stored
    /// verbatim, a blank removes the file, and an id that is not one path
    /// component never reaches the filesystem.
    #[test]
    fn sync_stores_removes_and_refuses() {
        crate::dirs::isolated_home(|| {
            let rt = tokio::runtime::Runtime::new().unwrap();
            rt.block_on(async {
                let dir = crate::dirs::alayaface_dir().join("sessions").join("s-1");
                std::fs::create_dir_all(&dir).unwrap();
                std::fs::write(dir.join("session.alaya"), "[]").unwrap();

                sync_session_label("s-1".into(), doc("重构 parser")).await.unwrap();
                let on_disk = std::fs::read_to_string(crate::dirs::label_file(&dir)).unwrap();
                assert_eq!(on_disk, doc("重构 parser"), "stored verbatim");
                assert_eq!(crate::dirs::read_session_label(&dir), "重构 parser");

                // blank → the file is gone, not emptied
                sync_session_label("s-1".into(), doc("   ")).await.unwrap();
                assert!(!crate::dirs::label_file(&dir).exists(), "no tombstone");

                // traversal and unknown sessions never reach the store
                assert_eq!(
                    sync_session_label("../escape".into(), doc("x")).await.unwrap_err(),
                    LABEL_ERR_BAD_ID
                );
                assert_eq!(
                    sync_session_label("nope".into(), doc("x")).await.unwrap_err(),
                    LABEL_ERR_NOT_TOP
                );
                assert!(!crate::dirs::alayaface_dir()
                    .join("..")
                    .join("escape")
                    .join("session.label.json")
                    .exists());
            });
        });
    }
}
