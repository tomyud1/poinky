#!/bin/bash
# Installs Poinky's free local voice (Kokoro) into the settings folder.
# Needs `uv` (brew install uv). Downloads ~350 MB: Python packages from PyPI and the
# model files from https://github.com/thewh1teagle/kokoro-onnx/releases
set -euo pipefail
K="$HOME/Library/Application Support/Poinky/kokoro"
mkdir -p "$K/models"
cd "$K"
[ -x venv/bin/python ] || uv venv --python 3.12 venv
VIRTUAL_ENV="$K/venv" uv pip install kokoro-onnx
cd models
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [ -s "$f" ] || curl -L --fail -o "$f" "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/$f"
done
echo "Kokoro voice installed in: $K"
