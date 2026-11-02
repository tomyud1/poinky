#!/bin/bash
# Builds Poinky.app into ./build
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Install the Xcode Command Line Tools first:  xcode-select --install" >&2
  exit 1
fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]; then
  echo "Poinky needs macOS 26 or later (you have $(sw_vers -productVersion))." >&2
  exit 1
fi

swift build -c release

APP="build/Poinky.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ScreenBuddy "$APP/Contents/MacOS/Poinky"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp prompts/talker-prompt.md prompts/artist-prompt.md prompts/guide-prompt.md prompts/doer-prompt.md prompts/poinky-manual.md "$APP/Contents/Resources/"
cp kokoro/kokoro_server.py "$APP/Contents/Resources/"

# Overlay page + 3D engine. libs.js packs three.js and the kit as text, so cards can
# run them inside sandboxed frames that have no network access.
mkdir -p "$APP/Contents/Resources/web"
cp web/overlay.html web/lesson.js web/buddy.js "$APP/Contents/Resources/web/"
python3 - "$APP/Contents/Resources/web/libs.js" <<'PY'
import json, sys
libs = {"three": open("vendor/three.min.js").read(),
        "kit": open("web/kit.js").read(),
        "kitCss": open("web/kit.css").read()}
open(sys.argv[1], "w").write("window.LIBS = " + json.dumps(libs) + ";\n")
PY

# Sign with a stable identity so macOS remembers the Microphone / Screen Recording
# permissions across rebuilds: your Apple Development certificate if you have one,
# otherwise the local "ScreenBuddy Local Signing" certificate, otherwise ad hoc.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | sed -E 's/.*"(.*)"/\1/' || true)
if [ -z "$IDENTITY" ]; then
  IDENTITY=$(security find-identity -p codesigning 2>/dev/null | grep -m1 "ScreenBuddy Local Signing" | awk '{print $2}' || true)
fi
if [ -n "$IDENTITY" ]; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad hoc (macOS may ask for permissions again after each rebuild)."
fi

echo "Built $APP"
echo "Run it with:  open \"$APP\""
