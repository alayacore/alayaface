#!/usr/bin/env bash
# Layout invariants for the canvas / solo-view work (F-series, TODO.md INV1 + SD7).
#
# `windowPositions` is the single source of truth for canvas layout (SD4), and
# App/Windows.winRect / winRectList / hasWin are the SOLE read path for it
# (INV1). That only means something if it is enforced: solo view derives a
# different effective rect for one window and makes every other window
# invisible, so a stray `Dict.get id model.windowPositions` somewhere else
# reads a rect that is no longer on screen — a drag started on a hidden window,
# a connection curve drawn to nowhere, a close target picked from a z that does
# not exist. Those bugs live two hops from the change that caused them, which
# is exactly the class of defect this repo keeps re-learning.
#
# So: reads outside App/Windows.elm are forbidden (zero, not "few"), and the
# reads inside App/Windows.elm are a ratchet — pinned at the current count, so
# they can only shrink. Writes stay direct everywhere: they ARE the layout store
# and a write-through-an-accessor would just hide the mutation.
#
# Baseline (a14ae80, pre-F0): 13 read sites in 3 files — App/Update.elm 6,
# App/View.elm 2, App/Windows.elm 5. F0 collapsed them into the three accessor
# bodies. 43 textual references to the field in total (reads AND writes).
#
# Portable shell only (this box's awk is mawk) — same house style as
# scripts/check-backend-parity.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

fail=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# elm_code <file> — the file with every comment BLANKED (not deleted: blanking
# keeps the line numbering, so the `grep -n` output below points at the line
# the reader can actually find). Comments are stripped because a prose note
# that quotes the forbidden pattern ("no Dict.get on windowPositions here")
# would otherwise satisfy the grep while the code agrees with us anyway.
# Handles `--` line comments (also trailing ones) and `{- ... -}` block
# comments, line-granular — Elm doc comments always span lines, so a line that
# merely opens a block comment is blanked too.
elm_code() {
  sed -e 's/[[:space:]]*--.*$/ /' "$1" \
    | awk '{
        if (inbc) { print " "; if (index($0, "-}")) inbc = 0; next }
        if (index($0, "{-")) { print " "; if (!index($0, "-}")) inbc = 1; next }
        print
      }'
}

# geometry_reads <file> — count raw reads of the layout store. `Dict.update`
# and `Dict.insert/remove/map` are deliberately NOT matched: they are writes.
geometry_reads() {
  elm_code "$1" | grep -cE 'Dict\.(get|member|toList)[^|]*windowPositions' || true
}

# geometry_lines <file> — the same matches with their real line numbers.
geometry_lines() {
  elm_code "$1" | grep -nE 'Dict\.(get|member|toList)[^|]*windowPositions' || true
}

# ─── 1. No raw reads outside App/Windows.elm (INV1) ──────────────────

for f in src-elm/src/App/View.elm src-elm/src/App/Update.elm; do
  n=$(geometry_reads "$f")
  if [ "$n" -ne 0 ]; then
    echo "✗ INV1: $f reads windowPositions directly ($n site(s)) — use App/Windows winRect / winRectList / hasWin"
    geometry_lines "$f" | sed 's/^/      /'
    fail=1
  fi
done

# ─── 2. Ratchet inside App/Windows.elm (reads may only shrink) ───────
#
# The maximum is the count of the primitive reads the accessors are BUILT ON:
# layoutRect (the store), hasWin (membership) and winRectList's own toList.
# Everything else — winRect's solo override, soloKey, soloRect, the chain
# payload — goes through those three, so a new read here means a second read
# path was added. Raising the number is a deliberate act; the pre-F0 baseline
# was 5, so 4 or fewer is always a shrink.
WIN_READS_MAX=3
WIN_READS=$(geometry_reads src-elm/src/App/Windows.elm)
if [ "$WIN_READS" -gt "$WIN_READS_MAX" ]; then
  echo "✗ INV1: src-elm/src/App/Windows.elm has $WIN_READS raw windowPositions reads; maximum is $WIN_READS_MAX"
  echo "    (the reads that are allowed: layoutRect, hasWin, winRectList)"
  geometry_lines src-elm/src/App/Windows.elm | sed 's/^/      /'
  fail=1
elif [ "$WIN_READS" -eq 0 ]; then
  # A check that can only go up is broken if the extraction stopped matching at
  # all (renamed field → grep finds nothing → "0 reads" → green). Assert the
  # accessor bodies are really there.
  for fn in winRect winRectList hasWin; do
    if ! grep -qE "^${fn} : Model" src-elm/src/App/Windows.elm; then
      echo "✗ invariant check broken: $fn is gone from src-elm/src/App/Windows.elm — fix this script, do not delete it"
      fail=1
    fi
  done
fi

