#!/usr/bin/env python3
"""Make a code-drawn explainer video, scene by scene, streaming as scenes become ready.

  python3 explainer/pipeline.py --script narration.txt --out explainer/runs/test
  python3 explainer/pipeline.py --topic "how does a heat pump work" --out explainer/runs/heatpump

Steps (times are logged to <out>/log.txt and <out>/stats.json):
  1. storyboard (Claude) and, when the narration is given, the voice (Phonon) + word timings, at once
  2. every scene is written in parallel by its own Claude call
  3. each scene is rendered into a sheet of frames (headless Chrome) and reviewed by Claude, which
     looks at the frames and fixes the code (--reviews rounds)
  4. each finished scene is published to <out>/manifest.json; explainer/player.html?dir=<out> plays
     the video and waits ("cooking") only if it reaches a scene that isn't ready yet
"""
import argparse
import difflib
import json
import os
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import wave
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
PHONON = os.path.expanduser('~/Library/Application Support/Poinky/phonon')
PHONON_SERVER = os.path.join(HERE, '..', 'phonon', 'phonon_server.py')
CONFIG = os.path.expanduser('~/Library/Application Support/Poinky/config.json')
GAP = 0.32        # silence between sentences (s)
LEAD = 0.45       # silence before the first sentence (s)
TAIL = 0.9        # the picture holds this long after the last word
# Forecast (when can playback start without stalling?). First guesses, replaced by measurements:
EST_LEAD = 70.0   # from a scene's storyboard line to its first playable version (s), before any history
# measured leads from earlier runs (the forecast plans for the slow case); the app keeps its own
HISTORY = os.environ.get('EXPLAINER_HISTORY') or os.path.join(HERE, 'runs', 'history.json')
EST_LINE = 9.0    # storyboard time per scene line (s)
EST_SENTS = 1.3   # sentences per scene
SAFETY = 4.0      # extra seconds before starting

T0 = time.time()
lock = threading.Lock()


def now():
    return round(time.time() - T0, 1)


class Run:
    def __init__(self, out):
        self.out = out
        os.makedirs(os.path.join(out, 'scenes'), exist_ok=True)
        os.makedirs(os.path.join(out, 'work'), exist_ok=True)
        self.logf = open(os.path.join(out, 'log.txt'), 'w')
        self.stats = {'events': [], 'cost_usd': 0.0, 'cost_note': 'API-price estimate from Claude Code; not billed on a subscription', 'scenes': {}}
        self.manifest = {'status': 'starting', 'scenes': []}
        self.eta = {}            # scene id -> {line, sents, first, ready} (epoch seconds)
        self.line_times = []     # when each scene line of the storyboard arrived
        self.leads = []          # measured: line → first playable version (s)
        self.board_done = False
        try:
            self.history = json.load(open(HISTORY))[-40:]
        except Exception:
            self.history = []

    def log(self, msg, **kv):
        line = f'[{now():6.1f}s] {msg}'
        with lock:
            print(line, flush=True)
            self.logf.write(line + '\n'); self.logf.flush()
            self.stats['events'].append({'t': now(), 'msg': msg, **kv})

    def write_manifest(self):
        with lock:
            p = os.path.join(self.out, 'manifest.json')
            tmp = p + '.tmp'
            with open(tmp, 'w') as f:
                json.dump(self.manifest, f, indent=1)
            os.replace(tmp, p)

    def save_stats(self):
        with lock:
            with open(os.path.join(self.out, 'stats.json'), 'w') as f:
                json.dump(self.stats, f, indent=1)


# ---------------------------------------------------------------- Claude

