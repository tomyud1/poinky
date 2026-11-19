#!/bin/bash
# tools/e2e/show.sh <url-or-file> [width height x y]: a page in front, in its own Chrome instance
# (scratch profile, app window) so it can be closed without touching anyone's browser.
# tools/e2e/show.sh --close: closes it.
prof=${E2E_CHROME_PROFILE:-${TMPDIR:-/tmp}/poinky-e2e-chrome}
if [ "$1" = "--close" ]; then pkill -f -- "--user-data-dir=$prof" ; exit 0; fi
u=$1; [ -e "$u" ] && u="file://$(cd "$(dirname "$u")" && pwd)/$(basename "$u")"
w=${2:-1500}; h=${3:-1000}; x=${4:-100}; y=${5:-60}
pkill -f -- "--user-data-dir=$prof"; sleep 0.5
open -na "Google Chrome" --args --user-data-dir="$prof" --no-first-run --no-default-browser-check \
  --app="$u" --window-size=$w,$h --window-position=$x,$y
sleep 2.5
