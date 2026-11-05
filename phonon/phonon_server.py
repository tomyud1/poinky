"""Poinky's local voice: a small helper that keeps Phonon loaded and streams speech as it's made.

Protocol (stdin/stdout, one JSON object per line):
  in : {"id": 1, "text": "...", "voice": "Easton", "speed": 1.0}   speak (queued in order)
       {"cancel": 7}                                                 drop every request with id <= 7
  out: {"ready": true, "voices": [...], "sr": 24000}                once, after loading and warming up
       {"id": 1, "bytes": N}  then N bytes of little-endian float32 mono audio   (one per ~80 ms chunk)
       {"id": 1, "end": true, "ttfa_ms": 5.1, "ms": 61.0}           the sentence is done
       {"id": 1, "error": "..."}                                     it failed (Poinky falls back to Apple's voice)
The helper exits when Poinky closes its stdin.

Usage: phonon_server.py MODEL_DIR [THREADS]
"""
import json
import os
import queue
import sys
import threading
import time

os.environ.setdefault("HF_HUB_OFFLINE", "1")   # everything is local; never reach for the Hub

import numpy as np
import ptts

# Poinky's speed (a multiplier) → Phonon's duration_delta condition. Measured on Phonon 31m:
# the effect flattens out past about ±0.4, and larger values make speech less reliable.
SPEED_TABLE = [(0.86, 0.30), (0.89, 0.20), (0.92, 0.10), (1.00, 0.0),
               (1.08, -0.10), (1.14, -0.20), (1.17, -0.30), (1.24, -0.40)]
MIN_SPEED, MAX_SPEED = SPEED_TABLE[0][0], SPEED_TABLE[-1][0]


def duration_delta(speed: float) -> float:
    s = min(MAX_SPEED, max(MIN_SPEED, speed))
    for (s0, d0), (s1, d1) in zip(SPEED_TABLE, SPEED_TABLE[1:]):
        if s <= s1:
            return round(d0 + (d1 - d0) * (s - s0) / (s1 - s0), 3)
    return SPEED_TABLE[-1][1]


class SilenceTrimmer:
    """Phonon starts each sentence with ~120 ms of silence and ends it with ~600 ms. Played as is,
    speech starts late and there are long gaps between sentences (and Poinky thinks it's still
    talking). This trims it as the audio streams: the silence before the speech goes (keeping a
    short lead-in so soft first sounds aren't clipped), pauses inside the sentence stay (they're
    passed on as soon as the speech resumes), and the silence at the end is capped.

    What counts as silence depends on the voice: some have a clean -80 dB floor, others room tone
    near -65 dB, and a soft "f" can be as quiet as -55 dB. So the floor is measured at the start of
    each sentence (10-40 ms, after the 5 ms click every sentence starts with, which is dropped),
    and sound is anything 12 dB above it."""

    WINDOW = 120                  # 5 ms at 24 kHz
    MIN_THRESHOLD = 10 ** (-65 / 20)
    ABOVE_FLOOR = 10 ** (12 / 20)
    SKIP = 2                      # windows at the very start: the click
    LEAD_IN = 60 * 24             # 60 ms kept before the first sound
    TAIL = 200 * 24               # 200 ms kept after the last one: the gap before the next sentence

    def __init__(self) -> None:
        self.held = np.zeros(0, dtype=np.float32)   # silence at the end of what we've seen so far
        self.threshold = None
        self.started = False

    def _rms(self, x: np.ndarray) -> np.ndarray:
        n = len(x) // self.WINDOW
        if n == 0:
            return np.zeros(0, dtype=np.float32)
        w = x[: n * self.WINDOW].reshape(n, self.WINDOW)
        return np.sqrt(np.mean(w * w, axis=1))

    def push(self, chunk: np.ndarray) -> np.ndarray:
        """Returns the audio that can be played now."""
        if not self.started and self.threshold is None:
            floor = self._rms(chunk[self.SKIP * self.WINDOW: 8 * self.WINDOW])
            base = float(np.median(floor)) if len(floor) else 0.0
            self.threshold = max(self.MIN_THRESHOLD, base * self.ABOVE_FLOOR)
            chunk = chunk[self.SKIP * self.WINDOW:]
        x = np.concatenate([self.held, chunk]) if len(self.held) else chunk
        loud = np.flatnonzero(self._rms(x) > self.threshold)
        if not self.started:
            if len(loud) == 0:
                self.held = x[-self.LEAD_IN:]
                return x[:0]
            self.started = True
            x = x[max(0, loud[0] * self.WINDOW - self.LEAD_IN):]
            loud = np.flatnonzero(self._rms(x) > self.threshold)
        if len(loud) == 0:
            self.held = x
            return x[:0]
        cut = (loud[-1] + 1) * self.WINDOW
        self.held = x[cut:]
        return x[:cut]

    def finish(self) -> np.ndarray:
        return self.held[: self.TAIL] if self.started else self.held[:0]


