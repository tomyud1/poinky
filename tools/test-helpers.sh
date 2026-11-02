#!/bin/bash
# Tests helpers (background agents) without spending tokens:
#   1. the stream parser (HelperEvents.swift) against every recorded run in tools/helper-runs/
#   2. AgentManager end to end with the fake helper: waiting line, follow-ups, stop, crash, error.
# Usage: tools/test-helpers.sh   (--screen: also show helpers through the real overlay, ~75 s;
#                                 --live: also run one real Claude Code helper, ~1 min)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf "  \033[32mok\033[0m   %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=1; }
expect() { grep -qE "$2" "$1" && pass "$3" || { bad "$3"; sed 's/^/       /' "$1" | grep -v " event " | head -40; }; }

echo "1. Parser"
swiftc -O -o "$TMP/parser" Sources/Poinky/HelperEvents.swift Sources/Poinky/HelperAsk.swift tools/tests/helper-events/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/parser" tools/helper-runs | grep -E "ok|FAIL" ; "$TMP/parser" tools/helper-runs >/dev/null || fail=1

echo "1b. Helper choreography in a browser (many at once: no overlaps, one hand-off and one report at a time)"
if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ] && node -e "process.exit(typeof WebSocket === 'function' ? 0 : 1)" 2>/dev/null; then
  node tools/tests/run-web-tests.mjs | sed 's/^/  /' ; [ "${PIPESTATUS[0]}" = 0 ] || fail=1
else
  echo "  (skipped: needs Google Chrome and Node 22+)"
fi

echo "2. Building"
swift build -c release 2>&1 | grep -E "error:" && exit 1
BIN="$ROOT/.build/release/Poinky"
cp -R demo/sample-project "$TMP/proj"
run() { # name, extra env..., -- tasks...
  local name="$1"; shift
  env POINKY_AGENT_LOG_DIR="$TMP/logs-$name" POINKY_HELPER_CMD="$ROOT/tools/fake-helper.py" POINKY_FAKE_SPEED=4 "$@"
}

echo "2b. Talking to a helper: stop, status, follow-ups, by pointing or by name (no model)"
"$BIN" --helper-talk-test "$TMP/talk.txt" 2>/dev/null
grep -E "^FAIL" "$TMP/talk.txt" | sed 's/^/  /'
grep -q "ALL OK" "$TMP/talk.txt" && pass "$(grep -c '^ok' "$TMP/talk.txt") phrases, status lines and talker tags" || { bad "talking to a helper"; cat "$TMP/talk.txt"; }

echo "3. Four helpers, three at a time, a follow-up and a crash"
run A POINKY_TEST_FOLLOWUP="2|Also add a test for 4 people." "$BIN" --helper-test "$TMP/A.txt" "$TMP/proj" \
  fixture:fix-bug fixture:todo-blocked fixture:crash fixture:two-turns
expect "$TMP/A.txt" "start 4: #4 Amber queued" "the 4th waits in line"
expect "$TMP/A.txt" "#3 Violet FINISHED failed" "a crash counts as failed"
expect "$TMP/A.txt" "#1 Mint FINISHED done .*followUps=1: All 4 tests pass.*" "a follow-up reaches a working helper"
expect "$TMP/A.txt" "Also handled: Also add a test for 4 people" "the follow-up is folded into its work"
expect "$TMP/A.txt" "#2 Coral FINISHED done .*checklist=4 blocked=5" "to-do list and refusals are tracked"
expect "$TMP/A.txt" "#4 Amber FINISHED done" "the waiting helper runs after a slot frees up"
expect "$TMP/A.txt" "ALL DONE" "everything finishes"

echo "4. Stop, and a follow-up right after a helper finished"
run B POINKY_FAKE_SPEED=1 POINKY_TEST_MAX=2 POINKY_TEST_STOP=1 POINKY_TEST_FOLLOWUP="3|Now say two." "$BIN" --helper-test "$TMP/B.txt" "$TMP/proj" \
  fixture:two-turns fixture:fix-bug fixture:error
expect "$TMP/B.txt" "#1 Mint FINISHED done turns=2 .*: two" "a follow-up just after the result starts a new turn"
expect "$TMP/B.txt" "Coral \"Test 2\": stopped by the user" "stop works"
expect "$TMP/B.txt" "#3 Violet FINISHED failed .*I hit an error" "an error result counts as failed"

echo "4b. Raising a hand: yes, no, a question, and one nobody answers"
run C POINKY_TEST_TELL=1 POINKY_TEST_ANSWERS="1=yes;2=No, write a small pad helper instead;3=ignore;4=The database" "$BIN" --helper-test "$TMP/C.txt" "$TMP/proj" \
  fixture:ask-install fixture:ask-install fixture:ask-install fixture:ask-question
