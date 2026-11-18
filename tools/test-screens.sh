#!/bin/bash
# Which display the overlay uses, with made-up layouts (ScreenChoice.swift): no app, no second display needed.
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/screens" Sources/Poinky/ScreenChoice.swift tools/tests/screens/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/screens"
