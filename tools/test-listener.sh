#!/bin/bash
# Checks the app's SpeechListener with Apple's real speech engine, fed speech made by `say` at real-time pace
# (no microphone): live words show while you hold the keys (also for short questions), the question sent is
# what was said, and in a hands-free call every question is heard. Needs macOS 26 with the English speech
# model installed (it is after Poinky has listened once); not run in CI.
#   tools/test-listener.sh            # POINKY_LIVE_CAPTIONS=0 runs it without the live-caption module
set -euo pipefail
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/poinky-listener-test"
mkdir -p "$out"
say -o "$out/q1.wav" --data-format=LEF32@48000 "Where is the save button"
say -o "$out/q2.wav" --data-format=LEF32@48000 "And how do I turn it off"
say -o "$out/yes.wav" --data-format=LEF32@48000 "Yes"
swiftc -O -o "$out/listener-test" tools/listener-test/main.swift \
  Sources/Poinky/SpeechListener.swift Sources/Poinky/VoiceActivity.swift Sources/Poinky/AudioIO.swift 2>&1 | grep -E "error" || true
"$out/listener-test" "$out"