def main() -> None:
    root = sys.argv[1]
    threads = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    # Performance cores only: with the efficiency cores too, it's slower (measured on an M3).
    ptts.set_num_threads(max(1, threads))
    tts = ptts.TTS(root, device="cpu", quant="q8_0", lang="en")
    voices = set(tts.voices)
    fallback = "Easton" if "Easton" in voices else ("default" if "default" in voices else sorted(voices)[0])
    out = sys.stdout.buffer
    out_lock = threading.Lock()

    def send(header: dict, data: bytes = b"") -> None:
        with out_lock:
            out.write((json.dumps(header) + "\n").encode())
            if data:
                out.write(data)
            out.flush()

    # Warm up the same streaming path real sentences take: the first one after loading is slower.
    for _ in range(3):
        with tts.stream("Hi there, how are you?", voice=fallback) as audio:
            for _chunk in audio:
                pass
    send({"ready": True, "voices": sorted(voices), "sr": tts.sample_rate})

    jobs: "queue.Queue[dict | None]" = queue.Queue()
    cancelled_upto = 0     # requests with an id at or below this are dropped
    lock = threading.Lock()

    def is_cancelled(rid) -> bool:
        with lock:
            return isinstance(rid, int) and rid <= cancelled_upto

    def reader() -> None:
        nonlocal cancelled_upto
        for line in sys.stdin:
            try:
                req = json.loads(line)
            except ValueError:
                continue
            if "cancel" in req:
                with lock:
                    cancelled_upto = max(cancelled_upto, int(req["cancel"]))
            else:
                jobs.put(req)
        jobs.put(None)   # Poinky closed our input: finish up

    threading.Thread(target=reader, daemon=True).start()

    current_delta = None
    while True:
        req = jobs.get()
        if req is None:
            break
        rid = req.get("id")
        if is_cancelled(rid):
            continue
        text = str(req.get("text", "")).strip()
        voice = req.get("voice") if req.get("voice") in voices else fallback
        try:
            if not text:
                raise ValueError("empty text")
            delta = duration_delta(float(req.get("speed", 1.0)))
            if delta != current_delta:
                tts.set_conditions({"duration_delta": delta})
                current_delta = delta
            t0 = time.perf_counter()
            first = None
            trim = SilenceTrimmer()
            with tts.stream(text, voice=voice) as audio:
                for chunk in audio:
                    if is_cancelled(rid):
                        break      # leaving the block stops generation
                    data = np.ascontiguousarray(trim.push(np.asarray(chunk, dtype=np.float32)), dtype="<f4").tobytes()
                    if data:
                        if first is None:
                            first = time.perf_counter() - t0
                        send({"id": rid, "bytes": len(data)}, data)
            tail = np.ascontiguousarray(trim.finish(), dtype="<f4").tobytes()
            if tail and not is_cancelled(rid):
                send({"id": rid, "bytes": len(tail)}, tail)
            if not is_cancelled(rid):
                send({"id": rid, "end": True,
                      "ttfa_ms": round((first or 0) * 1000, 1),
                      "ms": round((time.perf_counter() - t0) * 1000, 1)})
        except Exception as e:  # report and keep serving
            send({"id": rid, "error": str(e)})


if __name__ == "__main__":
    main()
