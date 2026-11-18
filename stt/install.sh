#!/bin/bash
# Installs Poinky's local speech recognizer (Parakeet TDT 0.6B v2, English) into
# ~/Library/Application Support/Poinky/stt:
#
#   - builds the small helper that runs it (stt/: Swift, FluidAudio 0.18.3 pinned, Apache-2.0) with the Swift
#     that builds Poinky itself (a few minutes, once),
#   - downloads the model (~465 MB, Core ML, from huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml at a
#     pinned revision; NVIDIA's Parakeet, CC-BY-4.0), each file checked against a known SHA-256 (models.json),
#   - makes the helper transcribe a sentence spoken by macOS, to be sure it really works.
#
# Safe to run again: anything already in place is skipped. Nothing is installed system-wide. Poinky keeps
# working with Apple's recognizer if this isn't installed or fails.
#   POINKY_PROGRESS=1   adds "@progress <0-1> <step>" lines for the app (Settings → Voice → Speech recognition)
#   POINKY_STT_DIR=dir  installs somewhere else (tests)
#   stt/install.sh --uninstall
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
D="${POINKY_STT_DIR:-$HOME/Library/Application Support/Poinky/stt}"
say() { echo "$*"; }
progress() { [ "${POINKY_PROGRESS:-0}" = 1 ] && echo "@progress $1 $2" || true; say "$2"; }
fail() { echo "error: $*" >&2; exit 1; }

if [ "${1:-}" = "--uninstall" ]; then rm -rf "$D"; say "Removed $D"; exit 0; fi

mkdir -p "$D/bin" "$D/models"
command -v swift >/dev/null || [ -x /usr/bin/swift ] || fail "Swift isn't installed (xcode-select --install)."

# 1. The helper.
if [ ! -x "$D/bin/poinky-stt" ] || [ "$HERE/Sources/poinky-stt/main.swift" -nt "$D/bin/poinky-stt" ]; then
  progress 0.02 "Building the speech recognizer (a few minutes, once)…"
  rm -rf "$D/src"; mkdir -p "$D/src"
  cp -R "$HERE/Package.swift" "$HERE/Sources" "$D/src/"
  if [ -f "$HERE/Package.resolved" ]; then cp "$HERE/Package.resolved" "$D/src/"; fi
  if ! swift build -c release --package-path "$D/src" --scratch-path "$D/build" > "$D/build.log" 2>&1; then
    tail -20 "$D/build.log" >&2
    fail "The build didn't work (log: $D/build.log)."
  fi
  cp "$D/build/release/poinky-stt" "$D/bin/poinky-stt.new" && mv "$D/bin/poinky-stt.new" "$D/bin/poinky-stt"
  rm -rf "$D/build"   # ~1 GB of build files; the helper is all that's needed
fi

# 2. The model, file by file, each checked.
/usr/bin/python3 - "$HERE/models.json" "$D" <<'PY'
import hashlib, json, os, subprocess, sys
spec, root = sys.argv[1], sys.argv[2]
prog = os.environ.get("POINKY_PROGRESS") == "1"
for m in json.load(open(spec))["models"]:
    folder = os.path.join(root, "models", m["folder"])
    ok = os.path.join(folder, ".verified")
    if os.path.exists(ok):
        continue
    total = sum(f["size"] for f in m["files"]); done = 0
    for f in m["files"]:
        path = os.path.join(folder, f["path"])
        os.makedirs(os.path.dirname(path), exist_ok=True)
        def good():
            if not os.path.exists(path) or os.path.getsize(path) != f["size"]:
                return False
            h = hashlib.sha256()
            with open(path, "rb") as fh:
                for chunk in iter(lambda: fh.read(1 << 20), b""):
                    h.update(chunk)
            return h.hexdigest() == f["sha256"]
        if not good():
            url = f"https://huggingface.co/{m['repo']}/resolve/{m['revision']}/{f['path']}"
            if prog:
                print(f"@progress {0.45 + 0.45 * done / total:.3f} Downloading the speech model ({done // 1_000_000} of {total // 1_000_000} MB)…", flush=True)
            subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", path + ".part", url], check=True)
            os.replace(path + ".part", path)
            if not good():
                sys.exit(f"error: {f['path']} didn't match its checksum")
        done += f["size"]
    open(ok, "w").write(m["revision"] + "\n")
PY

# 3. Hear something.
progress 0.93 "Checking that it hears…"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
/usr/bin/say -v Samantha -o "$T/t.wav" --data-format=LEF32@16000 "Testing Poinky's speech recognition." 2>/dev/null \
  || /usr/bin/say -o "$T/t.wav" --data-format=LEF32@16000 "Testing Poinky's speech recognition."
heard="$(/usr/bin/python3 - "$D" "$T/t.wav" <<'PY'
import json, struct, subprocess, sys
root, wav = sys.argv[1], sys.argv[2]
data = open(wav, "rb").read()
i = data.find(b"data"); n = struct.unpack("<I", data[i + 4:i + 8])[0]; audio = data[i + 8:i + 8 + n]
p = subprocess.Popen([root + "/bin/poinky-stt"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
p.stdin.write((json.dumps({"load": root + "/models/parakeet-tdt-0.6b-v2", "version": "v2"}) + "\n").encode()); p.stdin.flush()
r = json.loads(p.stdout.readline())
if not r.get("ready"):
    sys.exit("error: " + str(r))
p.stdin.write((json.dumps({"id": 1, "samples": len(audio) // 4}) + "\n").encode() + audio); p.stdin.flush()
r = json.loads(p.stdout.readline()); p.stdin.close(); p.wait(timeout=10)
print(r.get("text", ""))
PY
)"
echo "heard: $heard"
echo "$heard" | grep -qi "testing" || fail "The recognizer didn't hear the test sentence (it heard: $heard)."
date +%s > "$D/installed"
progress 1 "Installed."
