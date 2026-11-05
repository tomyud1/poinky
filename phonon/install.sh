#!/bin/bash
# Installs Poinky's natural voice (Phonon 31m by Gradium) into ~/Library/Application Support/Poinky/phonon.
#
#   - installs `uv` (a Python manager) into Poinky's folder if you don't have it,
#   - creates a private Python 3.12 environment and installs Phonon's runtime (`ptts`, Rust, no PyTorch),
#   - downloads the model and 25 English voices (~75 MB, each file checked against a known SHA-256),
#   - starts the voice helper once and makes it speak, to be sure it really works,
#   - removes the old Kokoro voice if it's there (it's replaced by this one).
#
# Safe to run again: anything already in place is skipped. Nothing is installed system-wide.
# Downloads come from: astral.sh (uv), pypi.org (Python packages), github.com (Python itself via uv),
# and huggingface.co (the model: gradium/phonon-31m-en, Apache 2.0; voices: gradium/phonon-voices).
#
# POINKY_PROGRESS=1 adds machine-readable lines ("@progress 0.42 Downloading the voices…") for the app.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P="$HOME/Library/Application Support/Poinky"
PH="$P/phonon"
M="$PH/model"
PTTS="ptts==0.6.0"
NUMPY="numpy>=1.26,<3"
PYTHON_VERSION="3.12"
MODEL_REV="8c64b55ec301728e2d1695bfea87a08a267d0c2d"      # gradium/phonon-31m-en (the runtime's own pin)
VOICES_REV="da6c9ec0d47be8df5c87c730a3aa97187f3229c3"     # gradium/phonon-voices
MODEL_URL="https://huggingface.co/gradium/phonon-31m-en/resolve/$MODEL_REV"
VOICES_URL="https://huggingface.co/gradium/phonon-voices/resolve/$VOICES_REV/voices"

