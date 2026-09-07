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
# The maximum is the count of the three accessor BODIES themselves. Raising it
# is a deliberate act: it means a new read path was added, which has to be the
# one true accessor, not a bypass.
WIN_READS_MAX=3
WIN_READS=$(geometry_reads src-elm/src/App/Windows.elm)
if [ "$WIN_READS" -gt "$WIN_READS_MAX" ]; then
  echo "✗ INV1: src-elm/src/App/Windows.elm has $WIN_READS raw windowPositions reads; maximum is $WIN_READS_MAX"
  echo "    (baseline pre-F0 was 5; the 3 that remain are winRect/winRectList/hasWin themselves)"
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

# ─── 3. No solo logic in the JS bridge (SD7) ─────────────────────────
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

echo "✓ layout invariants OK — windowPositions reads: Windows.elm $WIN_READS/$WIN_READS_MAX, View.elm + Update.elm 0; JS bridge free of solo logic"
