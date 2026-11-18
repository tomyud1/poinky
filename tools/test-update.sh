#!/bin/bash
# In-app updates (Updater.swift) for a developer's own checkout, without touching the real install or GitHub:
# a scratch "GitHub" (bare repo) one commit ahead of a scratch checkout. A checkout with changes that aren't
# committed must not be offered the update (it can only fail), and must say why; a clean one is offered it.
# Needs build/Poinky.app (no permissions: --update-test only checks). Usage: tools/test-update.sh
set -uo pipefail
cd "$(dirname "$0")/.."
APP="$PWD/build/Poinky.app/Contents/MacOS/Poinky"
[ -x "$APP" ] || { echo "build/Poinky.app is missing: run ./build.sh first"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fail=0
g() { git -C "$1" -c user.name=t -c user.email=t@example.com "${@:2}" >/dev/null 2>&1; }

git init -q --bare -b main "$TMP/github.git"
git clone -q "$TMP/github.git" "$TMP/checkout" 2>/dev/null
echo one > "$TMP/checkout/file.txt"; g "$TMP/checkout" add file.txt; g "$TMP/checkout" commit -m one; g "$TMP/checkout" push -q origin main
git clone -q "$TMP/github.git" "$TMP/other" 2>/dev/null
echo two > "$TMP/other/file.txt"; g "$TMP/other" commit -am two; g "$TMP/other" push -q origin main   # GitHub is now ahead

check() {   # check <name> <expected state prefix>
  mkdir -p "$TMP/support-$1"
  POINKY_SUPPORT_DIR="$TMP/support-$1" POINKY_TIMELINE_DIR="$TMP/tl-$1" POINKY_UPDATE_SOURCE="$TMP/checkout" \
    POINKY_UPDATE_CHECK_ONLY=1 "$APP" --update-test "$TMP/out-$1.txt" >/dev/null 2>&1 &
  local pid=$!
  for _ in $(seq 1 60); do kill -0 $pid 2>/dev/null || break; sleep 0.5; done
  kill -9 $pid 2>/dev/null
  local got; got="$(grep '^checked' "$TMP/out-$1.txt" 2>/dev/null)"
  if [[ "$got" == "checked $2"* ]]; then printf "  \033[32mok\033[0m   %s\n" "$3"
  else printf "  \033[31mFAIL\033[0m %s: %s\n" "$3" "${got:-no result}"; fail=1; fi
}

echo "U1. A checkout with uncommitted changes isn't offered the update, and says why"
echo "my edit" >> "$TMP/checkout/file.txt"
check dirty 'unavailable("There' "not offered, with the reason"
echo "U2. The same checkout, clean, is offered it"
git -C "$TMP/checkout" checkout -q -- file.txt
check clean 'available, changes 1' "offered (1 change)"
exit $fail
