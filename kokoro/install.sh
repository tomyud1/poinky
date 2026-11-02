#!/bin/bash
# Installs Poinky's natural voice (Kokoro) into ~/Library/Application Support/Poinky/kokoro.
#
#   - installs `uv` (a Python manager) into Poinky's folder if you don't have it,
#   - creates a private Python 3.12 environment and installs kokoro-onnx there,
#   - downloads the model (~330 MB, checked against a known checksum),
#   - starts the voice helper once to make sure it really works.
#
# Safe to run again: anything already in place is skipped. Nothing is installed system-wide.
# Downloads come from: astral.sh (uv), pypi.org (Python packages), github.com (Python itself via uv,
# and the Kokoro model files from https://github.com/thewh1teagle/kokoro-onnx/releases).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$HOME/Library/Application Support/Poinky"
K="$P/kokoro"
BASE="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"
KOKORO_ONNX="kokoro-onnx==0.6.1"
PYTHON_VERSION="3.12"
MODEL_SHA="7d5df8ecf7d4b1878015a32686053fd0eebe2bc377234608764cc0ef3636a6c5"
VOICES_SHA="bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d"

say()  { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m%s\033[0m\n" "$1" >&2; exit 1; }

# The helper script ships inside the app too; use whichever copy is next to this file.
SERVER="$HERE/kokoro_server.py"
[ -f "$SERVER" ] || fail "kokoro_server.py should be next to this script ($HERE)."

# 1. uv
find_uv() {
  for c in "$(command -v uv 2>/dev/null || true)" "$P/bin/uv" "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
if ! UV="$(find_uv)"; then
  say "Installing uv (Python manager) into Poinky's folder…"
  mkdir -p "$P/bin"
  curl -fsSL --retry 3 https://astral.sh/uv/install.sh \
    | env UV_UNMANAGED_INSTALL="$P/bin" UV_NO_MODIFY_PATH=1 sh >/dev/null \
    || fail "Couldn't install uv. Check your internet connection, or install it yourself:  brew install uv"
  UV="$(find_uv)" || fail "uv didn't install correctly. Try:  brew install uv"
fi

# 2. Python environment + package. uv's downloads stay inside Poinky's folder (so removing
#    Poinky removes everything); the cache is deleted afterwards to save ~130 MB.
export UV_CACHE_DIR="$P/uv-cache" UV_PYTHON_INSTALL_DIR="$P/python" UV_LINK_MODE=copy
mkdir -p "$K/models"
say "Setting up the voice's Python environment (first time takes a minute)…"
[ -x "$K/venv/bin/python" ] || "$UV" venv --quiet --python "$PYTHON_VERSION" "$K/venv"
VIRTUAL_ENV="$K/venv" "$UV" pip install --quiet "$KOKORO_ONNX"
rm -rf "$P/uv-cache"

# 3. Model files (downloaded to a temp name first, so an interrupted download never looks complete)
fetch() { # name, sha256
  local f="$K/models/$1"
  if [ -s "$f" ] && [ "$(shasum -a 256 "$f" | cut -d' ' -f1)" = "$2" ]; then return 0; fi
  rm -f "$f"
  say "Downloading $1…"
  curl -fL --retry 3 --progress-bar -o "$f.part" "$BASE/$1" || { rm -f "$f.part"; fail "Download failed: $BASE/$1"; }
  [ "$(shasum -a 256 "$f.part" | cut -d' ' -f1)" = "$2" ] || { rm -f "$f.part"; fail "$1 downloaded damaged. Run this again."; }
  mv "$f.part" "$f"
}
fetch kokoro-v1.0.onnx "$MODEL_SHA"
fetch voices-v1.0.bin "$VOICES_SHA"

# 4. Make sure it works: the helper says {"ready": true} once the model has loaded.
say "Testing the voice…"
OUT="$(printf '' | "$K/venv/bin/python" -I "$SERVER" "$K" 2>/dev/null | head -c 400 || true)"
case "$OUT" in
  *'"ready"'*) ;;
  *) fail "The voice helper didn't start. Delete \"$K\" and run this again; if it keeps failing, Poinky still works with Apple's voice." ;;
esac

echo "Natural voice installed in: $K"
