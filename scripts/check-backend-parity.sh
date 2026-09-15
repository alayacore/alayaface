#!/usr/bin/env bash
# Backend parity check: command NAMES + behavioral CONSTANTS.
#
# The Elm client runs against TWO backends: the Tauri (Rust) commands and the
# Go HTTP RPC registry. They are hand-mirrored, and drift is silent — a
# command implemented on one side only breaks exactly that deployment (see the
# R-series: the Rust close path diverged from Go's lock/parallel semantics).
#
# Names alone are not enough, and this script used to stop there. Every item in
# section 2 is a divergence that name-parity passed while the two backends
# disagreed: MIME for an uppercase extension, the StepAudio model default, the
# fork reasoning-level response, the WAV data chunk, the missing first-run
# seeding. Each is a constant or table both sides must agree on, so each is
# compared mechanically here.
#
# Adding a shared constant? Add it below. That is the point: the check is
# cheap, the drift is not.
#
# Portable shell only — this box's awk is mawk (no ERE extensions), so the
# extractors use grep/sed/tr and plain loops.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# expect_same <label> <file-a> <file-b> — compare two normalized lists.
expect_same() {
  local label=$1 a=$2 b=$3
  # The side names default to the two backends, which is what every existing
  # caller compares. A third kind of comparison exists now (the CLIENT's encoder
  # against a backend), and hard-coding "Rust vs Go" there would name a file that
  # is not in the comparison — a misleading diff is worse than no diff.
  local la=${4:-Rust} lb=${5:-Go}
  if ! diff -q "$a" "$b" >/dev/null; then
    echo "✗ parity mismatch: $label ($la vs $lb)"
    diff "$a" "$b" | sed -e "s/^< /    only in $la: /" -e "s/^> /    only in $lb:   /" | head -30
    fail=1
  fi
}

# code_only <file> — the file without comment lines. Every literal check below
# runs against this, because a string that only appears in a prose comment
# (a doc note saying the message "matches the Rust backend exactly") satisfies
# a plain grep while the actual code disagrees — which is precisely the drift
# being looked for. Both backends use // comments.
code_only() { grep -vE '^[[:space:]]*(//|///|\*)' "$1" || true; }

# expect_both <label> <literal> <file-a> <file-b> — both sources contain it.
expect_both() {
  local label=$1 lit=$2 a=$3 b=$4
  local f
  for f in "$a" "$b"; do
    if ! code_only "$f" | grep -qF -- "$lit"; then
      echo "✗ parity mismatch: $label — '$lit' missing from $f (in code, not just comments)"
      fail=1
    fi
  done
}

# ─── 1. Command names ────────────────────────────────────────────────

# Rust: commands::<name> entries in the invoke_handler list (lib.rs).
rust_cmds=$(grep -oE 'commands::[a-z_]+' src-tauri/src/lib.rs | sed 's/commands:://' | sort -u)

# Go: "<name>": Handler entries in the RPC registry (handlers.go). Handler
# names start uppercase, so `"error": err...` keys are excluded.
go_cmds=$(grep -oE '"[a-z_]+":[[:space:]]*[A-Z][A-Za-z]+' src-go/internal/server/handlers/handlers.go \
  | sed -E 's/^"([a-z_]+)".*/\1/' | sort -u)

# transport.js: command names invoked via transport.invoke.
bridge_cmds=$(grep -oE 'invoke\("[a-z_]+"' src-elm/transport.js | sed -E 's/invoke\("([a-z_]+)"/\1/' | sort -u)

comm -23 <(echo "$rust_cmds") <(echo "$go_cmds") > "$tmp/only_rust"
comm -13 <(echo "$rust_cmds") <(echo "$go_cmds") > "$tmp/only_go"
if [ -s "$tmp/only_rust" ] || [ -s "$tmp/only_go" ]; then
  echo "✗ backend command parity mismatch (Rust vs Go):"
  [ -s "$tmp/only_rust" ] && echo "    in Rust but NOT in Go: $(tr '\n' ' ' < "$tmp/only_rust")"
  [ -s "$tmp/only_go" ] && echo "    in Go but NOT in Rust: $(tr '\n' ' ' < "$tmp/only_go")"
  fail=1
fi

