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
FIXREQ="$REPO/testdata/alayacore-model-required.txt"
MODELCFG="$REPO/src-elm/src/Session/ModelConfig.elm"
CORE="${ALAYACORE_DIR:-$HOME/playground/alayacore}"
PROTOCOL="$CORE/internal/protocol/protocol.go"
AGENT_DIR="$CORE/internal/agent"

# AlayaFace's keys. `fields` builds entries with the field/choice helpers;
# `id` is carried by the codec but is not editable (AlayaCore assigns it at
# runtime, config:"-"), so it is added here rather than listed twice.
# The `fields` list, and nothing else: scoped from `fields =` to the next
# top-level declaration, so a codec line elsewhere in the module can never be
# mistaken for a field entry (and a helper rename cannot silently hide a key —
# the extraction matches ANY helper whose first argument is a quoted key).
fields_block() {
  awk '/^fields[[:space:]]*=/{f=1;next} f&&/^[^ \t]/{exit} f' "$MODELCFG"
}

# AlayaFace's keys. `id` is carried by the codec but is not editable (AlayaCore
# assigns it at runtime, config:"-"), so it is added here rather than listed
# twice in the table.
face_keys() {
  {
    printf 'id\n'
    fields_block | sed -n 's/^[[:space:]]*[[,]*[[:space:]]*[A-Za-z]*[[:space:]]*"\([a-z_0-9]*\)".*/\1/p'
  } | grep -v '^$' | sort -u
}

# AlayaFace's REQUIRED keys, by naming convention: a helper whose name begins
# with `required` is the client saying "AlayaCore refuses an entry without this"
# (`requiredField`, `requiredChoice`). Documented in ModelConfig.elm, where
# `choice` deliberately does NOT mean required.
face_required() {
  fields_block | sed -n 's/^[[:space:]]*[[,]*[[:space:]]*required[A-Za-z]*[[:space:]]*"\([a-z_0-9]*\)".*/\1/p' |
    grep -v '^$' | sort -u
}

# AlayaCore's keys, from the struct tags.
core_keys() {
  sed -n '/^type ModelInfo struct/,/^}/p' "$PROTOCOL" |
    sed -n 's/.*json:"\([a-z_0-9]*\)[",].*/\1/p' |
    sort -u
}

# Which keys AlayaCore refuses an entry for. Read from `validateModel`'s
# `if m.X == ""` tests and mapped back to json keys through the `modelConfig`
# struct tags, because the Go field is `BaseURL` and the config line is
# `base_url`.
#
# Why this half exists: a required field left blank does not fail a save
# harmlessly. `syncFromContent` skips entries that fail `validateModel` and
# `writeConfigFile` then persists the survivors, so the entry is DELETED from
# the user's model.conf, and the MODEL_VALIDATION reply only arrives afterwards
# to explain what already happened. If AlayaCore ever requires a fourth key and
# `fields` does not mark it, this check is what says so.
core_required() {
  local src="$AGENT_DIR/model_manager.go"
  local cfg
  # The struct lives in its own file, and naming the file is a second thing to
  # go stale — locate it by what it declares.
  cfg=$(grep -rl 'type modelConfig struct' "$AGENT_DIR" 2>/dev/null | head -1)
  [[ -f "$src" && -n "$cfg" ]] || return 1
  local tags
  tags=$(awk '/^type modelConfig struct/,/^}/' "$cfg")
  awk '/^func validateModel/,/^}/' "$src" |
    sed -n 's/.*if m\.\([A-Za-z0-9]*\) == "".*/\1/p' |
    while read -r gofield; do
      printf '%s\n' "$tags" |
        sed -n "s/^[[:space:]]*${gofield}[[:space:]]\+[A-Za-z0-9]*[[:space:]]\+.*json:\"\([a-z_0-9]*\)\".*/\1/p"
    done | sort -u
}

[[ -f "$MODELCFG" ]] || { echo "check-model-schema: missing $MODELCFG" >&2; exit 1; }

if [[ -f "$PROTOCOL" ]]; then
  echo "AlayaCore: $CORE"
  mapfile -t EXPECT < <(core_keys)
  mapfile -t EXPECT_REQ < <(core_required)
  REGEN=1
else
  echo "AlayaCore not found ($PROTOCOL) — checking against $FIXTURE" >&2
  [[ -f "$FIXTURE" ]] || { echo "check-model-schema: no fixture to check against" >&2; exit 1; }
  [[ -f "$FIXREQ" ]] || { echo "check-model-schema: no required-keys fixture ($FIXREQ)" >&2; exit 1; }
  mapfile -t EXPECT < <(grep -v '^[[:space:]]*#' "$FIXTURE" | grep -v '^[[:space:]]*$' | sort -u)
  mapfile -t EXPECT_REQ < <(grep -v '^[[:space:]]*#' "$FIXREQ" | grep -v '^[[:space:]]*$' | sort -u)
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

# --- required keys: the same comparison, second axis ------------------------
mapfile -t FACE_REQ < <(face_required)
req_missing=()
for k in "${EXPECT_REQ[@]}"; do
  [[ " ${FACE_REQ[*]} " == *" $k "* ]] || req_missing+=("$k")
done
req_extra=()
for k in "${FACE_REQ[@]}"; do
  [[ " ${EXPECT_REQ[*]} " == *" $k "* ]] || req_extra+=("$k")
done

if (( ${#req_missing[@]} )); then
  echo "AlayaCore requires these keys but AlayaFace does not refuse an empty one: ${req_missing[*]}" >&2
  echo "  Mark each as requiredField/requiredChoice in $MODELCFG — saving without one deletes the entry." >&2
fi
if (( ${#req_extra[@]} )); then
  echo "AlayaFace refuses an empty value for keys AlayaCore does not require: ${req_extra[*]}" >&2
  echo "  This blocks a save the core would accept, and can strand an entry the user only wants to edit. Mirror validateModel, do not outdo it." >&2
fi

if (( REGEN )); then
  tmp_req="$(mktemp)"
  {
    printf '# Which model.conf keys AlayaCore requires, from validateModel()\n'
    printf '# (internal/agent/model_manager.go), mapped to json keys through the\n'
    printf '# modelConfig struct tags. An entry missing one of these is SKIPPED\n'
    printf '# by syncFromContent and then deleted from model.conf by\n'
    printf '# writeConfigFile, so a client that lets it through destroys it.\n'
    printf '%s\n' "${EXPECT_REQ[@]}"
  } >"$tmp_req"
  if ! cmp -s "$tmp_req" "$FIXREQ" 2>/dev/null; then
    cp "$tmp_req" "$FIXREQ"
    echo "updated $FIXREQ"
  fi
  rm -f "$tmp_req"
fi

if (( ${#req_missing[@]} || ${#req_extra[@]} )); then
  exit 1
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
echo "OK: AlayaFace models all ${#EXPECT[@]} model.conf fields and refuses an empty value for exactly the ${#EXPECT_REQ[@]} AlayaCore requires"
