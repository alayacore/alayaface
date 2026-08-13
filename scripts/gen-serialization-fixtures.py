#!/usr/bin/env python3
"""Generate shared serialization truth-table fixtures for M1.

The fixture files under testdata/serialization/ are the single source of
truth for the Rust/Go/Elm wire contract: same logical input -> identical
JSON output on BOTH backends (see REFACTOR.md M1 / D3).

Expected strings are constructed from the DOCUMENTED wire format (not
from either backend's implementation) so the fixture can catch drift on
either side.

Usage: python3 scripts/gen-serialization-fixtures.py
"""
import json
import os

OUT = os.path.join(os.path.dirname(__file__), "..", "testdata", "serialization")
os.makedirs(OUT, exist_ok=True)


def dump(name, data):
    path = os.path.join(OUT, name)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=True)
        f.write("\n")
    print(f"wrote {path}")


# ─── Event payloads (FrameEvent / DeltaEvent / StatusEvent) ─────────
# Field order (both backends): FrameEvent = session_id, tag, raw_value,
# history_id, content, json, user_content_type; DeltaEvent = session_id,
# history_id, content, tag; StatusEvent = session_id, connected, message.
# NUL-separated history prefixes appear as \u0000 in the wire JSON
# (both Go encoding/json and serde_json escape control chars the same).
#
# The `json` payload object is stored in CANONICAL (key-sorted) form:
# JSON object key order is not part of the wire contract (RFC 8259), and
# the two backends legitimately differ — Go forwards RawMessage verbatim
# (frame order), Rust re-serializes serde_json::Value (BTreeMap sorted).
# The fixture pins the canonical form so both produce identical bytes.

frame_cases = [
    {
        "name": "plain_no_prefix",
        "input": {
            "session_id": "s1", "tag": "XX", "raw_value": "odd",
            "history_id": None, "content": "odd", "json": None,
            "user_content_type": None,
        },
        "expected": r'{"session_id":"s1","tag":"XX","raw_value":"odd","history_id":null,"content":"odd","json":null,"user_content_type":null}',
    },
    {
        "name": "user_echo_with_history",
        "input": {
            "session_id": "s1", "tag": "UT", "raw_value": "\x00h1\x00hi",
            "history_id": "h1", "content": "hi", "json": None,
            "user_content_type": "UT",
        },
        "expected": r'{"session_id":"s1","tag":"UT","raw_value":"\u0000h1\u0000hi","history_id":"h1","content":"hi","json":null,"user_content_type":"UT"}',
    },
    {
        "name": "at_terminator_empty_content",
        "input": {
            "session_id": "s1", "tag": "AT", "raw_value": "\x00h1\x00",
            "history_id": "h1", "content": None, "json": None,
            "user_content_type": None,
        },
        "expected": r'{"session_id":"s1","tag":"AT","raw_value":"\u0000h1\u0000","history_id":"h1","content":null,"json":null,"user_content_type":null}',
    },
    {
        "name": "json_frame",
        "input": {
            "session_id": "s1", "tag": "AF",
            "raw_value": '\x00h1\x00{"id":"t1","name":"read"}',
            "history_id": "h1", "content": '{"id":"t1","name":"read"}',
            "json": '{"id":"t1","name":"read"}', "user_content_type": None,
        },
        "expected": r'{"session_id":"s1","tag":"AF","raw_value":"\u0000h1\u0000{\"id\":\"t1\",\"name\":\"read\"}","history_id":"h1","content":"{\"id\":\"t1\",\"name\":\"read\"}","json":{"id":"t1","name":"read"},"user_content_type":null}',
    },
    {
        "name": "co_with_injected_name",
        "input": {
            "session_id": "s1", "tag": "CO",
            "raw_value": '{"id":"call-1","output":{"ok":true},"is_error":false}',
            "history_id": None,
            "content": '{"id":"call-1","output":{"ok":true},"is_error":false}',
            # Canonical (key-sorted) form — see header comment.
            "json": '{"id":"call-1","is_error":false,"name":"model_set","output":{"ok":true}}',
            "user_content_type": None,
        },
        "expected": r'{"session_id":"s1","tag":"CO","raw_value":"{\"id\":\"call-1\",\"output\":{\"ok\":true},\"is_error\":false}","history_id":null,"content":"{\"id\":\"call-1\",\"output\":{\"ok\":true},\"is_error\":false}","json":{"id":"call-1","is_error":false,"name":"model_set","output":{"ok":true}},"user_content_type":null}',
    },
    {
        "name": "sm_envelope",
        "input": {
            "session_id": "s1", "tag": "SM",
            "raw_value": '{"type":"task","data":{"id":"boot"}}',
            "history_id": None,
            "content": '{"type":"task","data":{"id":"boot"}}',
            # Canonical (key-sorted) form — see header comment.
            "json": '{"data":{"id":"boot"},"type":"task"}',
            "user_content_type": None,
        },
        "expected": r'{"session_id":"s1","tag":"SM","raw_value":"{\"type\":\"task\",\"data\":{\"id\":\"boot\"}}","history_id":null,"content":"{\"type\":\"task\",\"data\":{\"id\":\"boot\"}}","json":{"data":{"id":"boot"},"type":"task"},"user_content_type":null}',
    },
]