# transport.js may invoke a subset (not every backend command has a UI entry
# point), so only check one direction: bridge ⊆ backends.
comm -23 <(echo "$bridge_cmds") <(cat <(echo "$rust_cmds") <(echo "$go_cmds") | sort -u) > "$tmp/only_bridge"
if [ -s "$tmp/only_bridge" ]; then
  echo "✗ transport.js invokes commands missing from BOTH backends: $(tr '\n' ' ' < "$tmp/only_bridge")"
  fail=1
fi

# ─── 2. Behavioral constants ─────────────────────────────────────────

R_FS=src-tauri/src/commands/fs.rs
G_FS=src-go/internal/server/handlers/fs.go
R_CORE=src-tauri/src/alayacore.rs
G_CORE=src-go/internal/core/core.go
R_TLV=src-tauri/src/tlv.rs
G_TLV=src-go/internal/tlv/tlv.go
R_SESS=src-tauri/src/session.rs
G_SESS=src-go/internal/session/session.go
R_DIRS=src-tauri/src/dirs.rs
G_DIRS=src-go/internal/dirs/dirs.go
R_ASR=src-tauri/src/commands/asr.rs
G_ASR=src-go/internal/server/handlers/asr.go
R_CMD=src-tauri/src/commands/sessions.rs
G_CMD=src-go/internal/server/handlers/sessions.go

# 2a. MIME table, normalized to ext=mime and sorted. Before the fix, Go
#     lowercased the extension and Rust did not: the same .PNG came back
#     image/png on one backend, application/octet-stream on the other.
#     Plain line loops (portable: no GNU-sed hold space, no awk extensions),
#     and every "no match here" case is tolerated — `set -e`/pipefail would
#     otherwise abort the script on a legitimate miss.

# Rust arms:  "jpg" | "jpeg" => "image/jpeg",
extract_mime_rust() {
  local line keys val k
  while IFS= read -r line; do
    case $line in *"=>"*) ;; *) continue ;; esac
    keys=${line%%"=>"*}
    val=${line#*"=>"}
    val=$(printf '%s' "$val" | tr -d '", \t')
    # `_ => "..."` is the default arm: no extension to record.
    for k in $(printf '%s\n' "$keys" | grep -oE '"[A-Za-z0-9]+"' | tr -d '"' || true); do
      printf '%s=%s\n' "$k" "$val"
    done
  # arms inside doc comments quote the same shape — filter them out first
  done < <(code_only "$1" | grep -E '=>[[:space:]]*"' || true) | sort -u
}

# Go arms:  case ".jpg", ".jpeg": ⏎ return "image/jpeg"
extract_mime_go() {
  local line keys val k
  keys=""
  while IFS= read -r line; do
    case $line in
      *[Cc][Aa][Ss][Ee]*\".*)
        keys=$line
        continue
        ;;
      *return*)
        [ -n "$keys" ] || continue
        val=$(printf '%s' "$line" | sed -e 's/.*return "//' -e 's/".*//')
        for k in $(printf '%s\n' "$keys" | grep -oE '"\.[A-Za-z0-9]+"' | tr -d '."' || true); do
          printf '%s=%s\n' "$k" "$val"
        done
        keys=""
        ;;
    esac
  done < <(code_only "$1" | grep -E '^[[:space:]]*(case "\.|return ")' || true) | sort -u
}

extract_mime_rust "$R_FS" > "$tmp/mime_rust"
extract_mime_go "$G_FS" > "$tmp/mime_go"
# Non-media entries live in the same match (ResolvedPath's serde renames etc.),
# so keep only the type-shaped pairs both tables actually define.
grep -E '^[a-z0-9]+=[a-z]+/[a-z0-9.+-]+$' "$tmp/mime_rust" > "$tmp/mime_rust.f" || true
grep -E '^[a-z0-9]+=[a-z]+/[a-z0-9.+-]+$' "$tmp/mime_go" > "$tmp/mime_go.f" || true
expect_same "fs MIME table" "$tmp/mime_rust.f" "$tmp/mime_go.f"
# A check that extracted nothing passes vacuously — which is worse than no
# check, because it looks like coverage. Assert the tables are populated.
for f in "$tmp/mime_rust.f" "$tmp/mime_go.f"; do
  if [ "$(wc -l < "$f")" -lt 30 ]; then
    echo "✗ parity check broken: MIME extraction too small in $f ($(wc -l < "$f") entries) — fix the extractor"
    fail=1
  fi
