#!/bin/bash
# Pictures of quiet mode and readable answers, light and dark: the bubble (headless Chrome), the notch and the type box
# (the built app's --notch-shot / --type-box-test). Usage: tools/quiet-test/shots.sh <outdir>
set -e
cd "$(dirname "$0")/../.."
out="${1:?outdir}"; mkdir -p "$out"; node tools/quiet-test/shots.mjs "$out"

APP=build/Poinky.app/Contents/MacOS/Poinky
S=$(mktemp -d)
for a in row open long hebrew; do POINKY_SUPPORT_DIR=$S POINKY_SHOT_RECEIPT=0 POINKY_SHOT_ANSWER=$a POINKY_SHOT_QUIET=1 $APP --notch-shot "$out/notch-answer-$a.png"; done
POINKY_SUPPORT_DIR=$S POINKY_SHOT_RECEIPT=0 POINKY_SHOT_QUIET=1 POINKY_SHOT_IDLE=1 $APP --notch-shot "$out/notch-idle-quiet.png"
POINKY_SUPPORT_DIR=$S POINKY_SHOT_RECEIPT=0 POINKY_SHOT_IDLE=1 $APP --notch-shot "$out/notch-idle.png"
POINKY_SUPPORT_DIR=$S $APP --type-box-test "$out/box-light" >/dev/null 2>&1
POINKY_SUPPORT_DIR=$S POINKY_SHOT_DARK=1 $APP --type-box-test "$out/box-dark" >/dev/null 2>&1
ls "$out"