def claude(run, label, system, user, model, tools='', effort=None, cwd=None, timeout=1500):
    cmd = ['claude', '-p', '--model', model, '--output-format', 'json', '--setting-sources', '',
           '--strict-mcp-config', '--no-session-persistence', '--system-prompt', system, '--tools', tools]
    if tools:
        cmd += ['--allowedTools', tools]
    if effort:
        cmd += ['--effort', effort]
    t = time.time()
    r = subprocess.run(cmd, input=user, capture_output=True, text=True, cwd=cwd or run.out, timeout=timeout)
    try:
        d = json.loads(r.stdout)
    except Exception:
        raise RuntimeError(f'{label}: claude failed: {r.stderr[-800:] or r.stdout[-800:]}')
    cost = d.get('total_cost_usd') or 0
    with lock:
        run.stats['cost_usd'] += cost
    if d.get('is_error'):
        raise RuntimeError(f'{label}: {d.get("result")}')
    run.log(f'{label}: claude done in {time.time() - t:.1f}s (~${cost:.3f} at API prices)')
    return d.get('result') or ''


def claude_lines(run, label, system, user, model, on_line, effort=None):
    """Like claude(), but streams the reply and calls on_line(text) for every finished line."""
    cmd = ['claude', '-p', '--model', model, '--output-format', 'stream-json', '--verbose', '--include-partial-messages',
           '--setting-sources', '', '--strict-mcp-config', '--no-session-persistence', '--system-prompt', system, '--tools', '']
    if effort:
        cmd += ['--effort', effort]
    t = time.time()
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=run.out)
    p.stdin.write(user); p.stdin.close()
    buf, full, result = '', '', None
    for raw in p.stdout:
        try:
            e = json.loads(raw)
        except Exception:
            continue
        if e.get('type') == 'stream_event':
            d = e['event'].get('delta') or {}
            if d.get('type') == 'text_delta':
                buf += d['text']; full += d['text']
                while '\n' in buf:
                    line, buf = buf.split('\n', 1)
                    if line.strip():
                        on_line(line.strip())
        elif e.get('type') == 'result':
            result = e
    p.wait()
    if buf.strip():
        on_line(buf.strip())
    if not result or result.get('is_error'):
        raise RuntimeError(f'{label}: claude failed: {(result or {}).get("result") or p.stderr.read()[-800:]}')
    cost = result.get('total_cost_usd') or 0
    with lock:
        run.stats['cost_usd'] += cost
    run.log(f'{label}: claude done in {time.time() - t:.1f}s (~${cost:.3f} at API prices)')
    return full


def extract_json(s):
    s = s.strip()
    s = re.sub(r'^```(?:json)?\s*|\s*```$', '', s)
    a, b = s.find('{'), s.rfind('}')
    return json.loads(s[a:b + 1])


def extract_code(s):
    m = re.findall(r'```(?:js|javascript)?\s*\n(.*?)```', s, re.S)
    return max(m, key=len) if m else None


# ---------------------------------------------------------------- Voice

def voice_settings():
    try:
        c = json.load(open(CONFIG))
        return c.get('phononVoice') or 'Easton', float(c.get('voiceSpeed') or 1.0)
    except Exception:
        return 'Easton', 1.0


