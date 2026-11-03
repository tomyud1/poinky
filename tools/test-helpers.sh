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
swiftc -O -o "$TMP/parser" Sources/Poinky/HelperEvents.swift Sources/Poinky/HelperAsk.swift Sources/Poinky/HelperTranscript.swift tools/tests/helper-events/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
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

echo "4e. A plan first: go ahead, change it, or not now"
run E POINKY_TEST_PLAN=1 POINKY_TEST_ANSWERS="1=yes;2=Use SQLite instead of a JSON file;3=no" "$BIN" --helper-test "$TMP/E.txt" "$TMP/proj" \
  fixture:ask-plan fixture:ask-plan fixture:ask-plan
expect "$TMP/E.txt" "#1 Mint ASKS: Here.{1,3}s my plan. Can I start\\? .*spoken: \"Mint has a plan: Fix add in calc.py. The whole plan is in its window. Should it go ahead\\?\"" "it says it has a plan, with its title"
grep -q '"permissionMode": "plan"' "$TMP"/logs-E/*.jsonl && pass "it starts in plan mode" || bad "it starts in plan mode"
expect "$TMP/E.txt" "#1 Mint FINISHED done" "go ahead: it starts on the work"
A=$(grep -h "Approved with" "$TMP"/logs-E/*.jsonl)
echo "$A" | grep -q "'setMode'" && echo "$A" | grep -q "'mode': 'auto'" && pass "then it works in auto mode" || bad "then it works in auto mode"
echo "$A" | grep -q "'addRules'" && echo "$A" | grep -q "'npm test:\*'" && pass "with the usual safe tools" || bad "with the usual safe tools"
expect "$TMP/E.txt" "answer #2 .* → no\\(reason: \"Use SQLite instead of a JSON file\\.?\"\\)" "anything else you tell it is what to change"
expect "$TMP/E.txt" "#2 Coral FINISHED .*wants changes to the plan: Use SQLite" "the change reaches it"
expect "$TMP/E.txt" "#3 Violet FINISHED .*said no to this plan" "not now: it changes nothing"
grep -q '"kind":"plan"' "$TMP"/logs-E/*.chat.jsonl && pass "its window shows the plan" || bad "its window shows the plan"

echo "4f. Continuing a helper after Poinky restarts (from its saved window, in its own session)"
run R POINKY_TEST_RESTART=1 "$BIN" --helper-test "$TMP/R.txt" "$TMP/proj" fixture:fix-bug
expect "$TMP/R.txt" "after a restart: 1 earlier helpers: Mint \"Test 1\" done key [0-9a-f]{8}" "it's found again, with how it ended"
expect "$TMP/R.txt" "continue Mint: #1 Mint" "it can be continued, with its name"
expect "$TMP/R.txt" "continued: same session true" "in its own Claude Code session (it remembers its work)"
expect "$TMP/R.txt" "FINISHED done \\(continued\\): Continued the same session: .*Now also update the README" "it gets the new request"
expect "$TMP/R.txt" "its window now: 1 task, 2 ends, you: \\[\"Now also update the README.\"\\]" "one window with all of it"

echo "4g. Undo: a helper's changes put back from Claude Code's checkpoint"
run U POINKY_TEST_UNDO=1 "$BIN" --helper-test "$TMP/U.txt" "$TMP/proj" fixture:fix-bug
expect "$TMP/U.txt" "undo #1: checkpoints \\[\"kept\"\\]" "each run keeps a checkpoint"
expect "$TMP/U.txt" "undo #1 preview: preview.*files: \\[\".*README.md\"\\], changedSince: \\[\\]" "first it says which files it would put back"
expect "$TMP/U.txt" "undo #1: done.*rewound to the first checkpoint: true" "then puts them back to before it started"
expect "$TMP/U.txt" "its window: undone You undid its changes: put back README.md" "its window says so"

echo "4h. Two helpers in one repo: the second gets its own worktree, and its changes come back"
git init -q "$TMP/repo" && cp -R demo/sample-project/. "$TMP/repo/" && (cd "$TMP/repo" && git add -A && git -c user.name=t -c user.email=t@t commit -qm start)
echo "your own change" >> "$TMP/repo/README.md"
run W POINKY_FAKE_SPEED=1 POINKY_TEST_UNDO=3 "$BIN" --helper-test "$TMP/W.txt" "$TMP/repo" fixture:wt-slow fixture:wt-fast fixture:wt-clean
[ -f "$TMP/repo/a.txt" ] && pass "the first works in your folder" || bad "the first works in your folder"
[ "$(grep -l '"k":"worktree"' "$TMP"/logs-W/*.chat.jsonl 2>/dev/null | wc -l | tr -d ' ')" = 2 ] && pass "the next two get their own worktree" || bad "the next two get their own worktree"
grep -q "Brought its changes into repo: c.txt" "$TMP"/logs-W/*.chat.jsonl && pass "a clean one's changes come back into your folder" || bad "a clean one's changes come back into your folder"
expect "$TMP/W.txt" "#2 Coral FINISHED done.*on the git branch poinky/coral-" "one that overlaps is kept on a branch (and its report says so)"
(cd "$TMP/repo" && git branch --list 'poinky/coral-*' | grep -q coral) && pass "the branch is there" || bad "the branch is there"
grep -q "mint was here" "$TMP/repo/notes.txt" && grep -q "your own change" "$TMP/repo/README.md" && pass "nothing of yours (or the first helper's) is overwritten" || bad "nothing of yours (or the first helper's) is overwritten"
expect "$TMP/W.txt" "undo #3: done" "undoing one from a worktree takes its changes out again"
[ ! -f "$TMP/repo/c.txt" ] && pass "(c.txt is gone)" || bad "(c.txt is gone)"
[ -z "$(cd "$TMP/repo" && git worktree list | sed 1d)" ] && pass "no worktrees left behind" || bad "no worktrees left behind: $(cd "$TMP/repo" && git worktree list)"

echo "4i. The mouse and keyboard: one helper at a time"
run H POINKY_FAKE_SPEED=1 POINKY_TEST_ANSWERS="1=yes;2=yes" "$BIN" --helper-test "$TMP/H.txt" "$TMP/proj" fixture:hands fixture:hands
expect "$TMP/H.txt" "#1 Mint ASKS: Can I use your mouse\\? .*spoken: \"Mint wants to use your mouse and keyboard. Is that okay\\?\"" "the first time, it asks you"
[ "$(grep -c '#1 Mint ASKS' "$TMP/H.txt")" = 1 ] && pass "after your yes, it doesn't ask again" || bad "after your yes, it doesn't ask again ($(grep -c '#1 Mint ASKS' "$TMP/H.txt"))"
# Both ask at the same moment, so either may get the mouse first: check the order from whoever did.
first=$(grep -oE 'mouse and keyboard: #[0-9]+' "$TMP/H.txt" | head -1 | grep -oE '[0-9]+$')
second=$([ "$first" = 2 ] && echo 1 || echo 2)
firstName=$([ "$first" = 2 ] && echo Coral || echo Mint)
secondName=$([ "$first" = 2 ] && echo Mint || echo Coral)
awk -v f="$first" -v s="$second" -v n="$firstName" '
  $0 ~ ("mouse and keyboard: #" f "$") && !a {a=NR}
  $0 ~ ("#" f " " n " FINISHED") && !b {b=NR}
  $0 ~ ("mouse and keyboard: #" s "$") && !c {c=NR}
  END{exit !(a && b && c && a<b && b<c)}' "$TMP/H.txt" && pass "the second waits until the first is done with it" || { bad "the second waits until the first is done with it"; grep -E "mouse and keyboard|FINISHED" "$TMP/H.txt" | sed 's/^/       /'; }
expect "$TMP/H.txt" "#$second $secondName FINISHED done" "then it gets its turn and finishes"
grep -q "Waiting for the mouse and keyboard ($firstName is using them)" "$TMP"/logs-H/*.chat.jsonl && pass "its window says it's waiting for the mouse" || bad "its window says it's waiting for the mouse"

echo "4j. Away: a helper's question reaches your phone (a fake ntfy server), and its button answers it"
NP=$((8800 + RANDOM % 600))
python3 tools/fake-ntfy.py $NP "$TMP/ntfy.txt" tap & NPID=$!
sleep 0.5
run N POINKY_TEST_NTFY="http://127.0.0.1:$NP" "$BIN" --helper-test "$TMP/N.txt" "$TMP/proj" fixture:ask-install
kill $NPID 2>/dev/null
expect "$TMP/ntfy.txt" "notification on poinky-test: title='Mint needs your OK' message='Can I run npm install left-pad\\?\\\\nnpm install left-pad'" "it says who needs what"
expect "$TMP/ntfy.txt" "actions=.http, Allow, http://127.0.0.1:$NP/poinky-test-reply, method=POST, body=yes [^ ]+ [a-z0-9]{10}" "with Allow / Don't allow buttons (and a one-time code)"
expect "$TMP/N.txt" "from the phone: #1 yes.*→ sent" "tapping Allow answers it"
expect "$TMP/N.txt" "#1 Mint FINISHED done" "and it goes on and finishes"
expect "$TMP/ntfy.txt" "listening on poinky-test-reply" "answers are only listened for while something waits"

echo "4d. \"Wait\": a helper stops what it's doing but stays, then takes a new direction"
run P POINKY_TEST_PAUSE="3|6|Use yarn instead." "$BIN" --helper-test "$TMP/P.txt" "$TMP/proj" fixture:fix-bug
expect "$TMP/P.txt" "pause #1: true" "it can be paused"
expect "$TMP/P.txt" "#1 after pausing: status running, paused true, talk: Mint is paused" "paused, it keeps waiting (and says so)"
expect "$TMP/P.txt" "status line: .*PAUSED by the user" "the main agent knows it's paused"
expect "$TMP/P.txt" "new direction to #1: true, paused now false" "a new direction gets it going again"
expect "$TMP/P.txt" "FINISHED done.*Done: Use yarn instead" "it finishes with the new direction"
grep -q "You paused it" "$TMP"/logs-P/*.chat.jsonl && pass "its window shows the pause" || bad "its window shows the pause"

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

  echo "6c. The Helpers window: a helper's work as it happens, typing to it, and continuing it (~45 s, silent)"
  env POINKY_TEST_WINDOW=1 POINKY_TEST_SHOTS=0 POINKY_AGENT_LOG_DIR="$TMP/logs-win" POINKY_HELPER_CMD="$ROOT/tools/fake-helper.py" POINKY_FAKE_SPEED=3 \
    build/Poinky.app/Contents/MacOS/Poinky --helper-screen-test "$TMP/win" "$TMP/proj" fixture:fix-bug 2>/dev/null
  L="$TMP/win/log.txt"
  expect "$L" "opened #1's window" "its window opens"
  expect "$L" "window while working: .*\"entries\":[2-9].*\"pill\":\"Working · " "it fills in while the helper works"
  expect "$L" "window while working: .*\"steps\":\[\"(Read|Searched|Ran)" "its steps are grouped (\"Read 3 files, …\")"
  expect "$L" "follow-ups: \[\"Also make the README example use \\\$100.\"\]" "typing in it sends the helper a message"
  expect "$L" "window after typing: \[\"Also make the README" "what you typed shows in it"
  expect "$L" "window at the end: .*\"pill\":\"Done\".* Done" "it ends with Done and the summary"
  expect "$L" "typed to the finished helper \\(box said \"Ask Mint to do more" "a finished helper can be asked for more"
  expect "$L" "continue Mint \\(session kept\\): #2 Mint" "it continues its own session, with its name"
  expect "$L" "window after continuing: .*\"pill\":\"Done\".*\"list\":\\[\"Mint[^\"]*\"\\]" "one window for all of it (the list shows it once)"
  grep -q "## Continued" "$TMP"/logs-win/*.md && pass "its log goes on" || bad "its log goes on"
  [ -s "$TMP/win/window-working.png" ] && pass "a picture of the window" || bad "a picture of the window"
  [ -n "${KEEP_SHOTS:-}" ] && cp "$TMP"/win/window-*.png "$KEEP_SHOTS"/ 2>/dev/null

  echo "6d. Typing to Poinky (⌃⌥T): the box near the mouse"
  build/Poinky.app/Contents/MacOS/Poinky --type-box-test "$TMP/type" 2>/dev/null
  L="$TMP/type/log.txt"
  expect "$L" "open true, key true, placeholder Ask Poinky" "it opens ready to type"
  expect "$L" "after Shift-Return: \"Why does this fail\?\\\\nTypeError" "Shift-Return adds a line (for pasted errors)"
  expect "$L" "sent \"Why does this fail\?\\\\nTypeError: x is undefined\" to Poinky" "Return sends it to Poinky"
  expect "$L" "sent \"also add a test\" to #3" "opened on a helper, it types to that helper"
  expect "$L" "draft kept: \"a draft\"" "Esc closes it and keeps what you were typing"
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

  echo "7c. Undo, a plan, and continuing, with real Claude Code helpers (uses your Claude plan)"
  mkdir -p "$TMP/live3/u" "$TMP/live3/p"
  printf 'def add(a, b):\n    return a - b\n' > "$TMP/live3/u/calc.py"; cp "$TMP/live3/u/calc.py" "$TMP/live3/p/calc.py"
  env POINKY_AGENT_LOG_DIR="$TMP/logs-live3" POINKY_TEST_UNDO=1 "$BIN" --helper-test "$TMP/live3.txt" "$TMP/live3/u" \
    "In calc.py, make add return a + b, and create notes.txt with the word hi. Do nothing else."
  expect "$TMP/live3.txt" "undo #1 preview: .*calc.py.*notes.txt|undo #1 preview: .*notes.txt.*calc.py" "it knows which files it changed"
  grep -q "a - b" "$TMP/live3/u/calc.py" && [ ! -f "$TMP/live3/u/notes.txt" ] && pass "undo puts calc.py back and removes notes.txt" || bad "undo puts calc.py back and removes notes.txt ($(cat "$TMP/live3/u/calc.py" | tail -1); notes: $(ls "$TMP/live3/u"))"
  env POINKY_AGENT_LOG_DIR="$TMP/logs-live4" POINKY_TEST_PLAN=1 POINKY_TEST_ANSWERS="1=yes" POINKY_TEST_RESTART=1 "$BIN" --helper-test "$TMP/live4.txt" "$TMP/live3/p" \
    "Fix the bug in calc.py (add subtracts). Keep it small."
  expect "$TMP/live4.txt" "#1 Mint ASKS: Here.{1,3}s my plan" "a real helper asks with its plan first"
  grep -q "a + b" "$TMP/live3/p/calc.py" && pass "after go ahead, it makes the change" || bad "after go ahead, it makes the change"
  expect "$TMP/live4.txt" "continued: same session true" "after a restart, it continues in its own session"
  expect "$TMP/live4.txt" "FINISHED done \\(continued\\)" "and finishes the new request"
fi

[ $fail = 0 ] && printf "\033[32mAll helper tests passed.\033[0m\n" || { printf "\033[31mSome helper tests failed.\033[0m\n"; exit 1; }
