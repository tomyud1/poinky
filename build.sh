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
SDK="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
if [ "${SDK%%.*}" -lt 26 ]; then
  echo "Your developer tools are too old (macOS SDK $SDK, need 26 or newer)." >&2
  echo "Update \"Command Line Tools for Xcode\" in System Settings > General > Software Update (or update Xcode)." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is missing. It comes with the Xcode Command Line Tools:  xcode-select --install" >&2
  exit 1
fi

swift build -c release

APP="build/Poinky.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Poinky "$APP/Contents/MacOS/Poinky"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp prompts/talker-prompt.md prompts/artist-prompt.md prompts/guide-prompt.md prompts/doer-prompt.md prompts/poinky-manual.md "$APP/Contents/Resources/"
# The voice helper and its installer travel with the app, so the app can install the voice itself
# (Settings → Voice → Install, or automatically when updating from the old Kokoro voice).
mkdir -p "$APP/Contents/Resources/phonon"
cp phonon/phonon_server.py phonon/install.sh "$APP/Contents/Resources/phonon/"
chmod +x "$APP/Contents/Resources/phonon/install.sh"
cp phonon/phonon_server.py "$APP/Contents/Resources/"

# Overlay page + 3D engine. libs.js packs three.js and the kit as text, so cards can
# run them inside sandboxed frames that have no network access.
mkdir -p "$APP/Contents/Resources/web"
cp web/overlay.html web/lesson.js web/buddy.js web/sounds.js web/helpers.js web/helpers-app.js web/helper-window.html web/video.html "$APP/Contents/Resources/web/"
# Video explainers: the pipeline that makes them (run by a helper) and the engine that plays them.
mkdir -p "$APP/Contents/Resources/explainer/prompts"
cp explainer/pipeline.py explainer/engine.js explainer/player.html explainer/render.mjs explainer/align.swift explainer/render.swift "$APP/Contents/Resources/explainer/"
cp explainer/prompts/*.md "$APP/Contents/Resources/explainer/prompts/"
python3 - "$APP/Contents/Resources/web/libs.js" <<'PY'
import json, sys
libs = {"three": open("vendor/three.min.js").read(),
        "kit": open("web/kit.js").read(),
        "kitCss": open("web/kit.css").read()}
open(sys.argv[1], "w").write("window.LIBS = " + json.dumps(libs) + ";\n")
PY

# Sign with a stable identity so macOS remembers the Microphone / Screen Recording / Accessibility
# permissions across rebuilds and updates. In order of preference:
#   1. your Apple Development certificate (if you have one),
#   2. the local "Poinky Local Signing" certificate (made here, once, if it doesn't exist),
#   3. ad hoc (macOS would ask for permissions again after every update).
# Set POINKY_KEYCHAIN to use a different keychain than your login keychain (used for testing),
# or POINKY_ADHOC=1 to skip certificates and sign ad hoc (used by CI, which has no screen to click on).
CERT_NAME="Poinky Local Signing"
KEYCHAIN="${POINKY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
KC_ARGS=(); SIGN_KC=()   # search every keychain unless overridden
[ -z "${POINKY_KEYCHAIN:-}" ] || { KC_ARGS=("$POINKY_KEYCHAIN"); SIGN_KC=(--keychain "$POINKY_KEYCHAIN"); }

find_identity() { # name pattern -> hash of the first matching identity (trusted or not)
  security find-identity -p codesigning ${KC_ARGS[@]+"${KC_ARGS[@]}"} 2>/dev/null | grep -m1 "$1" | awk '{print $2}' || true
}

make_local_certificate() {
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
  local pass="poinky-$$"
  if /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
        -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1 \
     && /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$CERT_NAME" \
        -out "$tmp/cert.p12" -passout "pass:$pass" >/dev/null 2>&1 \
     && security import "$tmp/cert.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign >/dev/null 2>&1; then
    rm -rf "$tmp"; return 0
  fi
  rm -rf "$tmp"; return 1
}

# Runs a command, but gives up (and fails) after N seconds. macOS can pop up a "codesign wants to use
# your key" dialog; on a Mac nobody is looking at (CI, SSH) that would wait forever.
with_timeout() {
  local secs="$1"; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local watcher=$!
  local rc=0; wait "$pid" 2>/dev/null || rc=$?
  kill "$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true
  return "$rc"
}

IDENTITY=""
if [ "${POINKY_ADHOC:-0}" != 1 ]; then
  IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}' || true)
  [ -n "$IDENTITY" ] || IDENTITY=$(find_identity "$CERT_NAME")
  [ -n "$IDENTITY" ] || IDENTITY=$(find_identity "ScreenBuddy Local Signing")   # the old name, still honored
fi
if [ -z "$IDENTITY" ] && [ "${POINKY_ADHOC:-0}" != 1 ]; then
  echo "Creating a local signing certificate (\"$CERT_NAME\") so macOS keeps Poinky's permissions between updates…"
  if make_local_certificate; then
    IDENTITY=$(find_identity "$CERT_NAME")
    echo "If macOS asks to let codesign use the key, click \"Always Allow\"."
  fi
fi

if [ -n "$IDENTITY" ] && with_timeout "${POINKY_SIGN_TIMEOUT:-120}" codesign --force --sign "$IDENTITY" ${SIGN_KC[@]+"${SIGN_KC[@]}"} "$APP"; then
  echo "Signed with: $IDENTITY"
else
  [ -z "$IDENTITY" ] || echo "Signing with the certificate failed or timed out; falling back to ad hoc signing (run the installer again later and click Always Allow when macOS asks)."
  codesign --force --sign - "$APP"
  echo "Signed ad hoc (macOS may ask for permissions again after each update)."
fi

echo "Built $APP"
echo "Run it with:  open \"$APP\""
