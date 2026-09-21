#!/usr/bin/env bash
# Four facts about AlayaCore's TLV protocol are duplicated inside AlayaFace, and
# every one of them goes stale silently when the core moves:
#
#   1. message_version   — the number this adapter pins and the core announces.
#                          Nothing in CI compares them: the probe needs a
#                          binary, and AlayaCore is a separate repo, absent
#                          here. When v12 landed the pin sat at 11 and the only
#                          symptom was a home-screen banner telling users to
#                          DOWNGRADE their core while sessions kept running.
#   2. the tag alphabet  — a tag the adapter does not know is a frame it handles
#                          by accident (CE, v12's input end).
#   3. the broadcast
#       session states   — a state the adapter does not read is a lifecycle
#                          event thrown away (SM session/closed, v12, which is
#                          precisely what a client should wait for instead of
#                          inferring the end from EOF on stdout).
#   4. the command
#                       vocabulary — a command we send that the core renamed
#                       comes back as an UNKNOWN_COMMAND CO at best.
#
# This is the protocol-side twin of check-model-schema.sh, with the same two
# modes:
#
#   ./scripts/check-alayacore-protocol.sh
#
#   * AlayaCore checked out next door (or $ALAYACORE_DIR): read the four facts
#     from the authority, compare, and REFRESH the fixtures under testdata/.
#   * otherwise (CI): compare against those fixtures — what the last such run
#     left behind.
#
# When it goes red after an AlayaCore change, the fix is the four things the
# list above names: bump both message_version constants, add the tag to both tlv
# modules, decide where the new state is read (or record why not), and mirror
# the command name.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="${ALAYACORE_DIR:-$HOME/playground/alayacore}"
FIXDIR="$REPO/testdata"
FIX_VERSION="$FIXDIR/alayacore-message-version.txt"
FIX_TAGS="$FIXDIR/alayacore-tlv-tags.txt"
FIX_STATES="$FIXDIR/alayacore-session-states.txt"
FIX_COMMANDS="$FIXDIR/alayacore-commands.txt"

R_CORE="$REPO/src-tauri/src/alayacore.rs"
G_CORE="$REPO/src-go/internal/core/core.go"
R_TLV="$REPO/src-tauri/src/tlv.rs"
G_TLV="$REPO/src-go/internal/tlv/tlv.go"
C_TLV="$CORE/internal/tlv/tlv.go"
C_STATE="$CORE/internal/agent/session_types.go"
C_SESSION="$CORE/internal/agent/session.go"
C_COMMANDS="$CORE/internal/commands/commands.go"

fail=0

# An extractor that silently returns nothing makes every comparison below pass
# while proving nothing — the lesson scripts/check-backend-parity.sh already
# applies to its own greps. The minimum is the smallest credible count for that
# fact, so a rename that breaks the grep is reported as a broken check rather
# than as agreement.
require_min() {
  local label=$1 n=$2 min=$3
  if (( n < min )); then
    echo "✗ protocol check broken: $label extractor found $n, expected at least $min — fix the extractor, do not delete the check"
    fail=1
    return 1
  fi
}

# ─── The core's side (the authority) ────────────────────────────────

core_version() {
  [[ -f "$C_STATE" ]] || return 1
  grep -vE '^[[:space:]]*//' "$C_STATE" |
    sed -nE 's/^const messageVersion[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' | head -1
}

# Every two-letter tag the core declares, in either direction.
core_tags() {
  [[ -f "$C_TLV" ]] || return 1
  grep -oE 'Tag[A-Za-z]+ += +"[A-Za-z]{2}"' "$C_TLV" |
    sed -E 's/.*"([A-Za-z]{2})"/\1/' | sort -u
}

