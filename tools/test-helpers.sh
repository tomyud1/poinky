#!/bin/bash
# Tests helpers (background agents) without spending tokens:
#   1. the stream parser (HelperEvents.swift) against every recorded run in tools/helper-runs/
#   2. AgentManager end to end with the fake helper: waiting line, follow-ups, stop, crash, error.
# Usage: tools/test-helpers.sh            (add --live to also run one real Claude Code helper, ~1 min)
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
pass() { printf "  \033[32mok\033[0m   %s\n" "$1"; }
bad()  { printf "  \033[31mFAIL\033[0m %s\n" "$1"; fail=1; }
expect() { grep -qE "$2" "$1" && pass "$3" || { bad "$3"; sed 's/^/       /' "$1" | grep -v " event " | head -40; }; }

echo "1. Parser"
swiftc -O -o "$TMP/parser" Sources/Poinky/HelperEvents.swift tools/tests/helper-events/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/parser" tools/helper-runs | grep -E "ok|FAIL" ; "$TMP/parser" tools/helper-runs >/dev/null || fail=1

echo "2. Building"
swift build -c release 2>&1 | grep -E "error:" && exit 1
BIN="$ROOT/.build/release/Poinky"
cp -R demo/sample-project "$TMP/proj"
run() { # name, extra env..., -- tasks...
  local name="$1"; shift
  env POINKY_AGENT_LOG_DIR="$TMP/logs-$name" POINKY_HELPER_CMD="$ROOT/tools/fake-helper.py" POINKY_FAKE_SPEED=4 "$@"
}

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
pgrep -f "fake-helper.py" >/dev/null && bad "no helper processes left behind" || pass "no helper processes left behind"

if [ "${1:-}" = "--live" ]; then
  echo "5. A real Claude Code helper (uses your Claude plan)"
  cp -R demo/sample-project "$TMP/live"
  env POINKY_AGENT_LOG_DIR="$TMP/logs-live" POINKY_TEST_FOLLOWUP="10|Also add a short Usage section to the README." "$BIN" --helper-test "$TMP/live.txt" "$TMP/live" \
    "Fix the known issue described in the README of the tipsplit project (shares don't add up to the total), and add a test for it."
  expect "$TMP/live.txt" "#1 Mint FINISHED done" "the real helper finishes"
  expect "$TMP/live.txt" "event step\(\"Reading tipsplit.py\"\)" "its steps come through in plain words"
  (cd "$TMP/live" && python3 -m unittest 2>&1 | tail -1 | grep -q OK) && pass "its fix passes the project's tests" || bad "its fix passes the project's tests"
  grep -qi "usage" "$TMP/live/README.md" && pass "the follow-up was done" || bad "the follow-up was done"
fi

[ $fail = 0 ] && printf "\033[32mAll helper tests passed.\033[0m\n" || { printf "\033[31mSome helper tests failed.\033[0m\n"; exit 1; }
