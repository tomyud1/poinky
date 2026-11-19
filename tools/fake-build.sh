#!/bin/bash
# Stands in for build.sh in update tests (POINKY_UPDATE_BUILD=tools/fake-build.sh): copies an
# already-built app ($POINKY_FAKE_APP) into ./build and stamps it with this folder's commit, like
# build.sh does, in a couple of seconds. POINKY_FAKE_BUILD_FAIL=1 makes it fail.
set -euo pipefail
APP="build/Poinky.app"
for i in 1 2 3 4; do echo "[$i/4] Compiling Poinky Fake$i.swift"; sleep 0.3; done
[ "${POINKY_FAKE_BUILD_FAIL:-0}" = 1 ] && { echo "error: fake build failure"; exit 1; }
rm -rf "$APP"; mkdir -p build
/usr/bin/ditto "${POINKY_FAKE_APP:?set POINKY_FAKE_APP}" "$APP"
PB=/usr/libexec/PlistBuddy; PLIST="$APP/Contents/Info.plist"
for k in PoinkyCommit PoinkyCommitDate PoinkyDirty PoinkySource; do "$PB" -c "Delete :$k" "$PLIST" 2>/dev/null || true; done
"$PB" -c "Add :PoinkyCommit string $(git rev-parse HEAD)" -c "Add :PoinkyCommitDate string $(git log -1 --format=%cI)" \
      -c "Add :PoinkyDirty string 0" -c "Add :PoinkySource string $PWD" "$PLIST"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Signed ad hoc"
echo "Built $APP"