# name  sha256
MODEL_FILES=(
  "config.json 7062ea376e6b158543c8abec8e5af67df171c49ad70eb7e2a0fb25c16f265e06"
  "tokenizer.json 691a00068fa7b989f2f3e5ae5daa2d1a5bb319f2d5360deafcfb19a8bb6e7936"
  "default-voice.safetensors f739e8c4c76ee7f92e7c94a82002748c8cd22e99582ac49f7b9b94cd63786e18"
  "model.q8.gguf a7d9aad2cd6dc66473f24a08bc6d2939030ef4d751ef82349361fbef3272dbae"
)
# Poinky's name  catalog file  sha256   (the catalog's everyday English voices; US then UK, male then female)
VOICES=(
  "Easton LMDIYE0Oa377Qh6Z.safetensors 45c582673cb20edb04ddcca2b5a8865ddfb0a82599efadb269021e87d20fbdd4"
  "Micah 40QrMVgAxFiUnP9f.safetensors 0de1098d1051686a138d068e83ff09deb5053328bc74ec9541a1fdb90bfc24da"
  "Trevor 0zLApsZfVLLNaEGl.safetensors dc1341c8937af5534e6bbcc5c0fc5e7c10312229b59061228074f93683fe2261"
  "Russell _6Aslh2DxfmnRLmP.safetensors beae9e4030efce0a935fcb0f807dc0784d598bcaa87ad4aacb047436b1eaa411"
  "Preston qIxlZ7Ei8KvWlyQH.safetensors 6e04b84d3ae8751b22bca0a4f63936f9cb648f4f2182b2d0788071ea1c0b68a1"
  "Miles d9XCyhjo4JhkHF1d.safetensors eab20e4f159b48cfbc01b1885804e24f681f80e7a64f909182763a4e3361bee8"
  "Zoey NbpkqMVS3CJeq2j8.safetensors 97c7f8c253413574406ab80dd23f49c3ebb2517163b00a9bf86b9c4cf43e7e23"
  "Juniper NIWIOv5vTi5eRMj8.safetensors 444378eb06b7c492b86e8fc7d13e4db1a3c0cf3e68891a960bf6f0a41a13ef35"
  "Everly vjFyp2BcCyTlUmYb.safetensors 958ea94da14f46dd48c7f64adac11ed2ad2aa45f7ccd165dfebab5272664402e"
  "Harper 4SZHfMpw-p46Ywgs.safetensors 6b3da6e2d796a20c51af892c482bd6509fb88267a221aff83c870843dee2a123"
  "Hadley bXwrkHhURL1VFJdG.safetensors a879938aa9a2df0a8220bdadef88137929f71e887bd91e7db205bd5fa11661d2"
  "Delia nGzMHMPAWGaJFHOo.safetensors a0c3dcb91b2247eca56536be9ae8e8becc1c807b1136c5fe101552d6a155b24a"
  "Alfie X6NceqF285Gr04gb.safetensors 4de75497fff3030168e8aa6dca23ffeb332b1bc8c25d0bf3507ceadac953ae9c"
  "Hugh YyKcxPG7iIgS3jsK.safetensors 3169d74b47a54d1eb15e4c243f56393abe9fe90c7e1c308ecf96ee67618b152a"
  "Edwin zUCxzrOrugTSis03.safetensors ff1d0735b8b45710462b1d1f846da040f970c6eb62c7c2f36dbfb8e5bde74f1e"
  "Spencer JOW0vchyswkQUMDS.safetensors cc9ac1107b0ffce282374a19beb7bfa95847724e6b7afbac991b4ae4277d5e6d"
  "Toby dME3IWyZBvmh1n1q.safetensors 09ab315c7f4b72b4d71e66cb756184cedfb1f14d222d096e115bf95bfe7b29dc"
  "Teddy Zn7g6NxLqXlJb7Qi.safetensors baea0ea9506f3237a5ebfc61afb7c72dbd189c5603b199ef42fbb00dbda379e0"
  "Maeve 6PWnV0Nq4wu7RVBT.safetensors 56494ee67d533ad227ff0dfd0b1c13ff5aa91f1ad6e596e66c2986ba3005e844"
  "Freya GgfEkEJtxZR7gnpy.safetensors eb3cd47418349e618408c16bea7153988b3ad04b41a6033039dd474a9a4dcd23"
  "Pippa uem82D50GRv2Dwma.safetensors d41a8f01d6e33450f1ce062d332914da10beee99e585dab531750706f187c48a"
  "Elodie-Rose y9bQqIDnyxwqK01t.safetensors 21eade9d83b2e66b9364e1b6cd999a3a6704c000a71f27f34e05ace5cdfd58bb"
  "Imogen gDT1nz7Ie36ZhL-C.safetensors 1980ab3c35fa98a25b5f3b5e643fd852e14ca8a12a4a26b06aaf1abf2a8c68b1"
  "Lottie m9MxpY6IUGXtWp76.safetensors a906ebf17e43fded12b3d6bd077abb2df33bc86eff51c1beeb82e5d416527db3"
  "Bryony gfP44RlHwr2kEwk7.safetensors bcc207a73b7885e45b49ab633d3377a10158292e3a7cef9cd6764ad107f1cb9b"
)

say()  { printf "\033[1m%s\033[0m\n" "$1"; }
fail() { printf "\033[31m%s\033[0m\n" "$1" >&2; exit 1; }
progress() { [ "${POINKY_PROGRESS:-0}" = 1 ] && echo "@progress $1 $2" || true; say "$2"; }

# The helper script ships inside the app too; use whichever copy is next to this file.
SERVER="$HERE/phonon_server.py"
[ -f "$SERVER" ] || fail "phonon_server.py should be next to this script ($HERE)."
command -v curl >/dev/null 2>&1 || fail "curl is missing."

# 1. uv
find_uv() {
  for c in "$(command -v uv 2>/dev/null || true)" "$P/bin/uv" "$HOME/.local/bin/uv" /opt/homebrew/bin/uv /usr/local/bin/uv; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}
progress 0.02 "Getting the Python manager (uv)…"
if ! UV="$(find_uv)"; then
  mkdir -p "$P/bin"
  curl -fsSL --retry 3 https://astral.sh/uv/install.sh \
    | env UV_UNMANAGED_INSTALL="$P/bin" UV_NO_MODIFY_PATH=1 sh >/dev/null \
    || fail "Couldn't install uv. Check your internet connection, or install it yourself:  brew install uv"
  UV="$(find_uv)" || fail "uv didn't install correctly. Try:  brew install uv"
fi