done

# 2b. TLV tag constants (the wire alphabet).
grep -oE 'TAG_[A-Z_]+: &str = "[A-Za-z]{2}"' "$R_TLV" | sed -E 's/.*"([A-Za-z]{2})"/\1/' | sort -u > "$tmp/tags_rust"
grep -oE 'Tag[A-Za-z]+ += +"[A-Za-z]{2}"' "$G_TLV" | sed -E 's/.*"([A-Za-z]{2})"/\1/' | sort -u > "$tmp/tags_go"
expect_same "TLV tags" "$tmp/tags_rust" "$tmp/tags_go"
if [ "$(wc -l < "$tmp/tags_rust")" -lt 5 ] || [ "$(wc -l < "$tmp/tags_go")" -lt 5 ]; then
  echo "✗ parity check broken: TLV tag extraction too small — fix the extractor"
  fail=1
fi

# 2c. Guard constants that must move together.
#
# check_scalar <label> <rust-value> <go-value> — compares two already-extracted
# scalars and prints both on mismatch (a diff over process substitutions tells
# nobody anything).
check_scalar() {
  local label=$1 left=$2 right=$3
  if [ -z "$left" ] || [ -z "$right" ]; then
    echo "✗ parity check broken: $label extracted empty (got: '$left' vs '$right') — fix the extractor"
    fail=1
    return
  fi
  if [ "$left" != "$right" ]; then
    # The label already names both sides ("... (Rust vs Elm)"), so the values are
    # printed neutrally: hardcoding Rust/Go here mislabeled every Elm comparison.
    echo "✗ parity mismatch: $label — got '${left}' vs '${right}'"
    fail=1
  fi
}

# Sizes are compared as their SOURCE expression (`64<<20`), not a decoded
# number, so a unit slip (MiB vs MB) cannot pass by coincidence.
# Declaration lines only (`//` comments and doc examples are filtered out —
# they are what made an earlier version of this script pick up the wrong
# number), and the value is anchored on `=` for the same reason.
decls() { grep -vE '^[[:space:]]*(//|\*|///)' "$1" || true; }
shift_expr() { decls "$2" | sed -nE "s/.*$1[^=]*=[[:space:]]*([0-9]+)[[:space:]]*<<[[:space:]]*([0-9]+).*/\1<<\2/p" | head -1; }
plain_num()  { decls "$2" | sed -nE "s/.*$1[^=]*=[[:space:]]*([0-9]+).*/\1/p" | head -1; }

check_scalar "supported message_version" \
  "$(plain_num 'SUPPORTED_MESSAGE_VERSION' "$R_CORE")" \
  "$(plain_num 'SupportedMessageVersion' "$G_CORE")"

check_scalar "max TLV frame size" \
  "$(shift_expr 'MAX_FRAME_SIZE' "$R_TLV")" \
  "$(shift_expr 'MaxFrameSize' "$G_TLV")"

check_scalar "max pending commands" \
  "$(plain_num 'MAX_PENDING_COMMANDS' "$R_SESS")" \
  "$(plain_num 'maxPendingCmds' src-go/internal/session/pending_cmds.go)"

check_scalar "graceful close timeout (secs)" \
  "$(sed -nE 's/^[^\/]*GRACEFUL_CLOSE_TIMEOUT[^;]*from_secs\(([0-9]+)\).*/\1/p' "$R_CORE" | head -1)" \
  "$(plain_num 'gracefulCloseTimeout' "$G_SESS")"

check_scalar "fs data-URI cap" \
  "$(shift_expr 'MAX_DATA_URI_FILE_SIZE' "$R_FS")" \
  "$(shift_expr 'maxDataUriFileSize' "$G_FS")"

check_scalar "fs text cap" \
  "$(shift_expr 'MAX_TEXT_FILE_SIZE' "$R_FS")" \
  "$(shift_expr 'maxTextFileSize' "$G_FS")"

# 2c-bis. ui.conf (the F3 layout store) — the two constants shared by three
#     files. The CLIENT owns the schema (src-elm/src/App/UiConfig.elm) and the
#     backends are deliberately opaque storage, so these numbers are the ONLY
#     duplication by design — which is exactly why all three are compared.
#     DEFAULT_UI_CONF_VERSION decides what an absent file reports;
#     MAX_STORED_WINDOWS bounds the file's growth. A mismatch means one
#     deployment silently stops saving the layout while the other keeps going.
R_UI=src-tauri/src/commands/ui_config.rs
G_UI=src-go/internal/server/handlers/ui_config.go
E_UI=src-elm/src/App/UiConfig.elm

