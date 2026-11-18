#!/bin/bash
# Tests when repeating reminders come due (Reminders.swift): daily / weekdays / weekly / hourly across DST and
# time-zone changes, months off, sleep over several occurrences, a clock set back. No app, no tokens.
set -uo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swiftc -O -o "$TMP/reminders" Sources/Poinky/Reminders.swift tools/tests/reminders/stub.swift tools/tests/reminders/main.swift 2>"$TMP/swiftc.log" || { cat "$TMP/swiftc.log"; exit 1; }
TMPDIR="$TMP/" "$TMP/reminders"
