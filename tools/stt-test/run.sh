#!/bin/bash
# Builds the speech bench (tools/stt-test/bench/main.swift + the app's listener and engines).
#   tools/stt-test/run.sh build                 → $out/bench
#   tools/stt-test/run.sh <bench args…>         builds if needed, then runs it
set -euo pipefail
cd "$(dirname "$0")/../.."
out="${POINKY_BENCH_DIR:-${TMPDIR:-/tmp}/poinky-stt-bench}"
mkdir -p "$out"
src=(tools/stt-test/bench/main.swift Sources/Poinky/SpeechListener.swift Sources/Poinky/SpeechEngine.swift
     Sources/Poinky/VoiceActivity.swift Sources/Poinky/AudioIO.swift Sources/Poinky/MicDebug.swift Sources/Poinky/LocalSpeech.swift)
if [ "${1:-}" = build ] || [ ! -x "$out/bench" ] || [ -n "$(find "${src[@]}" -newer "$out/bench" 2>/dev/null)" ]; then
  swiftc -O -o "$out/bench" "${src[@]}" 2>&1 | grep -E "error" || true
fi
[ "${1:-}" = build ] && { echo "$out/bench"; exit 0; }
exec "$out/bench" "$@"
