#!/bin/bash
# How the last run ended is logged at the next launch ("app.unclean": froze / crashed / killed / restart; nothing
# shown to the user). 1. the classification table (no app); 2. with --app, the built app for real: a clean quit,
# a kill -9, and a frozen main thread then a kill (~45 s; it launches build/Poinky.app's binary with scratch settings).
# Usage: tools/test-launches.sh [--app]
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
swiftc -O -o "$TMP/launches" Sources/Poinky/Timeline.swift tools/tests/launches/stub.swift tools/tests/launches/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/launches" || fail=1
[ "${1:-}" = "--app" ] || exit $fail
BIN="$PWD/build/Poinky.app/Contents/MacOS/Poinky"
launch() {   # launch <name> <secs before kill -9, or 0 to let it quit by itself> [env…]
  local name=$1 secs=$2; shift 2
  mkdir -p "$TMP/$name"
  [ -f "$TMP/$name/config.json" ] || echo '{"homeShown": true, "checkForUpdates": false, "sounds": false}' > "$TMP/$name/config.json"
  env POINKY_SUPPORT_DIR="$TMP/$name" POINKY_TIMELINE_DIR="$TMP/$name/tl" POINKY_MUTE=1 "$@" "$BIN" --quit-after "$([ "$secs" = 0 ] && echo 3 || echo 120)" >/dev/null 2>&1 &
  local pid=$!
  if [ "$secs" = 0 ]; then wait $pid; else sleep "$secs"; kill -9 $pid; wait $pid 2>/dev/null; fi
}
verdict() { grep -h '"app.unclean"' "$TMP/$1/tl/"*.jsonl 2>/dev/null | tail -1; }
expect() {  # expect <name> <how or "clean"> <what>
  local v; v="$(verdict "$1")"
  if { [ "$2" = clean ] && [ -z "$v" ]; } || { [ "$2" != clean ] && [[ "$v" == *"\"how\":\"$2\""* ]]; }; then printf "  \033[32mok\033[0m   %s\n" "$3"
  else printf "  \033[31mFAIL\033[0m %s: %s\n" "$3" "${v:-no app.unclean}"; fail=1; fi
}
launch clean 0; launch clean 0; expect clean clean "a clean quit isn't counted as unclean"
launch kill 6; launch kill 0; expect kill killed "kill -9 is told apart (killed)"
launch freeze 26 POINKY_TEST_FREEZE=2; launch freeze 0; expect freeze froze "a frozen main thread, then killed (froze)"
exit $fail
