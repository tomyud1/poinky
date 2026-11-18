#!/bin/bash
# Pictures of quiet mode and readable answers, light and dark: the bubble (headless Chrome), the notch and the type box
# (the built app's --notch-shot / --type-box-test). Usage: tools/quiet-test/shots.sh <outdir>
set -e
cd "$(dirname "$0")/../.."
out="${1:?outdir}"; mkdir -p "$out"
CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
page="file://$PWD/tools/tests/quiet-bubble.html"
for shot in reading long copy hover hebrew snip; do
  for bg in light dark; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1000,700 --virtual-time-budget=6000 \
      --screenshot="$out/bubble-$shot-$bg.png" "$page?shot=$shot&bg=$bg" >/dev/null 2>&1
  done
done
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --window-size=1000,700 --virtual-time-budget=6000 --force-prefers-reduced-motion \
  --screenshot="$out/bubble-long-reduced.png" "$page?shot=long" >/dev/null 2>&1
APP=build/Poinky.app/Contents/MacOS/Poinky
S=$(mktemp -d)
for a in row open long hebrew; do POINKY_SUPPORT_DIR=$S POINKY_SHOT_RECEIPT=0 POINKY_SHOT_ANSWER=$a POINKY_SHOT_QUIET=1 $APP --notch-shot "$out/notch-answer-$a.png"; done
POINKY_SUPPORT_DIR=$S POINKY_SHOT_RECEIPT=0 POINKY_SHOT_QUIET=1 POINKY_SHOT_IDLE=1 $APP --notch-shot "$out/notch-idle-quiet.png"
POINKY_SUPPORT_DIR=$S POINKY_SHOT_RECEIPT=0 POINKY_SHOT_IDLE=1 $APP --notch-shot "$out/notch-idle.png"
POINKY_SUPPORT_DIR=$S $APP --type-box-test "$out/box-light" >/dev/null 2>&1
POINKY_SUPPORT_DIR=$S POINKY_SHOT_DARK=1 $APP --type-box-test "$out/box-dark" >/dev/null 2>&1
ls "$out"
