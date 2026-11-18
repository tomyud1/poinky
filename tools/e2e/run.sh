#!/bin/bash
# Real-use run of this checkout's build/Poinky.app with every test log on, plus a screenshot of the
# whole screen (what the overlay drew over the real app) every second.
#   tools/e2e/run.sh <outdir> <support-dir> <quit-after-secs> [app args: --ask "…" …]
# The support dir keeps memory/notes/conversations between runs of one persona; seed its config.json
# first (tools/e2e/seed.sh). Env passed through: POINKY_ASK_WAIT, POINKY_ASK_GAP, E2E_SHOT_EVERY (s, default 1).
# Writes into <outdir>: speech.log (caption ⇥ spoken), raw.jsonl (every model reply), timeline/,
# receipts/, lessons/, shots/NNN.jpg, run.txt (pid, crash reports seen).
set -u
out=$1; support=$2; quit=$3; shift 3
here=$(cd "$(dirname "$0")/../.." && pwd)
app="$here/build/Poinky.app"
mkdir -p "$out/shots" "$out/timeline" "$out/receipts" "$out/lessons"
before=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i poinky | sort)
open -n -g -W \
  --env POINKY_SUPPORT_DIR="$support" \
  --env POINKY_SPEECH_LOG="$out/speech.log" \
  --env POINKY_SPEECH_WAV="$out/speech.f32" \
  --env POINKY_RAW_LOG="$out/raw.jsonl" \
  --env POINKY_TIMELINE_DIR="$out/timeline" \
  --env POINKY_RECEIPTS_DIR="$out/receipts" \
  --env POINKY_LESSON_DIR="$out/lessons" \
  ${POINKY_ASK_WAIT:+--env POINKY_ASK_WAIT=$POINKY_ASK_WAIT} \
  ${POINKY_ASK_GAP:+--env POINKY_ASK_GAP=$POINKY_ASK_GAP} \
  ${E2E_EXTRA_ENV:+--env $E2E_EXTRA_ENV} \
  "$app" --args "$@" --quit-after "$quit" &
opener=$!
sleep 1.5
pid=$(pgrep -f "$app/Contents/MacOS/Poinky" | tail -1)
echo "pid $pid" > "$out/run.txt"
n=0; every=${E2E_SHOT_EVERY:-1}
start=$(date +%s)
while kill -0 "$opener" 2>/dev/null; do
  n=$((n+1)); screencapture -x -t jpg "$out/shots/$(printf %03d $n).jpg" 2>/dev/null
  sleep "$every"
  if [ $(( $(date +%s) - start )) -gt $(( ${quit%.*} + 30 )) ]; then
    echo "did not quit in time; killing $pid" >> "$out/run.txt"; [ -n "$pid" ] && kill "$pid"; break
  fi
done
wait "$opener" 2>/dev/null
after=$(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -i poinky | sort)
new=$(comm -13 <(echo "$before") <(echo "$after"))
[ -n "$new" ] && echo "NEW CRASH REPORTS: $new" >> "$out/run.txt"
echo "shots: $n" >> "$out/run.txt"
cat "$out/run.txt"
