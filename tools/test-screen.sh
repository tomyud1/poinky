#!/bin/bash
# Where things go on the screen. The paper never covers what's being explained when there's a spot of the
# smallest useful size beside it (Placement, real runs + random screens from 13" to 27"), and marks land on
# the text they name (MarkSnapper + the app's OCR on real pages, from 9 px small print to headings: under
# the right words, just below the letters, never through them).
# The marks part needs Google Chrome (renders the pages) and Node 22+. Usage: tools/test-screen.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
swiftc -O -o "$TMP/placement" Sources/Poinky/Placement.swift tools/tests/placement/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/placement" || fail=1
swiftc -O -o "$TMP/snap" Sources/Poinky/MarkSnapper.swift tools/tests/snap/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
mkdir -p "$TMP/r"
i=0
while IFS=$'\t' read -r page w h phrases; do
  node tools/tests/snap/render.mjs "$page" "$TMP/r/$i.png" "$w" "$h" "$phrases" || { echo "couldn't render $page"; exit 1; }
  i=$((i + 1))
done < <(python3 -c '
import json, sys
for c in json.load(open("tools/tests/snap/cases.json")):
    ps = []
    for m in c["marks"]:
        ps.append(m["phrase"]); ps += [m["to"]] if "to" in m else []
    print("\t".join([c["page"], str(c["screen"][0]), str(c["screen"][1]), json.dumps(ps, ensure_ascii=False)]))')
"$TMP/snap" tools/tests/snap/cases.json "$TMP/r" || fail=1
# The paper stays in the band the app found free, moves off the next subject, stays where you drag it.
node tools/tests/run-web-tests.mjs paper-place || fail=1
exit $fail
