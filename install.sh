#!/bin/bash
# Installs Poinky: downloads the source, builds it, and puts the app in Applications.
#   curl -fsSL https://raw.githubusercontent.com/tomyud1/poinky/main/install.sh | bash
set -euo pipefail

REPO="https://github.com/tomyud1/poinky.git"
SRC="$HOME/Library/Application Support/Poinky/source"

say() { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m%s\033[0m\n" "$1" >&2; exit 1; }

say "Installing Poinky"

# 1. A recent Mac
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || fail "Poinky needs macOS 26 or later (you have $(sw_vers -productVersion))."

# 2. Apple's developer tools (to build it)
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  fail "Install Apple's Command Line Tools in the window that just opened, then run this again."
fi

# 3. Claude Code (Poinky's brain)
if ! command -v claude >/dev/null 2>&1; then
  printf "Note: Claude Code isn't installed. Get it from https://claude.com/claude-code and sign in,\n      or add an Anthropic API key in Poinky's settings.\n"
fi

# 4. Get the latest source and build it
if [ -d "$SRC/.git" ]; then
  say "Updating the source…"
  git -C "$SRC" pull --ff-only --quiet
else
  say "Downloading…"
  mkdir -p "$(dirname "$SRC")"
  git clone --depth 1 --quiet "$REPO" "$SRC"
fi
say "Building (about a minute)…"
"$SRC/build.sh" >/dev/null

# 5. Put it in Applications and open it
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
pkill -f "Poinky.app/Contents/MacOS/Poinky" 2>/dev/null || true
rm -rf "$DEST/Poinky.app"
cp -R "$SRC/build/Poinky.app" "$DEST/"
open "$DEST/Poinky.app"

say "Done! Poinky is in $DEST and lives in your notch."
echo "Hold Control + Option and ask about anything on your screen."
echo "Optional free local voice:  \"$SRC/kokoro/install.sh\""