# 2. Python environment + the runtime. uv's downloads stay inside Poinky's folder (so removing
#    Poinky removes everything), and only uv's own Python is used, so a Homebrew upgrade can't
#    break it. The cache is deleted afterwards.
export UV_CACHE_DIR="$P/uv-cache" UV_PYTHON_INSTALL_DIR="$P/python" UV_LINK_MODE=copy
mkdir -p "$M/voices"
progress 0.06 "Setting up the voice's Python environment (first time takes a minute)…"
if ! "$PH/venv/bin/python" -I -c "import sys" >/dev/null 2>&1; then
  rm -rf "$PH/venv"
  "$UV" venv --quiet --python "$PYTHON_VERSION" --python-preference only-managed "$PH/venv" \
    || fail "Couldn't create the Python environment. Check your internet connection and run this again."
fi
VIRTUAL_ENV="$PH/venv" "$UV" pip install --quiet --python "$PH/venv/bin/python" "$PTTS" "$NUMPY" \
  || fail "Couldn't install Phonon's runtime (ptts). Check your internet connection and run this again."
rm -rf "$P/uv-cache"
"$PH/venv/bin/python" -I -c "import ptts, numpy" 2>/dev/null || fail "Phonon's runtime installed but doesn't load. Delete \"$PH\" and run this again."

# 3. Model and voices (each downloaded to a temp name first, so an interrupted download never looks complete)
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
fetch() { # url, destination, sha256, label
  local url="$1" f="$2" want="$3"
  if [ -s "$f" ] && [ "$(sha "$f")" = "$want" ]; then return 0; fi
  rm -f "$f"
  if [ -t 1 ] && [ "${POINKY_PROGRESS:-0}" != 1 ]; then
    curl -fL --retry 3 --progress-bar -o "$f.part" "$url" || { rm -f "$f.part"; fail "Download failed: $url"; }
  else
    curl -fsSL --retry 3 -o "$f.part" "$url" || { rm -f "$f.part"; fail "Download failed: $url"; }
  fi
  [ "$(sha "$f.part")" = "$want" ] || { rm -f "$f.part"; fail "$4 downloaded damaged. Run this again."; }
  mv "$f.part" "$f"
}
progress 0.15 "Downloading the voice model (65 MB)…"
for entry in "${MODEL_FILES[@]}"; do
  read -r name want <<<"$entry"
  fetch "$MODEL_URL/$name" "$M/$name" "$want" "$name"
done
total=${#VOICES[@]}; i=0
for entry in "${VOICES[@]}"; do
  read -r name file want <<<"$entry"
  i=$((i + 1))
  [ $((i % 5)) = 1 ] && progress "0.$((75 + 15 * i / total))" "Downloading the voices ($i of $total)…"
  fetch "$VOICES_URL/$file" "$M/voices/$name.safetensors" "$want" "voice $name"
done

# 4. Make sure it works: load the model, then speak a sentence.
progress 0.92 "Testing the voice…"
THREADS="$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || echo 4)"
[ "$THREADS" -gt 4 ] && THREADS=4
OUT="$(printf '{"id": 1, "text": "Testing, one two three.", "voice": "Easton"}\n' \
        | "$PH/venv/bin/python" -I "$SERVER" "$M" "$THREADS" 2>&1 | LC_ALL=C tr -c '[:print:]' '.' \
        | grep -aoE '\{"(ready|id|error)"[^}]*\}|[A-Za-z]*Error[^.]*' | head -n 40 || true)"
case "$OUT" in
  *'"ready": true'*'"end": true'*) ;;
  *) printf '%s\n' "$OUT" | tail -n 5 >&2
     fail "The voice helper didn't work. Delete \"$PH\" and run this again; if it keeps failing, Poinky still works with Apple's voice." ;;
esac
printf '{"runtime": "%s", "model": "%s", "voices": "%s"}\n' "$PTTS" "$MODEL_REV" "$VOICES_REV" > "$PH/installed.json"

# 5. The old voice (Kokoro, ~460 MB) is replaced by this one.
if [ -d "$P/kokoro" ]; then
  rm -rf "$P/kokoro"
  say "Removed the old Kokoro voice (replaced by Phonon)."
fi

progress 1.00 "Natural voice installed in: $PH"
