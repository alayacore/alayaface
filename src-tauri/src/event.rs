//! Event payloads emitted to the frontend via Tauri events.
//!
//! These structs are serialized and sent to the React frontend
//! over Tauri's event system. Every event includes `session_id`.

use serde::Serialize;

/// Emitted when a streaming delta frame (At, Ar) arrives.
#[derive(Debug, Clone, Serialize)]
pub struct DeltaEvent {
    pub session_id: String,
    pub history_id: String,
    pub content: String,
    pub tag: String,
}

/// Emitted when any complete TLV frame arrives from alayacore stdout.
#[derive(Debug, Clone, Serialize)]
pub struct FrameEvent {
    pub session_id: String,
    pub tag: String,
    pub raw_value: String,
    pub history_id: Option<String>,
    pub content: Option<String>,
    pub json: Option<serde_json::Value>,
    /// Set for user-role echo frames (UT/UI/UV/UA/UD on stdout)
    /// so the frontend can distinguish direction and content type.
    pub user_content_type: Option<String>,
}

/// Emitted when the connection status of a session changes.
#[derive(Debug, Clone, Serialize)]
pub struct StatusEvent {
    pub session_id: String,
    pub connected: bool,
    pub message: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    /// M1 truth table (D3): event serialization must produce the exact
    /// JSON bytes in the shared fixture testdata/serialization/
    /// event_cases.json — the same fixture the Go side
    /// (src-go/internal/session/events_test.go) is tested against.
    /// Any field-name, key-order or null-semantics drift breaks one of
    /// the two suites. See REFACTOR.md M1.

    #[derive(serde::Deserialize)]
    struct Fixture {
        frame: Vec<FrameCase>,
        delta: Vec<DeltaCase>,
        status: Vec<StatusCase>,
    }

    #[derive(serde::Deserialize)]
    struct FrameCase {
        name: String,
        input: FrameInput,
        expected: String,
    }

    #[derive(serde::Deserialize)]
    struct FrameInput {
        session_id: String,
        tag: String,
        raw_value: String,
        history_id: Option<String>,
        content: Option<String>,
        /// Raw JSON text, or null.
        json: Option<String>,
        user_content_type: Option<String>,
    }

    #[derive(serde::Deserialize)]
    struct DeltaCase {
        name: String,
        input: DeltaInput,
        expected: String,
    }

    #[derive(serde::Deserialize)]
    struct DeltaInput {
        session_id: String,
        history_id: String,
        content: String,
        tag: String,
    }

    #[derive(serde::Deserialize)]
    struct StatusCase {
        name: String,
        input: StatusInput,
        expected: String,
    }

    #[derive(serde::Deserialize)]
    struct StatusInput {
        session_id: String,
        connected: bool,
        message: String,
    }

    fn load_fixture() -> Fixture {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../testdata/serialization/event_cases.json");
        let text = std::fs::read_to_string(&path).expect("read event_cases.json fixture");
        serde_json::from_str(&text).expect("parse event_cases.json fixture")
    }

    #[test]
    fn frame_event_matches_shared_fixture() {
        let fx = load_fixture();
        for c in fx.frame {
            let json = c
                .input
                .json
                .as_ref()
                .map(|s| serde_json::from_str::<serde_json::Value>(s).expect("fixture json input"));
            let ev = FrameEvent {
                session_id: c.input.session_id,
                tag: c.input.tag,
                raw_value: c.input.raw_value,
                history_id: c.input.history_id,
                content: c.input.content,
                json,
                user_content_type: c.input.user_content_type,
            };
            let got = serde_json::to_string(&ev).unwrap();
            assert_eq!(got, c.expected, "FrameEvent case {}", c.name);
        }
    }

    #[test]
    fn delta_event_matches_shared_fixture() {
        let fx = load_fixture();
        for c in fx.delta {
            let ev = DeltaEvent {
                session_id: c.input.session_id,
                history_id: c.input.history_id,
                content: c.input.content,
                tag: c.input.tag,
            };
            let got = serde_json::to_string(&ev).unwrap();
            assert_eq!(got, c.expected, "DeltaEvent case {}", c.name);
        }
    }

    #[test]
    fn status_event_matches_shared_fixture() {
        let fx = load_fixture();
        for c in fx.status {
            let ev = StatusEvent {
                session_id: c.input.session_id,
                connected: c.input.connected,
                message: c.input.message,
            };
            let got = serde_json::to_string(&ev).unwrap();
            assert_eq!(got, c.expected, "StatusEvent case {}", c.name);
        }
    }
}