# elm_num <name> <file> — an Elm constant's value sits on the line AFTER
# `name =` (the 4-space continuation is the house style here), so the helpers
# above, which want `name = <digits>` on one line, cannot see it.
elm_num() { sed -nE "/^$1 =\$/{n;s/[^0-9-]*([0-9-]+).*/\1/p}" "$2" | head -1; }

check_scalar "ui.conf document version (Rust vs Go)" \
  "$(plain_num 'DEFAULT_UI_CONF_VERSION' "$R_UI")" \
  "$(plain_num 'DefaultUiConfVersion' "$G_UI")"

check_scalar "ui.conf document version (Rust vs Elm)" \
  "$(plain_num 'DEFAULT_UI_CONF_VERSION' "$R_UI")" \
  "$(elm_num 'version' "$E_UI")"

check_scalar "ui.conf max stored windows (Rust vs Go)" \
  "$(plain_num 'MAX_STORED_WINDOWS' "$R_UI")" \
  "$(plain_num 'MaxStoredWindows' "$G_UI")"

check_scalar "ui.conf max stored windows (Rust vs Elm)" \
  "$(plain_num 'MAX_STORED_WINDOWS' "$R_UI")" \
  "$(elm_num 'maxStoredWindows' "$E_UI")"

# The shared accept/refuse table: both backends run the SAME fixture, and a
# missing file is a failure, not a skip.
if [ ! -f testdata/serialization/ui_cases.json ]; then
  echo "✗ parity check broken: testdata/serialization/ui_cases.json is gone (both backends' fixture tests read it)"
  fail=1
fi

# 2c-ter. global.conf — the recursion-limit default, triplicated.
#     Unlike ui.conf the client does NOT own this schema: each backend decodes the
#     file into its own typed struct and writes that struct back, so `global.conf`
#     is REPLACE-semantics and holds exactly one key today. The default is the one
#     number all three must agree on, and a mismatch is quiet: the symptom is a
#     client showing a limit the backend replaces on the next save (and depth 8 vs
#     some other number changes when a plan stops delegating).
R_GC=src-tauri/src/commands/global_config.rs
G_GC=src-go/internal/server/handlers/global_config.go
E_GC=src-elm/src/App/GlobalConfig.elm

check_scalar "global.conf recursion limit (Rust vs Go)" \
  "$(plain_num 'DEFAULT_RECURSION_LIMIT' "$R_GC")" \
  "$(plain_num 'DefaultRecursionLimit' "$G_GC")"

check_scalar "global.conf recursion limit (Rust vs Elm)" \
  "$(plain_num 'DEFAULT_RECURSION_LIMIT' "$R_GC")" \
  "$(elm_num 'defaultRecursionLimit' "$E_GC")"


# 2c-quater. session.label.json (the G-series session name) — the cap that
#     decides when a stored name is no name. The CLIENT owns the document and
#     both backends only READ it, so the duplicated number is the whole
#     surface of the contract today. The unit is CHARACTERS, not bytes, which
#     is why the shared fixture has a 120-hanzi/360-byte case: a byte-counting
#     reader drops names the other keeps, and the same session would look
#     differently named depending on which backend serves it.
#     The Elm side (maxLabelChars in Session/Labels.elm) joins this comparison
#     in G1 — until then it covers two files, and `label_cases.json` existing
#     matters more: both backends' fixture tests read it, so a missing file is
#     a silent loss of the only cross-language assertion.
R_LABEL=src-tauri/src/dirs.rs
G_LABEL=src-go/internal/dirs/label.go

check_scalar "session label char cap (Rust vs Go)" \
  "$(plain_num 'MAX_LABEL_CHARS' "$R_LABEL")" \
  "$(plain_num 'MaxLabelChars' "$G_LABEL")"

if [ ! -f testdata/serialization/label_cases.json ]; then
  echo "✗ parity check broken: testdata/serialization/label_cases.json is gone (both backends' fixture tests read it)"
  fail=1
fi

