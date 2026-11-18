#!/bin/bash
# Tests the talker's reply handling without tokens:
#   1. offers (`<offer>`, Offer.swift): what's kept aside, yes / no / anything else (English and Hebrew),
#      expiry, a changed screen, and what may wait for a yes
#   2. the talker eval replayed: the real replies saved in tools/eval-talker/fixtures.json, scored again by
#      the eval's checks and run through the app's own TalkParser (so prompt, parser or check changes that
#      break tag parsing show up)
#   3. what is said: only speech, however the reply is cut into stream pieces (tools/tests/talk-parser)
#   4. routing: TalkerRoute's phrase table (tools/tests/talker-route/cases.tsv, English and Hebrew) and the
#      hand-over gate while the teacher sketches
#   5. "About me": only what the user said about themselves (UserFacts)
#   6. `<replace from=… to=…>`: the span of the document it names (TextSpan, tools/tests/text-swap)
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

echo "T3. What's said is only speech (an unclosed <say>, tags inside it), however the reply is streamed"
mkdir -p "$TMP/talk"
cp tools/tests/talk-parser/main.swift "$TMP/talk/main.swift"
swiftc -O -o "$TMP/talk-test" "${SRC[@]}" "$TMP/talk/main.swift" 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/talk-test" > "$TMP/talk.txt"; code=$?
grep -E "^FAIL" "$TMP/talk.txt" | sed 's/^/  /'
[ $code = 0 ] && printf "  \033[32mok\033[0m   %s checks\n" "$(grep -c '^ok' "$TMP/talk.txt")" || { printf "  \033[31mFAIL\033[0m what's said\n"; fail=1; }

echo "T4. Routing: what each question gets (teacher, extras, hints), from the phrase table"
swiftc -O -o "$TMP/route" Sources/Poinky/TalkerRoute.swift tools/tests/talker-route/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/route" tools/tests/talker-route/cases.tsv > "$TMP/route.txt"; code=$?
grep -E "^FAIL" "$TMP/route.txt" | sed 's/^/  /'
[ $code = 0 ] && printf "  \033[32mok\033[0m   %s\n" "$(tail -1 "$TMP/route.txt")" || { printf "  \033[31mFAIL\033[0m routing\n"; fail=1; }
"$TMP/route" --handover > "$TMP/handover.txt"; code=$?
grep -E "^FAIL" "$TMP/handover.txt" | sed 's/^/  /'
[ $code = 0 ] && printf "  \033[32mok\033[0m   %s\n" "$(tail -1 "$TMP/handover.txt")" || { printf "  \033[31mFAIL\033[0m hand-over\n"; fail=1; }

echo "T5. About me: only what the user said about themselves"
swiftc -O -o "$TMP/user-facts" Sources/Poinky/UserFacts.swift tools/tests/user-facts/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/user-facts" --test > "$TMP/uf.txt"; code=$?
grep -E "^FAIL" "$TMP/uf.txt" | sed 's/^/  /'
[ $code = 0 ] && printf "  \033[32mok\033[0m   %s\n" "$(tail -1 "$TMP/uf.txt")" || { printf "  \033[31mFAIL\033[0m about me\n"; fail=1; }

echo "T6. New wording goes over the right text: <replace from=… to=…> finds its span (TextSpan)"
mkdir -p "$TMP/swap"
cp tools/tests/text-swap/main.swift "$TMP/swap/main.swift"
awk '/^\/\/\/ Putting new wording into/{exit} {print}' Sources/Poinky/TextSwap.swift | grep -v "^import AppKit\|^import ApplicationServices" > "$TMP/swap/TextSpan.swift"
{ echo "import Foundation"; cat "$TMP/swap/TextSpan.swift"; } > "$TMP/swap/span.swift"
swiftc -O -o "$TMP/swap-test" "$TMP/swap/span.swift" "$TMP/swap/main.swift" 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/swap-test" > "$TMP/swap.txt"; code=$?
grep -E "^FAIL" "$TMP/swap.txt" | sed 's/^/  /'
[ $code = 0 ] && printf "  \033[32mok\033[0m   %s checks\n" "$(grep -c '^ok' "$TMP/swap.txt")" || { printf "  \033[31mFAIL\033[0m text spans\n"; fail=1; }

exit $fail