delta_cases = [
    {
        "name": "normal",
        "input": {"session_id": "s1", "history_id": "h1", "content": "hello", "tag": "At"},
        "expected": r'{"session_id":"s1","history_id":"h1","content":"hello","tag":"At"}',
    },
]

status_cases = [
    {
        "name": "connected",
        "input": {"session_id": "s1", "connected": True, "message": "ready"},
        "expected": r'{"session_id":"s1","connected":true,"message":"ready"}',
    },
    {
        "name": "disconnected",
        "input": {"session_id": "s1", "connected": False, "message": "Connection closed"},
        "expected": r'{"session_id":"s1","connected":false,"message":"Connection closed"}',
    },
]

dump("event_cases.json", {"frame": frame_cases, "delta": delta_cases, "status": status_cases})


# ─── session.spawn.json (SpawnArgs) ─────────────────────────────────
# Field order (both): tool_confirm, builtin_tools, system_prompt, work_dir,
# preset.
# builtin_tools: None -> null, Some("") -> "", Some("a,b") -> "a,b".
# File is written with 2-space indent (Go MarshalIndent / serde_json
# to_string_pretty produce the same layout).

def pretty(d):
    return json.dumps(d, indent=2, ensure_ascii=True)

spawn_cases = [
    {
        "name": "no_tools",
        "input": {"tool_confirm": "allow", "builtin_tools": "", "system_prompt": "planner-hint", "work_dir": "/tmp/plan-work", "preset": "Complex"},
        "expected": pretty({"tool_confirm": "allow", "builtin_tools": "", "system_prompt": "planner-hint", "work_dir": "/tmp/plan-work", "preset": "Complex"}),
    },
    {
        "name": "selected_tools",
        "input": {"tool_confirm": "", "builtin_tools": "a,b", "system_prompt": "", "work_dir": "", "preset": "Simple"},
        "expected": pretty({"tool_confirm": "", "builtin_tools": "a,b", "system_prompt": "", "work_dir": "", "preset": "Simple"}),
    },
    {
        "name": "unset_tools",
        "input": {"tool_confirm": "", "builtin_tools": None, "system_prompt": "", "work_dir": "", "preset": ""},
        "expected": pretty({"tool_confirm": "", "builtin_tools": None, "system_prompt": "", "work_dir": "", "preset": ""}),
    },
]
dump("spawn_cases.json", {"cases": spawn_cases})


# ─── settings.conf (GlobalSettings) ─────────────────────────────────
# Field order (both): tool_confirm, builtin_tools, system_prompt. Written
# with 2-space indent; empty strings are kept (no omitempty / no skip).

