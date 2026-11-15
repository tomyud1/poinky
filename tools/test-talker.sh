#!/bin/bash
# Tests the talker's reply handling without tokens:
#   1. offers (`<offer>`, Offer.swift): what's kept aside, yes / no / anything else (English and Hebrew),
#      expiry, a changed screen, and what may wait for a yes
#   2. the talker eval replayed: the real replies saved in tools/eval-talker/fixtures.json, scored again by
#      the eval's checks and run through the app's own TalkParser (so prompt, parser or check changes that
#      break tag parsing show up)
# Usage: tools/test-talker.sh     (a live run with real replies: see tools/eval-talker/README.md)
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
# The talker's part of Brain.swift (TalkEvents, TalkParser, JSONRepair…: Foundation only), so no app build is needed.
{ echo "import Foundation"; awk '/^\/\/ MARK: - Talker replies/{f=1} f' Sources/Poinky/Brain.swift; } > "$TMP/TalkParser.swift"
SRC=("$TMP/TalkParser.swift" Sources/Poinky/SpokenText.swift Sources/Poinky/Offer.swift)

echo "T1. Offers: a yes runs what was offered, with no model call"
mkdir -p "$TMP/offer" "$TMP/parse"
cp tools/tests/offer/main.swift "$TMP/offer/main.swift"
swiftc -O -o "$TMP/offer-test" "${SRC[@]}" "$TMP/offer/main.swift" 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/offer-test" > "$TMP/offer.txt"; code=$?
grep -E "^FAIL" "$TMP/offer.txt" | sed 's/^/  /'
[ $code = 0 ] && printf "  \033[32mok\033[0m   %s checks (answers in English and Hebrew, expiry, what may wait)\n" "$(grep -c '^ok' "$TMP/offer.txt")" || { printf "  \033[31mFAIL\033[0m offers\n"; fail=1; }

echo "T2. The talker eval, replayed (saved real replies, no tokens)"
cp tools/eval-talker/parse-replies.swift "$TMP/parse/main.swift"
swiftc -O -o "$TMP/parse-replies" "${SRC[@]}" "$TMP/parse/main.swift" 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
python3 tools/eval-talker/run.py --replay --parser "$TMP/parse-replies" | sed 's/^/  /'
[ "${PIPESTATUS[0]}" = 0 ] || fail=1

exit $fail
