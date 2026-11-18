#!/bin/bash
# Speech logic that needs no model, mic or network (language pick, context words, word errors, levels,
# VoiceActivity on a soft voice, the local model's audio window). Runs in a few seconds; in CI.
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${TMPDIR:-/tmp}/poinky-stt-check"
mkdir -p "$out"
swiftc -O -o "$out/check" tools/stt-test/logic/main.swift Sources/Poinky/SpeechListener.swift Sources/Poinky/SpeechEngine.swift \
  Sources/Poinky/LocalSpeech.swift Sources/Poinky/MicDebug.swift Sources/Poinky/VoiceActivity.swift Sources/Poinky/AudioIO.swift \
  Sources/Poinky/MicCheckWords.swift 2>&1 | grep -E "error" || true
"$out/check"