# ─── 3. soloWin is written only by App/Windows (INV3) ────────────────
#
# INV3 asks for "exactly three update helpers" — a rule about code shape that
# prose can satisfy and a reader cannot check. The checkable form is narrower
# and stronger: `soloWin` is a field of the Model record, so ANY write to it
# is a `soloWin =` inside a record update, and those are legal in exactly three
# files: the type declaration (App/Types.elm) and the two places that must
# initialise the whole record (Main.elm's init, tests/TestHelpers.elm). Every
# write in App/Update.elm or App/View.elm is an ad-hoc one, which is what the
# invariant forbids.

for f in src-elm/src/App/Update.elm src-elm/src/App/View.elm src-elm/src/Plan/*.elm src-elm/src/Session/*.elm src-elm/src/Overlay/*.elm src-elm/src/Arch/*.elm; do
  [ -e "$f" ] || continue
  n=$(sed -e 's/[[:space:]]*--.*$/ /' "$f" | grep -cE '(^|[,{ ])soloWin = ' || true)
  if [ "$n" -ne 0 ]; then
    echo "✗ INV3: $f writes soloWin directly ($n site(s)) — use Win.enterSolo / exitSolo / followSolo"
    grep -nE '(^|[,{ ])soloWin = ' "$f" | sed 's/^/      /'
    fail=1
  fi
done

# …and READS of the raw field are just as bad: `soloWin` may point at a window
# that no longer exists, and only App/Windows.soloKey de-risks that (INV2b).
# So outside the module that owns it (plus the type declaration and the two
# places that must initialise every field of the record), the name must not
# appear at all — `isSolo` / `soloKey` are the questions to ask.
#
# App/UiConfig.elm is on the list for a different reason and it is worth being
# explicit about it, because this file's own rule is "no exceptions in prose":
# its `soloWin` is the NAME OF A KEY IN ui.conf, not the Model field. The wire
# format has to spell it the way both backends and the file do; renaming it to
# dodge this grep would rename the user's config key. What the check protects
# against — reading or writing the live Model field off the accessor — is
# impossible there: UiConfig imports nothing from the app.
allowed="src-elm/src/App/Windows.elm src-elm/src/App/Types.elm src-elm/src/Main.elm src-elm/src/App/UiConfig.elm"
: > "$tmp/solowin"
for f in $(find src-elm/src -name '*.elm' | sort); do
  case " $allowed " in *" $f "*) continue ;; esac
  # Through elm_code: a comment explaining the invariant names the field, and
  # that is not a violation (several of the files below quote it on purpose).
  elm_code "$f" | grep -qE 'soloWin' && echo "$f" >> "$tmp/solowin"
done
if [ -s "$tmp/solowin" ]; then
  echo "✗ INV2b/INV3: these files touch soloWin directly — ask Win.isSolo / Win.soloKey instead:"
  sed 's/^/      /' "$tmp/solowin"
  fail=1
fi

# The one premise that makes UiConfig.elm's presence on that list safe: it can
# only name the config key if it cannot reach the Model. Check it, so the
# allow-list cannot rot into a hole the day someone imports the app record.
if grep -qE '^import App\.Types' src-elm/src/App/UiConfig.elm; then
  echo "✗ INV2b/INV3: src-elm/src/App/UiConfig.elm now imports App.Types — it can read Model.soloWin, so its"
  echo "    exemption above is no longer sound. Move the codec behind an accessor, do not extend the list."
  fail=1
fi

# ─── 4. No solo logic in the JS bridge (SD7) ─────────────────────────
#
# The bridge is a dumb pipe: transport.js / chain.js / overlay.js classify by
# DOM and move bytes, and every behavior decision lives in Elm. Solo is a
# presentation STATE, so a `solo` check in JS means the two sides now disagree
# about what is on screen — and only one of them is elm-tested.
#
# F3 legitimately touches transport.js again (the ui.conf flush); this guard is
# F1/F2's freeze, so delete section 3 when F3 starts. `maximize` is NOT
# matched on purpose: transport.js already carries the OS-window isMaximized
# plumbing (dead state, see F4.1) and it is not a solo decision.
for f in src-elm/*.js; do
  [ -e "$f" ] || continue
  # elm.js is the generated Elm bundle (gitignored, `make elm`) — it starts
  # containing "solo" the moment F1 lands, and it is exactly the code this
  # guard wants to KEEP (in Elm). The bridge is the hand-written pipe.
  case $f in */elm.js) continue ;; esac
  if grep -qiE 'solo' "$f"; then
    echo "✗ SD7: $f contains a 'solo' identifier — behavior decisions belong in Elm (F1/F2 freeze the bridge)"
    grep -niE 'solo' "$f" | sed 's/^/      /' | head -10
    fail=1
  fi
done

# ─── Result ──────────────────────────────────────────────────────────

if [ "$fail" -ne 0 ]; then
  exit 1
fi

echo "✓ layout invariants OK — windowPositions reads: Windows.elm $WIN_READS/$WIN_READS_MAX, View.elm + Update.elm 0; soloWin confined to App/Windows; JS bridge free of solo logic"