def synthesize(run, sentences, voice, speed):
    """Speak every sentence with Phonon (Poinky's local voice) into one WAV; return sentence timings."""
    py = os.path.join(PHONON, 'venv', 'bin', 'python')
    p = subprocess.Popen([py, '-I', PHONON_SERVER, os.path.join(PHONON, 'model'), '4'],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out = p.stdout

    def header():
        line = out.readline()
        if not line:
            raise RuntimeError('Phonon stopped')
        return json.loads(line)

    h = header()
    while 'ready' not in h:
        h = header()
    sr = h.get('sr', 24000)
    for i, s in enumerate(sentences):
        p.stdin.write((json.dumps({'id': i + 1, 'text': s, 'voice': voice, 'speed': speed}) + '\n').encode())
    p.stdin.flush()
    audio = {i: [] for i in range(len(sentences))}
    done = 0
    while done < len(sentences):
        h = header()
        i = h.get('id', 0) - 1
        if 'bytes' in h:
            audio[i].append(out.read(h['bytes']))
        elif h.get('end') or h.get('error'):
            if h.get('error'):
                run.log(f'voice error on sentence {i}: {h["error"]}')
            done += 1
    p.stdin.close(); p.wait(timeout=10)

    pcm = bytearray()
    timings = []
    def silence(sec):
        pcm.extend(b'\x00\x00' * int(sec * sr))
    silence(LEAD)
    for i, s in enumerate(sentences):
        raw = b''.join(audio[i])
        n = len(raw) // 4
        floats = struct.unpack(f'<{n}f', raw[:n * 4])
        start = len(pcm) / 2 / sr
        pcm.extend(struct.pack(f'<{n}h', *[max(-32767, min(32767, int(x * 32767))) for x in floats]))
        timings.append({'i': i, 'text': s, 'start': round(start, 3), 'end': round(len(pcm) / 2 / sr, 3)})
        silence(GAP)
    path = os.path.join(run.out, 'voice.wav')
    with wave.open(path, 'wb') as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr); w.writeframes(bytes(pcm))
    return timings, len(pcm) / 2 / sr


def norm(w):
    return re.sub(r"[^a-z0-9']", '', w.lower().replace('’', "'"))


_tool_lock = threading.Lock()


def swift_tool(name):
    """Our small Swift tools (word timing, frame rendering), compiled on first use (Command Line Tools)."""
    tool = os.path.join(os.environ.get('EXPLAINER_BUILD') or os.path.join(HERE, '.build'), name)
    src = os.path.join(HERE, name + '.swift')
    with _tool_lock:   # scenes render in parallel: compile once
        if not os.path.exists(tool) or os.path.getmtime(tool) < os.path.getmtime(src):
            os.makedirs(os.path.dirname(tool), exist_ok=True)
            subprocess.run(['swiftc', '-O', '-parse-as-library', '-o', tool + '.tmp', src], check=True, capture_output=True)
            os.replace(tool + '.tmp', tool)
    return tool


def align_words(run, timings):
    """Time every word of the narration (Apple's transcriber on our own audio, matched to the text)."""
    tool = swift_tool('align')
    r = subprocess.run([tool, os.path.join(run.out, 'voice.wav')], capture_output=True, text=True, timeout=300)
    heard = json.loads(r.stdout or '[]')
    tokens = [(s['i'], k, w) for s in timings for k, w in enumerate(s['text'].split())]
    a = [norm(w) for _, _, w in tokens]
    b = [norm(h['w']) for h in heard]
    times = [None] * len(tokens)
    for blk in difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks():
        for j in range(blk.size):
            times[blk.a + j] = heard[blk.b + j]['start']
    words = []
    for s in timings:   # fill the gaps by spreading unmatched words between their known neighbours
        idx = [n for n, tk in enumerate(tokens) if tk[0] == s['i']]
        known = [(n, times[n]) for n in idx if times[n] is not None and s['start'] - 0.3 <= times[n] <= s['end'] + 0.3]
        anchors = [(idx[0] - 1, s['start'])] + known + [(idx[-1] + 1, s['end'])]
        for n in idx:
            if times[n] is None or not (s['start'] - 0.3 <= times[n] <= s['end'] + 0.3):
                lo = max((x for x in anchors if x[0] < n), key=lambda x: x[0])
                hi = min((x for x in anchors if x[0] > n), key=lambda x: x[0])
                times[n] = lo[1] + (hi[1] - lo[1]) * (n - lo[0]) / (hi[0] - lo[0])
            words.append({'s': s['i'], 'k': tokens[n][1], 'w': tokens[n][2], 'start': round(times[n], 3)})
    run.log(f'words timed: {len([t for t in times if t is not None])} ({len(heard)} heard)')
    return words


# ---------------------------------------------------------------- Timeline

