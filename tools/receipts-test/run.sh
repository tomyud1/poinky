#!/bin/bash
# The receipt store (Sources/Poinky/Receipts.swift) without the app: keeps the last 20, 0600 files,
# thumbnails, summaries, nothing when off, Clear. Usage: tools/receipts-test/run.sh
set -e
here="$(cd "$(dirname "$0")" && pwd)"
tmp="$(mktemp -d)"
swiftc -o "$tmp/receipts-test" "$here/stubs.swift" "$here/main.swift" "$here/../../Sources/Poinky/Receipts.swift" 2>&1 | grep -v warning || true
POINKY_RECEIPTS_DIR="$tmp/receipts" "$tmp/receipts-test"
rm -rf "$tmp"
