#!/usr/bin/env python3
"""Stands in for explainer/pipeline.py in tests: replays a finished video's progress, spending no tokens.

  POINKY_VIDEO_CMD=tools/fake-video.py POINKY_FAKE_VIDEO=<a finished video folder> [POINKY_FAKE_SPEED=4] Poinky --video "topic"

It takes the pipeline's arguments (--out, --watch-stdin…) and writes <out>/manifest.json the way the
pipeline does: the narration when the storyboard header arrived, each scene when it became playable,
and the forecast, all at the recorded times divided by POINKY_FAKE_SPEED. It stops when stdin closes.
"""
import json
import os
import shutil
import sys
import threading
import time

args = sys.argv[1:]
out = args[args.index('--out') + 1]
src = os.environ['POINKY_FAKE_VIDEO']
speed = float(os.environ.get('POINKY_FAKE_SPEED', '4'))
os.makedirs(os.path.join(out, 'scenes'), exist_ok=True)

if '--watch-stdin' in args:
    def wait():
        while sys.stdin.read(4096):
            pass
        os._exit(1)
    threading.Thread(target=wait, daemon=True).start()

final = json.load(open(os.path.join(src, 'manifest.json')))
stats = json.load(open(os.path.join(src, 'stats.json')))
header = next((e['t'] for e in stats['events'] if 'header written' in e['msg']), 50.0)
ready = {k: v.get('ready_at', 0) for k, v in stats['scenes'].items()}
ideal = stats.get('ideal_start_s') or max(ready.values())
t0 = time.time()
log = open(os.path.join(out, 'log.txt'), 'w')


def write(m):
    tmp = os.path.join(out, 'manifest.json.tmp')
    json.dump(m, open(tmp, 'w'))
    os.replace(tmp, os.path.join(out, 'manifest.json'))


def at(t):   # sleep until recorded time t (seconds since the run started)
    d = t0 + t / speed - time.time()
    if d > 0:
        time.sleep(d)


write({'status': 'storyboard', 'scenes': []})
at(header)
for f in ('voice.wav', 'storyboard.json'):
    shutil.copy(os.path.join(src, f), os.path.join(out, f))
m = {k: final[k] for k in ('title', 'audio', 'audioVersion', 'duration', 'sentences', 'words') if k in final}
m['status'] = 'scenes'
m['scenes'] = [{k: v for k, v in s.items() if k not in ('file', 'state')} for s in final['scenes']]
m['forecast'] = {'playAt': t0 + (ideal + 4) / speed, 'at': time.time(), 'lead': 70}
write(m)
log.write(f'header at {header / speed:.1f}s\n'); log.flush()
for sid, t in sorted(ready.items(), key=lambda x: x[1]):
    at(t)
    s = next(x for x in m['scenes'] if x['id'] == sid)
    f = next(x['file'] for x in final['scenes'] if x['id'] == sid)
    shutil.copy(os.path.join(src, f), os.path.join(out, f))
    s['file'] = f
    s['state'] = 'ready'
    write(m)
    log.write(f'{sid} ready at {t / speed:.1f}s\n'); log.flush()
m['status'] = 'done'
write(m)
log.write('done\n')
