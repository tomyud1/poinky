#!/bin/bash
# The shared record (what the teacher said and showed, how it ended; the previous session's block): no app, no tokens.
set -e
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -O -o "$out/record-test" Sources/Poinky/TeacherRecord.swift Sources/Poinky/CarryOver.swift tools/record-test/main.swift
"$out/record-test"
