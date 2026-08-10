#!/usr/bin/env bash
# Backend command-parity check.
#
# The Elm client runs against TWO backends: the Tauri (Rust) commands and
# the Go HTTP RPC registry. They are hand-mirrored, and drift is silent —
# a command implemented on one side only breaks exactly that deployment
# (see the R-series: the Rust close path diverged from Go's lock/parallel
# semantics). This script fails CI when the command sets diverge.
#
# Also checks the command names transport.js actually invokes: every invoke
# must exist on both backends (a bridge-only name is a dead end).
set -euo pipefail
cd "$(dirname "$0")/.."

# Rust: commands::<name> entries in the invoke_handler list (lib.rs).
rust_cmds=$(grep -oE 'commands::[a-z_]+' src-tauri/src/lib.rs \
  | sed 's/commands:://' | sort -u)

# Go: "<name>": Handler entries in the RPC registry (handlers.go).
# Handler names start uppercase, so `"error": err...` keys are excluded.
go_cmds=$(grep -oE '"[a-z_]+"[[:space:]]*:[[:space:]]*[A-Z][A-Za-z]+' src-go/internal/server/handlers/handlers.go \
  | sed -E 's/^"([a-z_]+)".*/\1/' | sort -u)

# transport.js: command names invoked via transport.invoke.
bridge_cmds=$(grep -oE 'invoke\("[a-z_]+"' src-elm/transport.js \
  | sed -E 's/invoke\("([a-z_]+)"/\1/' | sort -u)

fail=0

missing_in_go=$(comm -23 <(echo "$rust_cmds") <(echo "$go_cmds"))
missing_in_rust=$(comm -13 <(echo "$rust_cmds") <(echo "$go_cmds"))
if [ -n "$missing_in_go" ] || [ -n "$missing_in_rust" ]; then
  echo "✗ backend command parity mismatch (Rust vs Go):"
  [ -n "$missing_in_go" ] && echo "    in Rust but NOT in Go: $missing_in_go"
  [ -n "$missing_in_rust" ] && echo "    in Go but NOT in Rust: $missing_in_rust"
  fail=1
fi

# bridge.js may invoke a subset (not every backend command has a UI
# entry point), so only check one direction: bridge ⊆ backends.
missing_in_backends=$(comm -23 <(echo "$bridge_cmds") <(cat <(echo "$rust_cmds") <(echo "$go_cmds") | sort -u))
if [ -n "$missing_in_backends" ]; then
  echo "✗ transport.js invokes commands missing from BOTH backends: $missing_in_backends"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "✓ backend command parity OK (Rust: $(echo "$rust_cmds" | wc -l), Go: $(echo "$go_cmds" | wc -l), bridge: $(echo "$bridge_cmds" | wc -l))"