def place_scene(sc, timings, words, duration):
    """Put one scene on the audio timeline (from its own sentences, so it doesn't wait for the others)
    and resolve its cues to scene-local times."""
    first, last = min(sc['sentences']), max(sc['sentences'])
    start = 0.0 if first == 0 else round((timings[first - 1]['end'] + timings[first]['start']) / 2 - 0.1, 3)
    end = (round(duration + TAIL, 3) if last >= len(timings) - 1
           else round((timings[last]['end'] + timings[last + 1]['start']) / 2 - 0.1, 3))
    s = {'id': sc['id'], 'start': start, 'end': end, 'dur': round(end - start, 3), 'state': 'cooking'}
    cues = {}
    for b in sc.get('beats', []):
        si = b.get('sentence', first)
        ws = [w for w in words if w['s'] == si]
        target, nth = norm(b.get('word', '')), b.get('nth', 1)
        hits = [w for w in ws if norm(w['w']) == target]
        if len(hits) < nth:
            close = difflib.get_close_matches(target, [norm(w['w']) for w in ws], n=1, cutoff=0.6)
            hits = [w for w in ws if close and norm(w['w']) == close[0]]
        t = hits[min(nth, len(hits)) - 1]['start'] if hits else timings[si]['start']
        cues[b['cue']] = round(max(0.0, t - start), 3)
    s['cues'] = cues
    return s


def scene_brief(board, sc, placed, timings):
    """What one animator needs: the whole storyboard, their scene, and its exact timing."""
    lines = [f'Sentence {t["i"]} is spoken from {t["start"] - placed["start"]:.2f}s to {t["end"] - placed["start"]:.2f}s (scene time): "{t["text"]}"'
             for t in timings if t['i'] in sc['sentences']]
    cues = '\n'.join(f'- g.cue("{k}") = {v:.2f}s' for k, v in placed['cues'].items())
    return (f'The full storyboard (for context and props):\n{json.dumps(board, indent=1)}\n\n'
            f'YOUR SCENE: {sc["id"]}\n{json.dumps(sc, indent=1)}\n\n'
            f'Timing: the scene lasts g.dur = {placed["dur"]:.2f}s.\n' + '\n'.join(lines) +
            f'\nCues (scene time, already measured from the voice):\n{cues}\n\n'
            f"Write Explainer.scene('{sc['id']}', function (g) {{ … }}).")


def sheet_times(placed):
    """Moments to check: the first frame, just after every beat lands, and the last frame (video time)."""
    s, e = placed['start'], placed['end']
    ts = {s + 0.05, e - 0.05}
    for c in placed['cues'].values():
        ts.add(min(e - 0.05, s + c + 0.6))
    ts = sorted(ts)
    while len(ts) < 6:   # fill long gaps
        gaps = [(ts[i + 1] - ts[i], i) for i in range(len(ts) - 1)]
        g, i = max(gaps)
        ts.insert(i + 1, (ts[i] + ts[i + 1]) / 2)
    if len(ts) > 12:
        ts = [ts[round(k * (len(ts) - 1) / 11)] for k in range(12)]
    return ','.join(f'{t:.2f}' for t in ts)


CHROME = os.environ.get('CHROME') or '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
# Frames are checked with macOS's own web engine (render.swift), the one that plays the videos. Headless
# Chrome (render.mjs) is only a fallback; with neither, scenes are published unchecked (no review).
CAN_RENDER = bool(shutil.which('swiftc')) or (bool(shutil.which('node')) and os.path.exists(CHROME))


def render_sheet(run, sid, file, times, png):
    args = [run.out, png, times, f'scenes={sid}', f'file_{sid}={file}', 'cols=3', 'w=560']
    try:
        cmd = [swift_tool('render')] + args
    except Exception as e:
        run.log(f'{sid}: could not build the frame renderer ({e}); trying Chrome')
        cmd = ['node', os.path.join(HERE, 'render.mjs')] + args
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=180, env={**os.environ, 'EXPLAINER_HOME': HERE})
    try:
        d = json.loads(r.stdout.strip().splitlines()[-1])
        return d.get('errors', []), d.get('lint', [])
    except Exception:
        return [f'render failed: {r.stderr[-400:]}'], []


