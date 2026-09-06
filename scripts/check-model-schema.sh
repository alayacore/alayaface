#!/usr/bin/env bash
# AlayaFace has to know every model.conf field, because :model_sync REPLACES
# the whole list and AlayaCore rewrites model.conf from what comes back: a
# field AlayaFace does not carry is a field it silently DELETES from the
# user's config file. `reasoning_field`, `serial_tool_calls` and
# `reasoning_0/1/2` were each lost that way.
#
# The schema lives in exactly one place — src-elm/src/Session/ModelConfig.elm,
# which drives the decoder, the :model_sync payload and the editor form. This
# script checks that one place against the authority: AlayaCore's
# protocol.ModelInfo, the :model_list payload.
#
#   ./scripts/check-model-schema.sh
#
# AlayaCore is a SEPARATE repo, absent in CI. There the checked-in fixture
# testdata/alayacore-model-fields.txt is used instead, so this script works
# both as the tool that regenerates the fixture (locally) and as a CI gate.
# Workflow after AlayaCore changes a model field:
#   1. run this script with AlayaCore checked out next door — it reports the
#      gap and updates the fixture;
#   2. add the field to ModelConfig.elm (control + decode + encode);
#   3. cd src-elm && elm-test;  4. run this script again: OK.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE="$REPO/testdata/alayacore-model-fields.txt"
MODELCFG="$REPO/src-elm/src/Session/ModelConfig.elm"
CORE="${ALAYACORE_DIR:-$HOME/playground/alayacore}"
PROTOCOL="$CORE/internal/protocol/protocol.go"

# AlayaFace's keys. `fields` builds entries with the field/choice helpers;
# `id` is carried by the codec but is not editable (AlayaCore assigns it at
# runtime, config:"-"), so it is added here rather than listed twice.
face_keys() {
  {
    printf 'id\n'
    sed -n 's/^[[:space:]]*[\[,]*[[:space:]]*\(field\|choice\)[[:space:]]*"\([a-z_0-9]*\)".*/\2/p' "$MODELCFG"
  } | sort -u
}

# AlayaCore's keys, from the struct tags.
core_keys() {
  sed -n '/^type ModelInfo struct/,/^}/p' "$PROTOCOL" |
    sed -n 's/.*json:"\([a-z_0-9]*\)[",].*/\1/p' |
    sort -u
}

[[ -f "$MODELCFG" ]] || { echo "check-model-schema: missing $MODELCFG" >&2; exit 1; }

if [[ -f "$PROTOCOL" ]]; then
  echo "AlayaCore: $CORE"
  mapfile -t EXPECT < <(core_keys)
  REGEN=1
else
  echo "AlayaCore not found ($PROTOCOL) — checking against $FIXTURE" >&2
  [[ -f "$FIXTURE" ]] || { echo "check-model-schema: no fixture to check against" >&2; exit 1; }
  mapfile -t EXPECT < <(grep -v '^[[:space:]]*#' "$FIXTURE" | grep -v '^[[:space:]]*$' | sort -u)
  REGEN=0
fi

mapfile -t FACE < <(face_keys)

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
  echo "  Add each to fields in $MODELCFG — a control, a decode, an encode." >&2
  echo "  Anything unmodelled is dropped from the user's model.conf on save." >&2
fi
if (( ${#extra[@]} )); then
  echo "AlayaFace models keys AlayaCore does not send: ${extra[*]}" >&2
  echo "  Either AlayaCore renamed or removed them, or the fixture is stale." >&2
fi

if (( REGEN )); then
  tmp="$(mktemp)"
  {
    printf '# model.conf / :model_list field names, from AlayaCore\n'
    printf '# internal/protocol/protocol.go (type ModelInfo), as of the run of\n'
    printf '# scripts/check-model-schema.sh that last touched this file.\n'
    printf '# AlayaCore is a separate repo and is absent in CI, so this is what\n'
    printf '# the schema check compares against there.\n'
    printf '%s\n' "${EXPECT[@]}"
  } >"$tmp"
  if ! cmp -s "$tmp" "$FIXTURE" 2>/dev/null; then
    if [[ -f "$FIXTURE" ]]; then
      cp "$tmp" "$FIXTURE"
      echo "updated $FIXTURE"
    else
      cp "$tmp" "$FIXTURE"
      echo "wrote $FIXTURE"
    fi
  fi
  rm -f "$tmp"
fi

(( ${#missing[@]} || ${#extra[@]} )) && exit 1
echo "OK: AlayaFace models all ${#EXPECT[@]} model.conf fields"
