#!/bin/bash
# Table tests for quiet mode's phrases, the Copy button's text and the silent pace (Sources/Poinky/Quiet.swift).
set -e
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
swiftc -O Sources/Poinky/Quiet.swift tools/quiet-test/main.swift -o "$out/quiet-test" 2>&1 | grep -v warning || true
"$out/quiet-test"
