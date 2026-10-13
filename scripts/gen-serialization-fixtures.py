#!/usr/bin/env python3
"""Generate shared serialization truth-table fixtures for M1.

The fixture files under testdata/serialization/ are the single source of
truth for the Rust/Go/Elm wire contract: same logical input -> identical
JSON output on BOTH backends (see REFACTOR.md M1 / D3).

Expected strings are constructed from the DOCUMENTED wire format (not
from either backend's implementation) so the fixture can catch drift on
either side.

Field order (both backends):
    FrameEvent = session_id, tag, raw_value, history_id, content, json,
                 content_type
    DeltaEvent = session_id, history_id, content, tag, content_type
    StatusEvent = session_id, connected, message

The `json` payload object is stored in CANONICAL (key-sorted) form:
JSON object key order is not part of the wire contract (RFC 8259), and
the two backends legitimately differ — Go forwards RawMessage verbatim
(frame order), Rust re-serializes serde_json::Value (BTreeMap sorted).
The fixture pins the canonical form so both produce identical bytes.

Usage: python3 scripts/gen-serialization-fixtures.py
"""
import json
import os
from collections import OrderedDict

OUT = os.path.join(os.path.dirname(__file__), "..", "testdata", "serialization")
os.makedirs(OUT, exist_ok=True)


def dump(name, data):
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=True)
        f.write("\n")
    print(f"wrote {path}")


def q(v):
    """JSON literal for a string or None."""
    return "null" if v is None else json.dumps(v, ensure_ascii=True)


def jstr(obj):
    """Canonical (key-sorted) compact JSON text for the `json` field."""
    return json.dumps(obj, separators=(",", ":"), ensure_ascii=True, sort_keys=True)


def frame_case(name, tag, raw_value, history_id, content, json_obj, content_type):
    """Build one FrameEvent case.

    `json_obj` is the parsed payload object (or None); its canonical,
    key-sorted text is what the fixture records in the `json` field, so
    the expected bytes are independent of how either backend stores it.
    """
    inp = OrderedDict()
    inp["session_id"] = "s1"
    inp["tag"] = tag
    inp["raw_value"] = raw_value
    inp["history_id"] = history_id
    inp["content"] = content
    inp["json"] = jstr(json_obj) if json_obj is not None else None
    inp["content_type"] = content_type
    json_field = jstr(json_obj) if json_obj is not None else "null"
    expected = (
        '{"session_id":"s1"'
        + ',"tag":' + q(tag)
        + ',"raw_value":' + q(raw_value)
        + ',"history_id":' + q(history_id)
        + ',"content":' + q(content)
        + ',"json":' + json_field
        + ',"content_type":' + q(content_type)
        + "}"
    )
    return {"name": name, "input": inp, "expected": expected}


content_text = OrderedDict(
    [("id", "h1"), ("time", "2026-10-14T02:06:07Z"), ("type", "text"), ("text", "hi")]
)
content_image = OrderedDict(
    [("id", "2"), ("type", "image"), ("uri", "data:image/png;base64,AA")]
)
ax_terminator = OrderedDict([("id", "h1"), ("type", "text")])
af_body = OrderedDict([("id", "h1"), ("call_id", "t1"), ("name", "read")])
co_body = OrderedDict(
    [
        ("call_id", "call-1"),
        ("is_error", False),
        ("name", "model_set"),
        ("output", OrderedDict([("ok", True)])),
    ]
)
co_raw = '{"call_id":"call-1","output":{"ok":true}}'
sm_body = OrderedDict(
    [("type", "task"), ("data", OrderedDict([("id", "boot")]))]
)

frame_cases = [
    frame_case("plain_no_prefix", "XX", "odd", None, "odd", None, None),
    frame_case(
        "user_content_echo",
        "UX",
        '{"id":"h1","time":"2026-10-14T02:06:07Z","type":"text","text":"hi"}',
        "h1",
        "hi",
        content_text,
        "text",
    ),
    frame_case(
        "user_media_echo",
        "UX",
        '{"id":"2","type":"image","uri":"data:image/png;base64,AA"}',
        "2",
        "data:image/png;base64,AA",
        content_image,
        "image",
    ),
    frame_case(
        "ax_terminator_empty_content",
        "AX",
        '{"id":"h1","type":"text"}',
        "h1",
        "",
        ax_terminator,
        "text",
    ),
    frame_case(
        "json_frame",
        "AF",
        '{"id":"h1","call_id":"t1","name":"read"}',
        "h1",
        '{"id":"h1","call_id":"t1","name":"read"}',
        af_body,
        None,
    ),
    frame_case("co_with_injected_name", "CO", co_raw, None, co_raw, co_body, None),
    frame_case(
        "sm_envelope",
        "SM",
        '{"type":"task","data":{"id":"boot"}}',
        None,
        '{"type":"task","data":{"id":"boot"}}',
        sm_body,
        None,
    ),
]


def delta_case(name, history_id, content, tag, content_type):
    inp = OrderedDict()
    inp["session_id"] = "s1"
    inp["history_id"] = history_id
    inp["content"] = content
    inp["tag"] = tag
    inp["content_type"] = content_type
    expected = (
        '{"session_id":"s1"'
        + ',"history_id":' + q(history_id)
        + ',"content":' + q(content)
        + ',"tag":' + q(tag)
        + ',"content_type":' + q(content_type)
        + "}"
    )
    return {"name": name, "input": inp, "expected": expected}


delta_cases = [
    delta_case("text", "h1", "hello", "Ax", "text"),
    delta_case("reasoning", "h2", "thinking", "Ax", "reasoning"),
]


def status_case(name, connected, message):
    inp = OrderedDict()
    inp["session_id"] = "s1"
    inp["connected"] = connected
    inp["message"] = message
    expected = (
        '{"session_id":"s1"' + ',"connected":' + ("true" if connected else "false") + ',"message":' + q(message) + "}"
    )
    return {"name": name, "input": inp, "expected": expected}


status_cases = [
    status_case("connected", True, "ready"),
    status_case("disconnected", False, "Connection closed"),
]

dump("event_cases.json", {"frame": frame_cases, "delta": delta_cases, "status": status_cases})
