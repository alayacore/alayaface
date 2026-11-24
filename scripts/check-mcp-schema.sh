#!/usr/bin/env bash
# AlayaFace writes mcp.conf as a whole file (App/McpConfig.elm) and AlayaCore
# reads it back, so every key AlayaCore's `ServerConfigFile` declares must be
# modelled: a key without a control is carried through `extras`, which keeps
# the user's value but leaves it uneditable, and a key this client invents is a
# line the core cannot parse.
#
# This is the MCP twin of check-model-schema.sh. The schema lives in exactly
# one place — src-elm/src/App/McpConfig.elm (`modeledKeys`) — and this script
# compares it against the authority:
#
#   * AlayaCore checked out next door (or $ALAYACORE_DIR): read the keys from
#     internal/mcp/types.go and refresh testdata/alayacore-mcp-fields.txt.
#   * otherwise (CI): compare against that fixture.
#
# When it goes red after an AlayaCore change, add the key to `modeledKeys`,
# give it a draft slot, a decode and an encode in McpConfig, and surface it in
# Overlay/McpEditor; McpConfigTest pins the round trip.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="${ALAYACORE_DIR:-$HOME/playground/alayacore}"
MCPCFG="$REPO/src-elm/src/App/McpConfig.elm"
TYPES="$CORE/internal/mcp/types.go"
FIXTURE="$REPO/testdata/alayacore-mcp-fields.txt"

# The keys AlayaCore reads. `ServerConfigFile` is the persisted shape; the
# runtime `ServerConfig` has derived fields (TokenStore, DebugDir) that are not
# config lines.
core_keys() {
  [[ -f "$TYPES" ]] || return 1
  sed -n '/^type ServerConfigFile struct/,/^}/p' "$TYPES" |
    sed -n 's/.*config:"\([a-z-]*\)[",].*/\1/p' |
    sort -u
}

# The keys this client writes. Scoped from `modeledKeys :` to its closing
# bracket, so a comment or another list cannot contribute a key.
face_keys() {
  awk '/^modeledKeys[[:space:]]*:/{f=1} f{print} f&&/^    \]/{exit}' "$MCPCFG" |
    grep -oE '"[a-z-]+"' |
    tr -d '"' |
    sort -u
}

# An extractor that silently returns nothing makes every comparison below pass
# while proving nothing. The minimum is the smallest credible count.
require_min() {
  local label=$1 n=$2 min=$3
  if (( n < min )); then
    echo "✗ MCP schema check broken: $label extractor found $n, expected at least $min — fix the extractor, do not delete the check" >&2
    return 1
  fi
}

[[ -f "$MCPCFG" ]] || {
  echo "check-mcp-schema: missing $MCPCFG" >&2
  exit 1
}

if KEYS=$(core_keys) && [[ -n "$KEYS" ]]; then
  echo "AlayaCore: $CORE"
  mapfile -t EXPECT < <(printf '%s\n' "$KEYS")
  REGEN=1
else
  echo "AlayaCore not found ($TYPES) — checking against $FIXTURE" >&2
  [[ -f "$FIXTURE" ]] || {
    echo "check-mcp-schema: no fixture at $FIXTURE — run this with AlayaCore checked out" >&2
    exit 1
  }
  mapfile -t EXPECT < <(grep -v '^[[:space:]]*#' "$FIXTURE" | grep -v '^[[:space:]]*$' | sort -u)
  REGEN=0
fi

require_min "core key" "${#EXPECT[@]}" 5 || exit 1

mapfile -t FACE < <(face_keys)
require_min "modelled key (this repo)" "${#FACE[@]}" 5 || exit 1

missing=()
for k in "${EXPECT[@]}"; do
  [[ " ${FACE[*]} " == *" $k "* ]] || missing+=("$k")
done
extra=()
for k in "${FACE[@]}"; do
  [[ " ${EXPECT[*]} " == *" $k "* ]] || extra+=("$k")
done

if (( ${#missing[@]} )); then
  echo "AlayaFace does not model: ${missing[*]}" >&2
  echo "  Add each to modeledKeys in $MCPCFG — a draft slot, a decode, an encode," >&2
  echo "  and a control in Overlay/McpEditor. Until then it is carried in extras" >&2
  echo "  (the value survives, but the user cannot edit it)." >&2
fi
if (( ${#extra[@]} )); then
  echo "AlayaFace models keys AlayaCore does not read: ${extra[*]}" >&2
  echo "  Either AlayaCore renamed or removed them, or the fixture is stale." >&2
fi

if (( REGEN )); then
  tmp="$(mktemp)"
  {
    printf '# mcp.conf keys AlayaCore reads, from internal/mcp/types.go\n'
    printf '# (type ServerConfigFile), as of the run of\n'
    printf '# scripts/check-mcp-schema.sh that last touched this file.\n'
    printf '# AlayaCore is a separate repo and is absent in CI, so this is what\n'
    printf '# the schema check compares against there.\n'
    printf '%s\n' "${EXPECT[@]}"
  } >"$tmp"
  if ! cmp -s "$tmp" "$FIXTURE" 2>/dev/null; then
    cp "$tmp" "$FIXTURE"
    echo "updated $FIXTURE"
  fi
  rm -f "$tmp"
fi

(( ${#missing[@]} || ${#extra[@]} )) && exit 1
echo "OK: AlayaFace models all ${#EXPECT[@]} mcp.conf keys"