# Only the lifecycle states the core BROADCASTS, which is not the whole
# SessionState vocabulary: `setState` is the single writer of a `session` SM
# frame and its guard names the phases that reach an adapter. `starting` and
# `initializing` exist but never do, so requiring this repo to read them would
# be requiring it to handle nothing. If that guard grows a phase, so does this
# list — and the comparison says so.
core_states() {
  [[ -f "$C_SESSION" && -f "$C_STATE" ]] || return 1
  local phases
  # grep -o, not one sed substitution per line: `if phase == A || phase == B`
  # names TWO phases and a greedy `s/.*phase == /\1/` keeps only the last.
  phases=$(grep -oE 'phase == (Session[A-Za-z]+)' "$C_SESSION" | sed -E 's/.*phase == //' | sort -u)
  [[ -n "$phases" ]] || return 1
  # Map each constant through SessionState.String()'s switch to the wire string.
  local body const name
  body=$(sed -n '/^func (s SessionState) String/,/^}/p' "$C_STATE")
  while read -r const; do
    [[ -n "$const" ]] || continue
    name=$(printf '%s\n' "$body" |
      awk -v want="$const" '
        $1 == "case" { sub(/:$/, "", $2); hit = ($2 == want) }
        hit && $1 == "return" { gsub(/"/, "", $2); print $2; exit }
      ')
    [[ -n "$name" ]] && printf '%s\n' "$name"
  done <<< "$phases" | sort -u
}

# The names the registry answers: the canonical constants plus the aliases, since
# the core resolves aliases before dispatch (a client may send either word).
core_commands() {
  [[ -f "$C_COMMANDS" ]] || return 1
  {
    grep -oE 'CommandName[A-Za-z]+ += +"[a-z_]+"' "$C_COMMANDS" |
      sed -E 's/.*"([a-z_]+)"/\1/'
    # The alias table's KEYS are the words a client may send ("q"), so they
    # belong in the accepted set: the core resolves aliases before dispatch.
    sed -n '/^var commandAliases/,/^}/p' "$C_COMMANDS" |
      sed -nE 's/^[[:space:]]*"([a-z_]+)":.*/\1/p'
  } | grep -v '^$' | sort -u
}

# ─── Our side ───────────────────────────────────────────────────────

face_version() { grep -vE '^[[:space:]]*//' "$1" | sed -nE "s/.*$2[^=]*=[[:space:]]*([0-9]+).*/\1/p" | head -1; }
face_tags() { grep -oE 'TAG_[A-Z_]+: &str = "[A-Za-z]{2}"' "$R_TLV" | sed -E 's/.*"([A-Za-z]{2})"/\1/' | sort -u; }
go_tags() { grep -oE 'Tag[A-Za-z]+ += +"[A-Za-z]{2}"' "$G_TLV" | sed -E 's/.*"([A-Za-z]{2})"/\1/' | sort -u; }

# Production source, with the test code removed. Rust's tests live in the same
# file (below `#[cfg(test)]`), and they quote things production never does — a
# test session id of "s1" would otherwise read as a command name here. Go's
# tests are separate files, and fakecore is excluded because it IMPLEMENTS the
# vocabulary rather than choosing it.
face_source() {
  local f
  for f in $(find "$REPO/src-tauri/src" -name '*.rs' | sort); do
    awk '/^#\[cfg\(test\)\]/{ exit } { print }' "$f"
  done
  for f in $(find "$REPO/src-go/internal" -name '*.go' ! -name '*_test.go' ! -path '*/fakecore/*' | sort); do
    cat "$f"
  done
}

# The command names this repo SENDS.
#
# Extraction is anchored on the send sites, so prose and comments cannot add a
# command to the list:
#
#   1. any line that calls the Rust `send_cmd`/`send_cmd!` or Go's
#      SendCmd/sendCmdLocked — every snake_case word it quotes;
#   2. a CmdMsg built by hand rather than through those helpers (close_session's
#      cancel and save, the model probe's sync), anchored at the start of the
#      line so a `rename` struct tag cannot join in.
#
# A site that picks the name with a runtime conditional is invisible to a
# line-shaped check: `send_cmd(..., name, ...)` quotes nothing. Those two are
# named below, and they are still validated against the core's registry every
# run — this list says WHICH names to look for, not that they are allowed. Add a
# conditional command name to the code and forgetting it here means the check
# stops covering that one name; the comment cites the sites so a reader can see
# the coupling.
face_commands() {
  local src; src=$(face_source)
  {
    printf '%s\n' "$src" |
      grep -E 'send_cmd|SendCmd\(|sendCmdLocked\(' |
      grep -oE '"[a-z_][a-z_]+"' | tr -d '"'
    printf '%s\n' "$src" |
      sed -nE 's/^[[:space:]]*[Nn]ame: *"([a-z_][a-z_]+)".*/\1/p'
    # commands/cmd.rs::alayacore_confirm and handlers/cmd.go::ConfirmTool.
    printf '%s\n' tool_confirm tool_decline
  } | sort -u
}

# Where a session lifecycle state is ACTUALLY read: the two readers (they end a
# session on the terminal frame) and the two client predicates (readiness).
# Comments are stripped, because a state named in prose is a state nobody acts
# on — which is precisely the difference between "we handled v12" and "we read
# about v12", and what made an earlier version of this check green while the
# terminal frame was still being dropped.
LIFECYCLE_FILES=(
  "$REPO/src-tauri/src/reader.rs"
  "$REPO/src-go/internal/session/reader.go"
  "$REPO/src-elm/src/Session/Handlers.elm"
  "$REPO/src-elm/src/Plan/Update.elm"
)

face_states() {
  local f re
  # The states to look for come in as arguments — the core's list, not a copy
  # of it kept here. A state AlayaCore adds is then found, or missed, without
  # an edit to this script: that is the difference between a check and a
  # snapshot of what we knew when it was written.
  re='"('"$(printf '%s|' "$@" | sed 's/|$//')"')"'
  {
    for f in "${LIFECYCLE_FILES[@]}"; do
      case "$f" in
        # Rust's tests live in the same file; a state named only in a test
        # table is not a state the reader acts on.
        *.rs) awk '/^#\[cfg\(test\)\]/{ exit } { print }' "$f" ;;
        *)    cat "$f" ;;
      esac
    done
  } | grep -v -E '^[[:space:]]*(//|\*|--|/\*)' |
      grep -oE "$re" |
      tr -d '"' | sort -u
}

# ─── Resolve what is expected: the core if present, else the fixtures ──

if EXPECT_VERSION=$(core_version 2>/dev/null) && [[ -n "${EXPECT_VERSION:-}" ]]; then
  echo "AlayaCore: $CORE"
  REGEN=1
  mapfile -t EXPECT_TAGS < <(core_tags)
  mapfile -t EXPECT_STATES < <(core_states)
  mapfile -t EXPECT_COMMANDS < <(core_commands)
else
  echo "AlayaCore not found ($C_TLV) — checking against the fixtures in $FIXDIR" >&2
  for f in "$FIX_VERSION" "$FIX_TAGS" "$FIX_STATES" "$FIX_COMMANDS"; do
    [[ -f "$f" ]] || { echo "✗ no fixture at $f — run this script with AlayaCore checked out" >&2; exit 1; }
  done
  REGEN=0
  EXPECT_VERSION=$(grep -v '^[[:space:]]*#' "$FIX_VERSION" | grep -v '^[[:space:]]*$' | head -1)
  mapfile -t EXPECT_TAGS < <(grep -v '^[[:space:]]*#' "$FIX_TAGS" | grep -v '^[[:space:]]*$')
  mapfile -t EXPECT_STATES < <(grep -v '^[[:space:]]*#' "$FIX_STATES" | grep -v '^[[:space:]]*$')
  mapfile -t EXPECT_COMMANDS < <(grep -v '^[[:space:]]*#' "$FIX_COMMANDS" | grep -v '^[[:space:]]*$')
fi

[[ -n "$EXPECT_VERSION" ]] || { echo "✗ no message_version found in $C_STATE" >&2; exit 1; }
require_min "TLV tag" "${#EXPECT_TAGS[@]}" 10 || exit 1
require_min "broadcast session state" "${#EXPECT_STATES[@]}" 2 || exit 1
require_min "registered command" "${#EXPECT_COMMANDS[@]}" 10 || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# 1. message_version, against both backends. check-backend-parity.sh already
#    asserts Rust == Go; this is the half it cannot see.
for side in "Rust|$R_CORE|SUPPORTED_MESSAGE_VERSION" "Go|$G_CORE|SupportedMessageVersion"; do
  IFS='|' read -r label file const <<< "$side"
  got=$(face_version "$file" "$const")
  if [[ "$got" != "$EXPECT_VERSION" ]]; then
    echo "✗ $label pins $const = ${got:-<missing>}; AlayaCore announces message_version $EXPECT_VERSION"
    echo "  Update $file — and read what the bump describes before doing it:"
    echo "  a new tag (checked in section 2), a new broadcast state (section 3),"
    echo "  a new command (section 4). All three are this repo's job too."
    fail=1
  fi
done

# 2. the tag alphabet, both backends.
face_tags > "$tmp/tags_rust"
go_tags > "$tmp/tags_go"
printf '%s\n' "${EXPECT_TAGS[@]}" > "$tmp/tags_core"
require_min "TLV tag (Rust)" "$(wc -l < "$tmp/tags_rust")" 10 || fail=1
require_min "TLV tag (Go)" "$(wc -l < "$tmp/tags_go")" 10 || fail=1
for pair in "Rust|$tmp/tags_rust" "Go|$tmp/tags_go"; do
  IFS='|' read -r label file <<< "$pair"
  if ! diff -q "$tmp/tags_core" "$file" >/dev/null; then
    echo "✗ $label TLV tag alphabet differs from AlayaCore's"
    echo "  the core defines, $label does not: $(comm -23 "$tmp/tags_core" "$file" | tr '\n' ' ')"
    echo "  $label defines, the core does not: $(comm -13 "$tmp/tags_core" "$file" | tr '\n' ' ')"
    echo "  A tag nobody knows is a frame that gets forwarded to a client which"
    echo "  parses it as nothing. Add it to $R_TLV and $G_TLV (or say why not)."
    fail=1
  fi
done

# 3. every broadcast state must be read somewhere.
face_states "${EXPECT_STATES[@]}" > "$tmp/states_face"
for state in "${EXPECT_STATES[@]}"; do
  if ! grep -qx "$state" "$tmp/states_face"; then
    echo "✗ AlayaCore broadcasts SM {\"type\":\"session\",\"data\":{\"state\":\"$state\"}} and nothing in AlayaFace reads it"
    echo "  Decide it where the two readers live: src-tauri/src/reader.rs and"
    echo "  src-go/internal/session/reader.go act on the lifecycle to end a"
    echo "  session; src-elm/src/Session/Handlers.elm owns readiness. A state"
    echo "  nobody reads is a lifecycle event thrown away — which is exactly how"
    echo "  v12's \`closed\` sat unhandled here until it was wired up."
    fail=1
  fi
done

# 4. every command we send must be one the registry answers. The reverse is NOT
#    required: AlayaFace implements a subset of the vocabulary on purpose.
face_commands > "$tmp/commands_face"
require_min "sent command (this repo)" "$(wc -l < "$tmp/commands_face")" 8 || fail=1
printf '%s\n' "${EXPECT_COMMANDS[@]}" > "$tmp/commands_core"
unknown=$(comm -23 "$tmp/commands_face" "$tmp/commands_core")
if [[ -n "$unknown" ]]; then
  echo "✗ AlayaFace sends command(s) AlayaCore does not register: $(echo "$unknown" | tr '\n' ' ')"
  echo "  That is an UNKNOWN_COMMAND CO for a user action, or silence. Either the"
  echo "  core renamed or dropped it, or this repo invented it."
  fail=1
fi

# ─── Refresh the fixtures when the core was the authority ───────────
#
# Written unconditionally on a live-core run (not only on drift), so the
# fixtures always describe the core that was checked out — that is what makes
# the CI run meaningful.

fixture_header() {
  # $1 what the fact is, $2 where in AlayaCore it comes from.
  printf '# %s\n' "$1"
  printf '# Source: internal/%s.\n' "$2"
  printf '# Refreshed by scripts/check-alayacore-protocol.sh whenever it runs with\n'
  printf '# AlayaCore checked out. AlayaCore is a separate repo and absent from CI,\n'
  printf '# so this file is what the check compares against there.\n'
}

if (( REGEN )); then
  {
    fixture_header "message_version AlayaCore announces as its first boot frame" \
      "agent/session_types.go (const messageVersion)"
    printf '%s\n' "$EXPECT_VERSION"
  } > "$FIX_VERSION"
  {
    fixture_header "TLV tags AlayaCore defines, in either direction" "tlv/tlv.go"
    printf '%s\n' "${EXPECT_TAGS[@]}"
  } > "$FIX_TAGS"
  {
    fixture_header "the session lifecycle states AlayaCore BROADCASTS, i.e. the phases named in setState's guard — NOT the whole SessionState vocabulary (starting and initializing exist but never reach an adapter)" \
      "agent/session.go (setState), via SessionState.String()"
    printf '%s\n' "${EXPECT_STATES[@]}"
  } > "$FIX_STATES"
  {
    fixture_header "command names AlayaCore's registry answers — canonical names and aliases. AlayaFace sends a subset; anything it sends that is NOT listed here comes back as UNKNOWN_COMMAND" \
      "commands/commands.go (CommandName* constants, commandAliases)"
    printf '%s\n' "${EXPECT_COMMANDS[@]}"
  } > "$FIX_COMMANDS"
fi

if (( fail )); then
  echo "✗ protocol drift — see the lines above"
  exit 1
fi
echo "✓ protocol OK — message_version $EXPECT_VERSION; ${#EXPECT_TAGS[@]} tags; states [${EXPECT_STATES[*]}]; $(wc -l < "$tmp/commands_face") sent commands all registered (of ${#EXPECT_COMMANDS[@]})"
