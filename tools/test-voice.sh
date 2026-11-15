#!/bin/bash
# Tests what the voice hears (SpokenText.normalize) and where replies are cut into sentences
# (SentenceSplit), without audio or tokens. Usage: tools/test-voice.sh
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/spoken" Sources/Poinky/SpokenText.swift tools/tests/spoken-text/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
"$TMP/spoken"