# 2d. Seeded presets: the plan contract in the seeded system_prompt names them
#     by string, so a divergence breaks rename guards and plan detection.
#     (Rust calls the list SEED_PRESETS, Go SeedPresets — the NAMES may
#     differ, the contents may not.)
# Array literal delimiters differ by language (Rust `[...]`, Go composite
# literal `{...}`), so each side gets its own explicit pattern — and a check
# that extracts nothing fails loudly below rather than passing silently.
quoted_sorted() { grep -oE '"[A-Za-z0-9_-]+"' | tr -d '"' | sort || true; }

sed -nE 's/.*SEED_PRESETS[^=]*=[^[]*\[([^]]*)\].*/\1/p' "$R_DIRS" | head -1 | quoted_sorted > "$tmp/seeds_rust"
sed -nE 's/.*SeedPresets[^{]*\{([^}]*)\}.*/\1/p' "$G_DIRS" | head -1 | quoted_sorted > "$tmp/seeds_go"
expect_same "seed presets" "$tmp/seeds_rust" "$tmp/seeds_go"
if [ ! -s "$tmp/seeds_rust" ] || [ ! -s "$tmp/seeds_go" ]; then
  echo "✗ parity check broken: seed presets extracted empty (a rename? fix the extractor — do not delete the check)"
  fail=1
fi

# 2e. ASR wire protocols + the per-protocol model default (the fallback that
#     was unreachable on both sides lived here).
grep -oE 'PROTOCOL_[A-Z_]+: &str = "[a-z_]+"' "$R_ASR" | sed -E 's/.*"([a-z_]+)"/\1/' | sort -u > "$tmp/proto_rust" || true
grep -oE 'Protocol[A-Za-z]+ += +"[a-z_]+"' "$G_ASR" | sed -E 's/.*"([a-z_]+)"/\1/' | sort -u > "$tmp/proto_go" || true
expect_same "ASR protocols" "$tmp/proto_rust" "$tmp/proto_go"
if [ ! -s "$tmp/proto_rust" ] || [ ! -s "$tmp/proto_go" ]; then
  echo "✗ parity check broken: ASR protocols extracted empty (fix the extractor)"
  fail=1
fi

# Extract from the DEFAULT-RESOLVING FUNCTION, not the whole file: the
# literals also appear in unit-test assertions, so a file-wide grep stays
# "equal" after someone changes only the production default (verified — a
# whole-file grep missed exactly that).
sed -nE '/fn default_asr_model/,/^}/p' "$R_ASR" | grep -oE '"[a-z0-9._-]+"' | tr -d '"' | sort -u > "$tmp/models_rust" || true
sed -nE '/func DefaultAsrModel/,/^}/p' "$G_ASR" | grep -oE '"[a-z0-9._-]+"' | tr -d '"' | sort -u > "$tmp/models_go" || true
if [ "$(wc -l < "$tmp/models_rust")" -lt 2 ] || [ "$(wc -l < "$tmp/models_go")" -lt 2 ]; then
  echo "✗ parity check broken: ASR default-model function extraction came up short — fix the extractor"
  fail=1
fi
expect_same "ASR default models" "$tmp/models_rust" "$tmp/models_go"

# 2f. `asr.conf` field names, THREE copies — and the third one is the client.
#
# Why this exists: `sync_asr_config` REPLACES the file, and both backends do it
# by decoding into a typed struct and re-serialising (`json.MarshalIndent(cfg)`,
# `serde_json::to_string`). So a key the Elm encoder omits is not merely unseen,
# it is written back as the struct's zero value: a user's stored value is gone.
# `AsrConfigTest.elm` pins the client's own key list, which catches the client
# dropping a key it knows — nothing caught the BACKENDS adding one, which is the
# drift AGENTS.md describes as "the third copy moves by hand: all three
# together, or none". This makes it mechanical.
#
# Extracted from the encoder/structs only, never from a whole file: the same key
# strings appear in decoders, tests and comments, and a file-wide grep stays
# "equal" after a real change (the lesson already recorded for
# `default_asr_model`).
block() { awk -v pat="$1" '$0 ~ pat {f=1; next} f && /^[^ \t]/ {exit} f' "$2"; }

# Elm needs a second shape: an encoder is a type signature AND a value, both at
# column 0, so `block`'s "stop at the next column-0 line" ends it before the
# body starts. Print the matched line, then stop at the NEXT one.
elm_block() { awk -v pat="$1" '$0 ~ pat {print; f=1; next} f && /^[^ \t]/ {exit} f' "$2"; }