expect "$TMP/C.txt" "#1 Mint ASKS: Can I run npm install left-pad\\? \\[npm install left-pad\\] spoken: \"Mint wants to run npm install left-pad. Is that okay\\?\" risky=true" "it asks in plain words (the card shows the exact command)"
expect "$TMP/C.txt" "#1 after the talker's message: still waiting" "a message from the talker (or the screen) never approves anything"
expect "$TMP/C.txt" "answer #1 \"yes\" → yes.*: sent" "yes goes through"
expect "$TMP/C.txt" "#1 Mint FINISHED done" "after a yes it finishes"
expect "$TMP/C.txt" "#2 Coral event note\\(\"Okay, I.{1,2}ll write a small pad helper instead" "after a no it finds another way"
grep -q "The user said no: Write a small pad helper instead" "$TMP"/logs-C/*.jsonl && pass "the reason for the no reaches it" || bad "the reason for the no reaches it"
expect "$TMP/C.txt" "Amber asks: Where should I keep the settings\\? A JSON file, or The database\\?" "a question is read with its choices"
grep -q "The user answered: {'Where should I keep the settings?': 'The database'}" "$TMP"/logs-C/*.jsonl && pass "the spoken choice reaches it" || bad "the spoken choice reaches it"
expect "$TMP/C.txt" "#3 Violet STILL WAITING for an answer" "nobody answers: it keeps waiting while the others finish"
expect "$TMP/C.txt" "WAITING for the user's OK to: npm install left-pad" "the talker knows what it's waiting for"
expect "$TMP/C.txt" "ALL DONE" "everything finishes"

echo "4c. Auto mode (the default) not available: the helper starts again without it"
run D POINKY_FAKE_NO_AUTO=1 "$BIN" --helper-test "$TMP/D.txt" "$TMP/proj" fixture:fix-bug
expect "$TMP/D.txt" "#1 Mint FINISHED done" "it still finishes"
grep -q "started again without it" "$TMP"/logs-D/*.md && pass "its log says why" || bad "its log says why"
pgrep -f "fake-helper.py" >/dev/null && bad "no helper processes left behind" || pass "no helper processes left behind"

if [ "${1:-}" = "--screen" ] || [ "${2:-}" = "--screen" ]; then
  echo "5. Helpers on screen through the real overlay (draws on your screen for ~40 s, silent)"
  [ -d build/Poinky.app ] || ./build.sh >/dev/null 2>&1
  env POINKY_AGENT_LOG_DIR="$TMP/logs-screen" POINKY_HELPER_CMD="$ROOT/tools/fake-helper.py" POINKY_FAKE_SPEED=3 POINKY_TEST_STOP=9 POINKY_TEST_BUSY="13|20" \
    build/Poinky.app/Contents/MacOS/Poinky --helper-screen-test "$TMP/screen" "$TMP/proj" fixture:fix-bug fixture:todo-blocked fixture:error 2>/dev/null
  L="$TMP/screen/log.txt"
  if grep -q "SCREEN LOCKED" "$L" 2>/dev/null; then echo "  skipped: the screen is locked (nothing draws until you unlock it)"; else
  expect "$L" "helpers on screen 3, session on" "all three helpers appear on screen"
  expect "$L" "#2 Coral stopped" "a card's Stop button stops its helper"
  expect "$L" "session ended" "the session ends while they work"
  expect "$L" "overlay shown, helpers on screen [1-3], session off" "the overlay stays up for them after the session"
  expect "$L" "phases: 1:ready 3:ready" "finished helpers wait at the edge while you're busy"
  r=$(grep -m1 "report \\[" "$L" | awk '{print $1}')
  awk -v r="${r:-0}" 'BEGIN{exit !(r >= 20)}' && pass "they report once you're free ($r s)" || bad "they report once you're free (${r:-never})"
  expect "$L" "report \\[[13], [13]\\]" "two that finished together report together"
  expect "$L" "phases: 1:report 3:report" "they stay by the buddy while it talks"
  expect "$L" "release \\[" "they merge when it's done talking"
  expect "$L" "overlay hidden, helpers on screen 0, session off" "it goes away after the last one reports"
  n=$(ls "$TMP/screen"/shot-*.png 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" -gt 20 ] && pass "snapshots of what it drew ($n)" || bad "snapshots of what it drew ($n)"

  echo "6. Pointing at helpers and talking to them, through the real overlay (~35 s, silent)"
  env POINKY_TEST_TALK=1 POINKY_AGENT_LOG_DIR="$TMP/logs-talk" POINKY_HELPER_CMD="$ROOT/tools/fake-helper.py" POINKY_FAKE_SPEED=2 \
    build/Poinky.app/Contents/MacOS/Poinky --helper-screen-test "$TMP/talk" "$TMP/proj" fixture:fix-bug fixture:todo-blocked fixture:error 2>/dev/null
  L="$TMP/talk/log.txt"
  expect "$L" "holding the keys, pointing at #1" "the helper under the mouse is the one you talk to"
  expect "$L" "phases: 1:dock\\(listening\\)" "it listens while you hold the keys"
  expect "$L" "follow-ups \\[\"Also add a test for 4 people.\"\\]" "a follow-up goes into its work"
  expect "$L" "phases: 1:dock\\(got it\\)" "it shows it got the message"
  expect "$L" "said \"What are you doing\\?\" to #1 → say\\(\"Mint (is|says)" "a status answer comes from what it reported (no model)"
  expect "$L" "#2 Coral stopped" "saying stop while pointing stops it"
  expect "$L" "ALL DONE" "everything finishes"

  echo "6b. Helpers raising their hands, through the real overlay (~45 s, silent)"
  env POINKY_TEST_ASK=1 POINKY_TEST_SHOTS=0 POINKY_AGENT_LOG_DIR="$TMP/logs-ask" POINKY_HELPER_CMD="$ROOT/tools/fake-helper.py" POINKY_FAKE_SPEED=2 \
    build/Poinky.app/Contents/MacOS/Poinky --helper-screen-test "$TMP/ask" "$TMP/proj" fixture:ask-install fixture:ask-install fixture:ask-install fixture:ask-question 2>/dev/null
  L="$TMP/ask/log.txt"
  expect "$L" "#1 Mint is asking next to the buddy" "a helper that needs your OK flies to you"
  expect "$L" "phases: 1:asking\\(hand up\\) 2:" "one asks while the others keep working"
  expect "$L" "said \"Wait, what does it want\\?\" → not an answer" "a question back isn't a yes"
  expect "$L" "said \"Yes, go ahead\" → #1 yes.*: sent" "a spoken yes reaches the one next to you"
  expect "$L" "phases: 1:thanks" "it thanks you and goes back to work"
  expect "$L" "said \"No, write a small pad helper instead\" → #2 no.*: sent" "a spoken no (with a reason) reaches it"
  expect "$L" "parked #3" "nobody answers: it goes back to the edge"
  expect "$L" "3:(fly>)?dock\\(parked\\)" "with its hand still up"
  expect "$L" "#4 Amber is asking next to the buddy" "the next one gets its turn"
  expect "$L" "said \"Violet, yes\" → #3 yes.*: sent" "a waiting helper can be answered by name later"
  expect "$L" "said \"The database\" → #4 answer\\(\"The database\"\\): sent" "a question gets your choice"
  expect "$L" "#3 Violet finished done" "they all finish"
  expect "$L" "ALL DONE" "everything finishes"
  fi
fi

if [ "${1:-}" = "--live" ]; then
  echo "7. A real Claude Code helper (uses your Claude plan)"
  cp -R demo/sample-project "$TMP/live"
  env POINKY_AGENT_LOG_DIR="$TMP/logs-live" POINKY_TEST_ANSWERS="1=yes" POINKY_TEST_FOLLOWUP="10|Also add a short Usage section to the README." "$BIN" --helper-test "$TMP/live.txt" "$TMP/live" \
    "Fix the known issue described in the README of the tipsplit project (shares don't add up to the total), and add a test for it."
  expect "$TMP/live.txt" "#1 Mint FINISHED done" "the real helper finishes"
  expect "$TMP/live.txt" "event step\\(\"(Reading|Editing|Running|Searching|Looking|Checking|Writing|Viewing|Listing|Finding)[^\"]*\"\\)" "its steps come through in plain words"
  (cd "$TMP/live" && python3 -m unittest 2>&1 | tail -1 | grep -q OK) && pass "its fix passes the project's tests" || bad "its fix passes the project's tests"
  grep -qi "usage" "$TMP/live/README.md" && pass "the follow-up was done" || bad "the follow-up was done"

  echo "7b. Real Claude Code helpers raising their hands: no, yes, and a question (uses your Claude plan)"
  mkdir -p "$TMP/live2/one" "$TMP/live2/two" "$TMP/live2/three"
  echo "old notes" > "$TMP/live2/one/notes-old.txt"; echo "old notes" > "$TMP/live2/two/notes-old.txt"
  env POINKY_AGENT_LOG_DIR="$TMP/logs-live2" POINKY_TEST_ANSWERS="1=No, keep it;2=Yes;3=beta" "$BIN" --helper-test "$TMP/live2.txt" "$TMP/live2" \
    "Delete the file one/notes-old.txt with the rm command (it's no longer needed). Do nothing else." \
    "Delete the file two/notes-old.txt with the rm command (it's no longer needed). Do nothing else." \
    "Use AskUserQuestion to ask me whether the new file in the folder three/ should be called alpha.txt or beta.txt (two options), then create it with the text hello. Do nothing else."
  expect "$TMP/live2.txt" "#1 Mint ASKS: Can I run rm .*rm .*risky=true" "deleting asks first, in plain words"
  [ -f "$TMP/live2/one/notes-old.txt" ] && pass "after a no, the file is still there" || bad "after a no, the file is still there"
  [ ! -f "$TMP/live2/two/notes-old.txt" ] && pass "after a yes, it's deleted" || bad "after a yes, it's deleted"
  expect "$TMP/live2.txt" "#3 Violet ASKS: .*alpha" "a real question comes through"
  [ -f "$TMP/live2/three/beta.txt" ] && pass "the spoken choice is used (beta.txt)" || bad "the spoken choice is used (beta.txt: $(ls "$TMP/live2/three"))"
  expect "$TMP/live2.txt" "ALL DONE" "they all finish"
fi

[ $fail = 0 ] && printf "\033[32mAll helper tests passed.\033[0m\n" || { printf "\033[31mSome helper tests failed.\033[0m\n"; exit 1; }
