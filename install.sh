#!/bin/bash
# Installs Poinky: downloads the source, builds it, installs the natural voice, and puts the app in Applications.
#
#   curl -fsSL https://raw.githubusercontent.com/tomyud1/poinky/main/install.sh | bash
#
# Options (add after `bash -s --`, e.g.  ... | bash -s -- --no-voice):
#   --no-voice    skip the natural voice (Phonon, ~75 MB); Poinky then speaks with Apple's voice (add it later in Settings → Voice)
#   --uninstall   remove Poinky (asks before deleting your settings and the voice)
#   --purge       with --uninstall: also delete settings, memory and the voice, without asking
#
# Everything lives in ~/Library/Application Support/Poinky and Applications/Poinky.app.
# The full log of the last install is in ~/Library/Application Support/Poinky/install.log
set -euo pipefail

REPO="https://github.com/tomyud1/poinky.git"
REF="${POINKY_REF:-main}"
SUPPORT="$HOME/Library/Application Support/Poinky"
SRC="$SUPPORT/source"
LOG="$SUPPORT/install.log"

say()  { printf "\033[1m%s\033[0m\n" "$1"; }
note() { printf "  %s\n" "$1"; }
warn() { printf "\033[33m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m%s\033[0m\n" "$1" >&2; exit 1; }

VOICE=1; UNINSTALL=0; PURGE=0
for arg in "$@"; do
  case "$arg" in
    --no-voice) VOICE=0 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    -h|--help)
      echo "Usage: install.sh [--no-voice] [--uninstall [--purge]]"
      echo "  --no-voice   skip the natural voice (Phonon, ~75 MB)"
      echo "  --uninstall  remove Poinky (asks before deleting settings and the voice)"
      echo "  --purge      with --uninstall: delete settings, memory and the voice without asking"
      exit 0 ;;
    *) fail "Unknown option: $arg  (try --help)" ;;
  esac
done