# ---------------------------------------------------------------- Scenes

def make_scene(run, args, board, sc, placed, timings, prompts):
    """Write one scene, publish its first clean render at once, then review it and swap in the fix."""
    sid = sc['id']
    st = run.stats['scenes'].setdefault(sid, {})
    t0 = time.time()
    st['started_at'] = now()
    reply = claude(run, f'{sid} write', prompts['scene'], scene_brief(board, sc, placed, timings), args.model, effort=args.effort)
    code = extract_code(reply) or reply
    st['write_s'] = round(time.time() - t0, 1)

    def publish(file, state):
        with lock:
            first = 'ready_at' not in st
            if first and sid in run.eta:
                run.eta[sid]['ready'] = time.time()
                run.leads.append(time.time() - run.eta[sid]['line'])
            placed['file'] = file
            placed['state'] = state
            st.setdefault('ready_at', now())
            st['final_file'] = file
        run.write_manifest()
        run.log(f'{sid} {"READY" if first else "UPDATED"} ({file})')

    version = 1
    for rnd in range(args.reviews + 1):
        code = re.sub(r"Explainer\.scene\(\s*['\"][^'\"]*['\"]", f"Explainer.scene('{sid}'", code, count=1)
        file = f'scenes/{sid}.v{version}.js'
        with open(os.path.join(run.out, file), 'w') as f:
            f.write(code)
        png = os.path.join(run.out, 'work', f'{sid}.v{version}.png')
        if not CAN_RENDER:
            publish(file, 'ready')
            break
        errors, lint = render_sheet(run, sid, file, sheet_times(placed), png)
        run.log(f'{sid} v{version} rendered' + (f'; errors: {errors}' if errors else '') + (f'; {len(lint)} layout problems' if lint else ''))
        last = rnd == args.reviews
        if not errors or 'file' not in placed:   # a clean render replaces what's published (a broken one only if nothing is)
            publish(file, 'ready' if last else 'improving')
        if last:
            break
        nxt = next((x for x in board['scenes'] if x['sentences'] and min(x['sentences']) == max(sc['sentences']) + 1), None)
        msg = (f'Storyboard for this scene:\n{json.dumps(sc, indent=1)}\n\n'
               f'Cue times (scene time): {json.dumps(placed["cues"])}; the scene starts at {placed["start"]:.2f}s of the video and lasts {placed["dur"]:.2f}s.\n\n'
               + (f'The next scene starts with: {nxt["starts_with"]}\n\n' if nxt else '') +
               f'Errors from rendering (must fix): {json.dumps(errors) if errors else "none"}\n\n'
               f'Layout problems measured from the drawn text, every 0.25 s (must fix): {json.dumps(lint, indent=0) if lint else "none"}\n\n'
               f'The frames: {png}\n\nThe code:\n```js\n{code}\n```\n\n'
               f'The drawing kit, for reference:\n{prompts["scene"]}')
        t1 = time.time()
        reply = claude(run, f'{sid} review {rnd + 1}', prompts['review'], msg, args.model, tools='Read', effort=args.effort)
        st.setdefault('review_s', []).append(round(time.time() - t1, 1))
        fixed = extract_code(reply)
        if not fixed or reply.strip().upper().startswith('OK'):
            run.log(f'{sid} review {rnd + 1}: OK')
            break
        run.log(f'{sid} review {rnd + 1}: fixed')
        code = fixed
        version += 1
    with lock:
        placed['state'] = 'ready'
        st['final_at'] = now()
        st['versions'] = version
    run.write_manifest()


