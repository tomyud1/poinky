#!/usr/bin/env python3
"""tools/e2e/gaps.py <rundir> [min_secs=0.8]: silences in what was played (speech.f32 from POINKY_SPEECH_WAV),
with the words just before them (speech.log, in order), so long pauses mid-answer stand out.
Silences between questions are in there too (the player ran dry while idle)."""
import sys, struct, array
d = sys.argv[1]; th = float(sys.argv[2]) if len(sys.argv) > 2 else 0.8
rate = int(open(d + "/speech.f32.rate").read())
a = array.array("f"); a.frombytes(open(d + "/speech.f32", "rb").read())
win = rate // 50; quiet = 0; t = 0; last_loud = 0; segs = []
for i in range(0, len(a), win):
    w = a[i:i+win]; loud = max(abs(x) for x in w) > 0.01 if w else False
    if loud:
        if (i - last_loud) / rate >= th and last_loud: segs.append((last_loud / rate, (i - last_loud) / rate))
        last_loud = i
print(f"{len(a)/rate:.1f} s played; silences >= {th}s:")
for s, l in segs: print(f"  at {s:6.1f}s  {l:5.2f}s")