settings_cases = [
    {
        "name": "normalized",
        "input": {"tool_confirm": " execute_command , search_files ,", "builtin_tools": "read_file,write_file", "system_prompt": "planner-hint"},
        "normalized": {"tool_confirm": "execute_command,search_files", "builtin_tools": "read_file,write_file", "system_prompt": "planner-hint"},
        "expected_file": pretty({"tool_confirm": "execute_command,search_files", "builtin_tools": "read_file,write_file", "system_prompt": "planner-hint"}),
    },
    {
        "name": "empty",
        "input": {"tool_confirm": "", "builtin_tools": "", "system_prompt": ""},
        "normalized": {"tool_confirm": "", "builtin_tools": "", "system_prompt": ""},
        "expected_file": pretty({"tool_confirm": "", "builtin_tools": "", "system_prompt": ""}),
    },
]
dump("settings_cases.json", {"cases": settings_cases})


# ─── global.conf (GlobalConfig) ─────────────────────────────────────

global_cases = [
    {
        "name": "default",
        "input": {"recursion_limit": 0},
        "normalized": {"recursion_limit": 8},
        "expected_file": pretty({"recursion_limit": 8}),
    },
    {
        "name": "custom",
        "input": {"recursion_limit": 12},
        "normalized": {"recursion_limit": 12},
        "expected_file": pretty({"recursion_limit": 12}),
    },
]
dump("global_cases.json", {"cases": global_cases})


# ─── mcp.conf (parse + write) ───────────────────────────────────────
# parse: blocks split by `---`; comments/blank skipped; only blocks with
# a `server` key are kept; `type` is inferred (url -> http, else stdio);
# args/env are normalized to compact raw JSON text strings. The parsed
# model is serialized with sorted object keys (Go map marshal and serde
# BTreeMap both sort alphabetically).
# write: ordered field list server, url, command, args, env, auth-type,
# auth-token, auth-client-id, auth-client-secret, proto-version; string
# values JSON-quoted (args/env raw), empty strings skipped except server.

mcp_parse_cases = [
    {
        "name": "http_and_stdio",
        "input_text": (
            "server: exaWebSearch\n"
            "url: https://mcp.exa.ai/mcp\n"
            "proto-version: 2025-11-25\n"
            "---\n"
            "server: embedded\n"
            'command: "embedded-debugger-mcp"\n'
            'args: ["--allow-flash-erase", "serve"]\n'
            'env: {"RUST_LOG": "info"}\n'
        ),
        "expected_parsed": json.dumps(
            [
                {"proto_version": "2025-11-25", "server": "exaWebSearch", "type": "http", "url": "https://mcp.exa.ai/mcp"},
                {"args": '["--allow-flash-erase","serve"]', "command": "embedded-debugger-mcp", "env": '{"RUST_LOG":"info"}', "server": "embedded", "type": "stdio"},
            ],
            separators=(",", ":"),
            ensure_ascii=True,
        ),
    },
]

mcp_write_cases = [
    {
        "name": "ordered_fields",
        "input_servers": json.dumps(
            [
                {"server": "exaWebSearch", "url": "https://mcp.exa.ai/mcp", "proto_version": "2025-11-25"},
                {"server": "embedded", "command": "embedded-debugger-mcp", "args": '["--allow-flash-erase","serve"]', "env": '{"RUST_LOG":"info"}'},
            ],
            separators=(",", ":"),
            ensure_ascii=True,
        ),
        "expected_text": (
            'server: "exaWebSearch"\n'
            'url: "https://mcp.exa.ai/mcp"\n'
            'proto-version: "2025-11-25"\n'
            "---\n"
            'server: "embedded"\n'
            'command: "embedded-debugger-mcp"\n'
            'args: ["--allow-flash-erase","serve"]\n'
            'env: {"RUST_LOG":"info"}\n'
        ),
    },
]
dump("mcp_cases.json", {"parse_cases": mcp_parse_cases, "write_cases": mcp_write_cases})