def forecast(run):
    """Predict when playback can start and play straight through: every scene (written or not yet
    written) must be ready by the time the video reaches it. Uses measured speeds once known."""
    tm = run.manifest.get('sentences')
    if not tm or not run.eta:
        return None
    t = time.time()
    known = sorted(run.history + run.leads)
    slow = known[min(len(known) - 1, int(0.9 * len(known)))] if known else EST_LEAD   # 90th percentile
    lead = max(slow, 1.25 * sum(run.leads) / len(run.leads) if run.leads else 0,
               EST_LEAD if len(known) < 6 else 0)   # with little data, the first guess is a floor
    def vstart(i):
        return 0.0 if i == 0 else (tm[i - 1]['end'] + tm[i]['start']) / 2 - 0.1
    need = []
    for e in list(run.eta.values()):
        # a scene past its estimate is usually well behind, so give it a quarter of a lead more
        eta = e['ready'] or max(e['line'] + lead, t + 0.25 * lead)
        need.append(eta - vstart(e['first']))
    if not run.board_done:   # scenes the storyboard hasn't written yet
        covered = {i for e in run.eta.values() for i in e['sents']}
        rest = [i for i in range(len(tm)) if i not in covered]
        lt = run.line_times
        L = (lt[-1] - lt[0]) / (len(lt) - 1) if len(lt) >= 2 else EST_LINE
        r = len(covered) / len(run.eta) if run.eta else EST_SENTS
        n = -(-len(rest) // max(1, round(r))) if rest else 0
        for j in range(1, n + 1):
            i = rest[min(len(rest) - 1, int((j - 1) * r))]
            line_at = max(lt[-1] + j * L, t + (j - 0.5) * L)
            need.append(line_at + lead - vstart(i))
    return {'playAt': round(max(need) + SAFETY, 2), 'at': round(t, 2), 'lead': round(lead, 1)}


def forecast_loop(run, stop):
    last = None
    while not stop.is_set():
        f = forecast(run)
        if f:
            with lock:
                run.manifest['forecast'] = f
                run.stats.setdefault('forecasts', []).append({'t': now(), 'playAt': round(f['playAt'] - T0, 1)})
            if last is None or abs(f['playAt'] - last) > 3:
                run.log(f'forecast: playback can start at {f["playAt"] - T0:.0f}s (lead {f["lead"]}s)')
                last = f['playAt']
            run.write_manifest()
        stop.wait(1.0)


def parse_line(line):
    """One JSON object from a storyboard line (tolerates code fences, list brackets and trailing commas)."""
    line = line.strip().strip('`').strip()
    if line.startswith('json'):
        line = line[4:].strip()
    line = line.lstrip('[').rstrip(',').rstrip(']').rstrip(',').strip()
    if not line.startswith('{'):
        return None
    try:
        return json.loads(line)
    except Exception:
        return json.loads(re.sub(r',\s*([}\]])', r'\1', line))


def research(run, topic, model):
    """Checks the facts on the web before the narration is written (the models' memory can be out of date).
    Kept in research.md (the app shows its sources when you ask). Gives up after 2.5 minutes."""
    run.manifest['status'] = 'research'
    run.write_manifest()
    run.log('research started')
    t = time.time()
    today = time.strftime('%B %-d, %Y')
    try:
        facts = claude(run, 'research', open(os.path.join(HERE, 'prompts', 'research.md')).read(),
                       f'Today is {today}.\nThe video: {topic}', model, tools='WebSearch,WebFetch', timeout=150).strip()
    except Exception as e:
        run.log(f'research failed ({str(e)[:200]}); writing from memory')
        return None
    with open(os.path.join(run.out, 'research.md'), 'w') as f:
        f.write(facts + '\n')
    run.stats['research_s'] = round(time.time() - t, 1)
    run.log(f'research: {len(facts.splitlines())} lines in {time.time() - t:.0f}s')
    return facts


def watch_stdin():
    """Run as the app's helper: we lead our own process group, so cancelling (closing our stdin, or the
    app quitting) stops every claude, node and voice process we started, not just this one."""
    try:
        os.setpgid(0, 0)
    except OSError:
        pass

    stopping = []

    def stop(*_):   # from the signal handler (main thread) or the stdin watcher (its own thread)
        if stopping:
            return   # our own SIGTERM from killpg below
        stopping.append(1)
        try:
            os.killpg(0, signal.SIGTERM)
        except OSError:
            pass
        os._exit(1)
    signal.signal(signal.SIGTERM, stop)

    def wait():
        try:
            while sys.stdin.read(4096):
                pass
        except Exception:
            pass
        stop()
    threading.Thread(target=wait, daemon=True).start()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--script', help='narration, one sentence per line')
    ap.add_argument('--topic', help='or: a question/topic; the director writes the narration')
    ap.add_argument('--out', required=True)
    ap.add_argument('--model', default='claude-opus-5-5')
    ap.add_argument('--effort', default=None)
    ap.add_argument('--reviews', type=int, default=1, help='look-and-fix rounds per scene')
    ap.add_argument('--research-model', default='claude-sonnet-5-5', help='checks the facts with web search first (topic mode)')
    ap.add_argument('--no-research', action='store_true', help='write from memory only')
    ap.add_argument('--watch-stdin', action='store_true',
                    help='stop everything (this and every claude/voice process it started) when stdin closes')
    args = ap.parse_args()
    if args.watch_stdin:
        watch_stdin()
    run = Run(os.path.abspath(args.out))
    prompts = {k: open(os.path.join(HERE, 'prompts', f'{k}.md')).read() for k in ('storyboard', 'scene', 'review', 'research')}
    voice, speed = voice_settings()
    run.stats.update({'model': args.model, 'effort': args.effort, 'reviews': args.reviews, 'voice': voice})

    sentences = None
    if args.script:
        sentences = [l.strip() for l in open(args.script) if l.strip()]
        ask = 'Narration (numbered sentences):\n' + '\n'.join(f'{i}. {s}' for i, s in enumerate(sentences))
    else:
        ask = f'Topic: {args.topic}\nWrite the narration first (in the header\'s "sentences"), then the scenes.'
        facts = None if args.no_research else research(run, args.topic, args.research_model)
        if facts:
            ask += ('\n\nFacts checked with a web search today (use these numbers and dates exactly; leave out any number '
                    'that isn\'t here or that you aren\'t sure of, rather than guessing):\n' + facts)
    run.log('storyboard + voice started')
    run.manifest['status'] = 'storyboard'
    run.write_manifest()

    voice_done = threading.Event()
    voice_result = {}
    def do_voice(sents):
        t = time.time()
        timings, duration = synthesize(run, sents, voice, speed)
        run.log(f'voice done in {time.time() - t:.1f}s ({duration:.1f}s of audio)')
        t = time.time()
        words = align_words(run, timings)
        run.log(f'word timing done in {time.time() - t:.1f}s')
        voice_result.update(timings=timings, duration=duration, words=words)
        with lock:
            run.manifest.update({'audio': 'voice.wav', 'audioVersion': int(time.time()), 'duration': round(duration + TAIL, 3),
                                 'sentences': timings, 'words': words})
        run.write_manifest()
        voice_done.set()

    board = {'scenes': []}
    pool = ThreadPoolExecutor(10)
    futs = []

    def start_scene(sc):
        voice_done.wait()
        placed = place_scene(sc, voice_result['timings'], voice_result['words'], voice_result['duration'])
        with lock:
            run.manifest['scenes'].append(placed)
            run.manifest['scenes'].sort(key=lambda x: x['start'])
        run.write_manifest()
        run.log(f'{sc["id"]} placed at {placed["start"]:.1f}-{placed["end"]:.1f}s; writing')
        snapshot = {**board, 'scenes': list(board['scenes'])}   # the storyboard as far as it's written
        make_scene(run, args, snapshot, sc, placed, voice_result['timings'], prompts)

    if sentences:
        futs.append(pool.submit(do_voice, sentences))

    def on_line(line):
        try:
            obj = parse_line(line)
        except Exception as e:
            run.log(f'storyboard: could not read a line ({e}): {line[:120]}')
            return
        if not obj:
            return
        if 'beats' in obj and 'id' in obj:
            board['scenes'].append(obj)
            with lock:
                run.line_times.append(time.time())
                run.eta[obj['id']] = {'line': time.time(), 'sents': list(obj.get('sentences') or [0]),
                                      'first': min(obj.get('sentences') or [0]), 'ready': None}
            run.log(f'storyboard: scene {obj["id"]} written (sentences {obj.get("sentences")})')
            futs.append(pool.submit(start_scene, obj))
        else:
            board.update(obj)
            run.log(f'storyboard: header written ({len(obj.get("props", []))} props)')
            with lock:
                run.manifest['title'] = obj.get('title')
            if not sentences and obj.get('sentences'):
                futs.append(pool.submit(do_voice, obj['sentences']))

    stop = threading.Event()
    threading.Thread(target=forecast_loop, args=(run, stop), daemon=True).start()
    claude_lines(run, 'storyboard', prompts['storyboard'], ask, args.model, on_line, effort=args.effort)
    run.board_done = True
    with open(os.path.join(run.out, 'storyboard.json'), 'w') as f:
        json.dump(board, f, indent=1)
    run.log(f'storyboard: {len(board["scenes"])} scenes')
    while any(not f.done() for f in futs):   # scenes started from the stream may still be adding futures
        for f in list(futs):
            try:
                f.result()
            except Exception as e:
                run.log(f'failed: {e}')
    pool.shutdown()
    covered = sorted(i for sc in board['scenes'] for i in sc['sentences'])
    if sentences and covered != list(range(len(sentences))):
        run.log(f'warning: the scenes cover sentences {covered}, not all {len(sentences)}')
    stop.set()
    run.manifest['status'] = 'done'
    run.write_manifest()
    # The real earliest stall-free start, to judge the forecast: every scene ready when the video reaches it.
    tm = run.manifest.get('sentences') or []
    ideal = max(((e['ready'] or time.time()) - T0 - (0.0 if e['first'] == 0 else (tm[e['first'] - 1]['end'] + tm[e['first']]['start']) / 2 - 0.1))
                for e in run.eta.values()) if run.eta else None
    fc = run.stats.get('forecasts', [])
    first_ready = min((e['ready'] for e in run.eta.values() if e['ready']), default=None)
    at_first = next((f['playAt'] for f in fc if first_ready and f['t'] >= first_ready - T0), None)
    run.stats.update({'ideal_start_s': ideal and round(ideal, 1), 'forecast_at_first_ready_s': at_first})
    try:
        os.makedirs(os.path.dirname(HISTORY), exist_ok=True)
        json.dump((run.history + [round(x, 1) for x in run.leads])[-40:], open(HISTORY, 'w'))
    except Exception:
        pass
    run.log(f'ideal stall-free start was {ideal:.1f}s; when the first scene was ready the forecast said {at_first}s')
    first_id = min(run.manifest['scenes'], key=lambda x: x['start'])['id'] if run.manifest['scenes'] else None
    first = run.stats['scenes'].get(first_id, {}).get('ready_at')
    run.stats.update({'first_scene_ready_s': first, 'all_ready_s': max((v.get('ready_at') or 0) for v in run.stats['scenes'].values()),
                      'all_final_s': now(), 'video_s': run.manifest.get('duration')})
    run.save_stats()
    run.log(f'done: first scene ready at {first}s, all scenes playable at {run.stats["all_ready_s"]}s, all reviewed at {now()}s; '
            f'video {run.manifest.get("duration")}s; usage ~${run.stats["cost_usd"]:.2f} at API prices (a subscription isn\'t billed this)')


if __name__ == '__main__':
    main()