E_ELM=src-elm/src/App/AsrConfig.elm
elm_asr_keys() {
  {
    elm_block '^profileEncoder p =' "$E_ELM"
    elm_block '^encode doc =' "$E_ELM"
  } | grep -oE '\( "[a-z_0-9]+"' | sed 's/( "//; s/"//' | sort -u
}
go_asr_keys() {
  {
    block '^type AsrProfile struct' "$G_ASR"
    block '^type AsrConfig struct' "$G_ASR"
  } | grep -oE 'json:"[a-z_0-9]+"' | sed 's/json:"//; s/"//' | sort -u
}
rust_asr_keys() {
  # A `#[serde(rename)]` would make the field name a lie about the JSON key, so
  # refuse to guess rather than compare the wrong strings.
  if block '^pub struct AsrProfile' "$R_ASR" | grep -q 'rename'; then
    echo "✗ parity check broken: serde rename in AsrProfile — teach rust_asr_keys about it" >&2
    fail=1
  fi
  {
    block '^pub struct AsrProfile' "$R_ASR"
    block '^pub struct AsrConfig' "$R_ASR"
  } | sed -nE 's/^[[:space:]]*pub ([a-z_0-9]+):.*/\1/p' | sort -u
}

elm_asr_keys > "$tmp/asr_elm" || true
go_asr_keys > "$tmp/asr_go" || true
rust_asr_keys > "$tmp/asr_rust" || true
# Anti-vacuity: an extractor that returns nothing makes the comparison pass
# while proving nothing, and a rename of a struct or the encoder is exactly how
# that happens. 9 = 7 profile fields + 2 document fields, and every one is
# required to be present on every side.
for side in elm go rust; do
  n=$(wc -l < "$tmp/asr_$side")
  if [ "$n" -lt 9 ]; then
    echo "✗ parity check broken: asr.conf $side extractor found $n of 9 field names — fix the extractor, do not delete the check"
    fail=1
  fi
done
expect_same "asr.conf field names" "$tmp/asr_rust" "$tmp/asr_go" "Rust" "Go"
expect_same "asr.conf field names" "$tmp/asr_go" "$tmp/asr_elm" "Go" "Elm client"

# 2g. User-facing error strings the client displays verbatim or matches on.
#     Each must exist in both backends; a renamed one silently breaks the
#     frontend's error handling on only one deployment. File pointers follow
#     where the string is actually produced today (the sessions command files
#     no longer hold the shared ones — they live in the send/write helpers).
R_MOD=src-tauri/src/commands/mod.rs
G_IO=src-go/internal/server/handlers/io.go
R_SET=src-tauri/src/commands/settings.rs
G_SET=src-go/internal/server/handlers/settings.go
R_OBJ=src-tauri/src/commands/objects.rs
G_OBJ=src-go/internal/server/handlers/objects.go

expect_both "error string" "Session not found" "$R_SESS" "$G_SESS"
expect_both "error string" "Session is disconnected" "$R_MOD" "$G_IO"
expect_both "error string" "Session is already active" "$R_CMD" "$G_CMD"
expect_both "error string" "Reasoning level must be 0, 1 or 2" "$R_SET" "$G_SET"
expect_both "error string" "Preset is required" "$R_DIRS" "$G_DIRS"
expect_both "error string" "Not a directory" "$R_FS" "$G_FS"
expect_both "error string" "Cannot delete file: Is a directory" "$R_FS" "$G_FS"
expect_both "error string" "Cannot write file:" "$R_FS" "$G_FS"
expect_both "error string" "file too large" "$R_FS" "$G_FS"
expect_both "error string" "Invalid session id" "$R_DIRS" "$G_DIRS"
expect_both "error string" "escapes the sessions directory" "$R_DIRS" "$G_DIRS"
expect_both "error string" "Cannot read object: invalid hash" "$R_OBJ" "$G_OBJ"

# ─── Result ──────────────────────────────────────────────────────────

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "✓ backend parity OK — commands (Rust: $(echo "$rust_cmds" | wc -l), Go: $(echo "$go_cmds" | wc -l), bridge: $(echo "$bridge_cmds" | wc -l)) plus MIME, TLV tags, caps, seeds, ASR protocols/defaults/field names and error strings"
