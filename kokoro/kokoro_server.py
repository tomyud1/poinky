"""Poinky's local voice: a small helper that keeps Kokoro loaded and turns text into audio.

Protocol (stdin/stdout):
  in : one JSON request per line  {"id": 1, "text": "...", "voice": "am_michael", "speed": 1.0}
  out: one JSON header line       {"id": 1, "sr": 24000, "bytes": N}   (or {"ready": true, ...} once at start)
       followed by N bytes of little-endian float32 mono audio.
The helper exits when Poinky closes its stdin.
"""
import json
import os
import sys

import numpy as np
from kokoro_onnx import Kokoro


def main() -> None:
    root = sys.argv[1]
    kokoro = Kokoro(os.path.join(root, "models", "kokoro-v1.0.onnx"),
                    os.path.join(root, "models", "voices-v1.0.bin"))
    voices = set(kokoro.get_voices())
    out = sys.stdout.buffer

    def send(header: dict, data: bytes = b"") -> None:
        out.write((json.dumps(header) + "\n").encode())
        if data:
            out.write(data)
        out.flush()

    kokoro.create("Hi.", voice="af_heart", lang="en-us")  # warm up so the first real sentence is fast
    send({"ready": True, "voices": sorted(voices)})

    for line in sys.stdin:
        try:
            req = json.loads(line)
        except ValueError:
            continue
        rid = req.get("id")
        text = str(req.get("text", "")).strip()
        voice = req.get("voice") if req.get("voice") in voices else "af_heart"
        # British voices (bf_/bm_) sound right with British pronunciation.
        lang = req.get("lang") or ("en-gb" if voice[:1] == "b" else "en-us")
        try:
            if not text:
                raise ValueError("empty text")
            samples, sr = kokoro.create(text, voice=voice, speed=float(req.get("speed", 1.0)), lang=lang)
            data = np.asarray(samples, dtype="<f4").tobytes()
            send({"id": rid, "sr": sr, "bytes": len(data)}, data)
        except Exception as e:  # report and keep serving
            send({"id": rid, "error": str(e), "bytes": 0})


if __name__ == "__main__":
    main()
