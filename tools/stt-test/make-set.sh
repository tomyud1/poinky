#!/bin/bash
# Synthesizes the speech test set with macOS voices (`say`), as 48 kHz float WAVs (what the mic delivers).
#   tools/stt-test/make-set.sh <out-dir>
# English sentences in several accents (US, UK, Indian, Australian, Irish, South African, a whispered voice, the
# Hebrew voice reading English as a stand-in for an Israeli accent, and fast speech); Hebrew and mixed sentences
# with the Hebrew voice. Synthetic speech is cleaner than a person: scores from it are a lower bound for errors.
set -euo pipefail
cd "$(dirname "$0")"
out="${1:?out dir}"
mkdir -p "$out"
/usr/bin/python3 - "$out" <<'PY'
import json, os, subprocess, sys
out = sys.argv[1]
s = json.load(open("sentences.json"))
english = {"us": ("Samantha", None), "us2": ("Zoe (Premium)", None), "gb": ("Daniel", None), "in": ("Rishi", None),
           "au": ("Karen", None), "ie": ("Moira", None), "za": ("Tessa", None), "il": ("Carmit", None),
           "whisper": ("Whisper", None), "fast": ("Samantha", 280)}
have = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
jobs = []
for tag, (voice, rate) in english.items():
    if voice.split(" (")[0] not in have:
        print(f"(no voice {voice}: skipping {tag})"); continue
    for x in s["en"]:
        jobs.append((tag, voice, rate, x, "en"))
for x in s["he"] + s["mixed"]:
    jobs.append(("he", "Carmit", None, x, "he"))
manifest = []
for tag, voice, rate, x, lang in jobs:
    wav = os.path.join(out, f"{tag}-{x['id']}.wav")
    if not os.path.exists(wav):
        cmd = ["say", "-v", voice, "-o", wav, "--data-format=LEF32@48000"] + (["-r", str(rate)] if rate else []) + [x["text"]]
        subprocess.run(cmd, check=True)
    manifest.append({"id": f"{tag}-{x['id']}", "voice": tag, "lang": lang, "kind": x["kind"], "ref": x["text"],
                     "terms": x["terms"], "long": x.get("long", False), "wav": os.path.abspath(wav)})
with open(os.path.join(out, "clean.jsonl"), "w") as f:
    for m in manifest: f.write(json.dumps(m, ensure_ascii=False) + "\n")
print(f"{len(manifest)} clips in {out}")
PY