# Can we ask questions? (When run through `curl | bash`, stdin is the script, so we use the terminal.)
TTY=0; { : </dev/tty; } 2>/dev/null && TTY=1
ask() { # question, default (y/n) -> returns 0 for yes
  local def="$2" reply=""
  [ "$TTY" = 1 ] || { [ "$def" = y ]; return; }
  printf "%s [%s] " "$1" "$([ "$def" = y ] && echo Y/n || echo y/N)" >/dev/tty
  read -r reply </dev/tty || reply=""
  case "${reply:-$def}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

app_dirs() { echo "/Applications/Poinky.app"; echo "$HOME/Applications/Poinky.app"; }
quit_app() { pkill -f "Poinky.app/Contents/MacOS/Poinky" 2>/dev/null || true; sleep 0.5; }

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  say "Removing Poinky"
  quit_app
  while read -r d; do [ -d "$d" ] && { rm -rf "$d"; note "Removed $d"; }; done < <(app_dirs)
  rm -rf "$SRC" "$LOG"
  if [ -d "$SUPPORT" ]; then
    if [ "$PURGE" = 1 ] || ask "Also delete your settings, memory and the natural voice ($SUPPORT)?" n; then
      rm -rf "$SUPPORT"; note "Removed $SUPPORT"
    else
      note "Kept $SUPPORT (settings, memory, voice)."
    fi
  fi
  echo
  note "macOS keeps Poinky's permissions in System Settings > Privacy & Security."
  note "To clear them, remove Poinky from Microphone, Speech Recognition, Screen & System Audio Recording and Accessibility."
  exit 0
fi

say "Installing Poinky"
mkdir -p "$SUPPORT"
: > "$LOG"

# ---------------------------------------------------------------- 1. the Mac
MACOS="$(sw_vers -productVersion)"
[ "${MACOS%%.*}" -ge 26 ] || fail "Poinky needs macOS 26 or later (you have $MACOS). Update in System Settings > General > Software Update."
if [ "$(uname -m)" != "arm64" ]; then
  warn "This is an Intel Mac. Poinky itself should run, but it hasn't been tested there, and the natural voice may not install."
fi

# ---------------------------------------------------------------- 2. Apple's developer tools (to build it)
# The free Command Line Tools are enough: no Xcode needed. They bring Swift, git and python3.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  say "Poinky is built on your Mac, which needs Apple's free Command Line Tools."
  xcode-select --install >/dev/null 2>&1 || true
  note "Click \"Install\" in the window that just opened. This installer continues by itself when it's done (can take 5-15 minutes)."
  for _ in $(seq 1 360); do
    xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1 && command -v git >/dev/null 2>&1 && break
    sleep 5
  done
  xcode-select -p >/dev/null 2>&1 && command -v swift >/dev/null 2>&1 || fail "The Command Line Tools still aren't installed. Install them, then run this again."
fi
SDK="$(xcrun --show-sdk-version 2>/dev/null || echo 0)"
[ "${SDK%%.*}" -ge 26 ] || fail "Your developer tools are too old (macOS SDK $SDK, need 26 or newer). Update \"Command Line Tools for Xcode\" in System Settings > General > Software Update, then run this again."

# ---------------------------------------------------------------- 3. Claude (Poinky's brain)
find_claude() {
  for c in "$(command -v claude 2>/dev/null || true)" "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -n "$c" ] && [ -x "$c" ] && return 0
  done
  return 1
}
CLAUDE_NEEDS_LOGIN=0
if ! find_claude; then
  say "Poinky's brain is Claude."
  note "Poinky uses Claude Code (needs a Claude Pro or Max plan) or an Anthropic API key."
  if ask "Install Claude Code now?" y; then
    if curl -fsSL https://claude.ai/install.sh | bash >>"$LOG" 2>&1 && find_claude; then
      note "Claude Code installed."
      CLAUDE_NEEDS_LOGIN=1
    else
      warn "Couldn't install Claude Code automatically. See https://claude.com/claude-code (or use an API key in Poinky's settings)."
    fi
  else
    note "Skipped. Install it later from https://claude.com/claude-code, or paste an API key in Poinky's settings."
  fi
fi

# ---------------------------------------------------------------- 4. Source
if [ -d "$SRC/.git" ]; then
  say "Updating the source…"
  if ! { git -C "$SRC" fetch --quiet --depth 1 origin "$REF" && git -C "$SRC" reset --quiet --hard FETCH_HEAD; } >>"$LOG" 2>&1; then
    warn "Couldn't update in place; downloading fresh."
    rm -rf "$SRC"
  fi
fi
if [ ! -d "$SRC/.git" ]; then
  say "Downloading…"
  git clone --depth 1 --quiet --branch "$REF" "$REPO" "$SRC" >>"$LOG" 2>&1 \
    || fail "Couldn't download Poinky. Check your internet connection. Details: $LOG"
fi

# ---------------------------------------------------------------- 5. Build
say "Building (about a minute; macOS may ask to let codesign use a key: choose Always Allow)…"
if ! "$SRC/build.sh" >>"$LOG" 2>&1; then
  printf "\033[31mThe build failed. Last lines of the log:\033[0m\n" >&2
  tail -n 25 "$LOG" | cut -c1-240 >&2
  fail "Full log: $LOG   (please include it if you open an issue: https://github.com/tomyud1/poinky/issues)"
fi
grep -E '^Signed' "$LOG" | tail -1 | sed 's/^/  /'

# ---------------------------------------------------------------- 6. Natural voice
VOICE_OK=0
if [ "$VOICE" = 1 ]; then
  say "Installing the natural voice (Phonon, ~75 MB download, runs on your Mac)…"
  if "$SRC/phonon/install.sh"; then
    VOICE_OK=1
  else
    warn "The natural voice didn't install. Poinky still works with Apple's voice."
    note "Try again any time in Poinky's Settings → Voice → Install, or run:  \"$SRC/phonon/install.sh\""
  fi
fi

# ---------------------------------------------------------------- 7. Put it in Applications and open it
DEST="/Applications"
[ -w "$DEST" ] || { DEST="$HOME/Applications"; mkdir -p "$DEST"; }
quit_app
rm -rf "$DEST/Poinky.app"
cp -R "$SRC/build/Poinky.app" "$DEST/"
open "$DEST/Poinky.app"

say "Done! Poinky is in $DEST and lives in your notch."
echo
echo "Next:"
if [ "$CLAUDE_NEEDS_LOGIN" = 1 ]; then
  note "1. Open Terminal, run  claude  once and sign in."
else
  note "1. Make sure Claude Code is signed in (run  claude  in Terminal), or add an API key in Poinky's settings."
fi
note "2. Hold Control + Option, ask about anything on your screen, let go."
note "3. macOS asks for permissions as Poinky needs them:"
note "     - Microphone and Speech Recognition: click Allow."
note "     - Screen Recording: turn Poinky on in System Settings > Privacy & Security > Screen & System Audio Recording, then reopen Poinky."
note "     - Accessibility: only when you ask it to click or type for you."
[ "$VOICE" = 1 ] && [ "$VOICE_OK" = 0 ] && note "(Natural voice not installed: add it in Settings → Voice → Install.)"
echo "Update later by running the same install command. Remove with:  ... | bash -s -- --uninstall"
