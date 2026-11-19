#!/usr/bin/env python3
"""The call loop with the fake brain (tools/fake-claude.py): no tokens, no mic.

Each scenario launches build/Poinky.app in a scratch support folder, asks typed questions (`--ask`), quits
(`--quit-after`), and checks the timeline and the speech log (what was captioned and said). It needs the
build's Screen Recording permission and an awake display, and it plays its audio at volume 0 (POINKY_MUTE=0 to hear it), so it's a
local check (not CI). A run that doesn't quit by itself is killed (by its own pid) and fails.

Usage: tools/test-call-loop.py [scenario …]     (no names: all of them; --list shows them)
"""
import json, os, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.environ.get("POINKY_APP") or os.path.join(ROOT, "build/Poinky.app")   # (another build: checks that fail before a fix)
EXE = os.path.join(APP, "Contents/MacOS/Poinky")
FAKE = os.path.join(ROOT, "tools/fake-claude.py")


def pids():
    out = subprocess.run(["pgrep", "-f", EXE], capture_output=True, text=True).stdout.split()
    return set(map(int, out))


def idle_secs():
    """Seconds since the last real keyboard or mouse input (HIDIdleTime)."""
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem", "-d", "4"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if '"HIDIdleTime"' in line:
            return int(line.split("=")[-1].strip()) / 1e9
    return 0.0


def wait_until_idle(need=20, limit=float(os.environ.get("POINKY_IDLE_WAIT", "600"))):
    """A scenario that takes the keyboard focus (its own window in front) waits until nobody is using the Mac,
    so it never catches someone's typing or clicks. False if that didn't happen within `limit` seconds."""
    t0 = time.time()
    while time.time() - t0 < limit:
        if idle_secs() >= need: return True
        time.sleep(2)
    return False


def run(name, asks, quit_after, env=None, args=()):
    env = dict(env or {})
    api = env.pop("_API", None)   # the API brain, against tools/fake-api.py on this port
    extra_config = json.loads(env.pop("_CONFIG", "{}"))   # more settings in config.json
    audio = env.pop("_AUDIO", None)   # really played (otherwise at volume 0: the WAV still records what was scheduled)
    server = None
    if api:
        server = subprocess.Popen([sys.executable, os.path.join(ROOT, "tools/fake-api.py"), api],
                                  env={**os.environ, **{k: v for k, v in env.items() if k.startswith("FAKE_API")}})
        time.sleep(0.5)
    d = tempfile.mkdtemp(prefix=f"poinky-loop-{name}-")
    os.makedirs(f"{d}/support"); os.makedirs(f"{d}/tl")
    with open(f"{d}/support/config.json", "w") as f:
        json.dump({"homeShown": True, "checkForUpdates": False, "sounds": False,
                   **({"brain": "api", "apiKey": "test"} if api else {}), **extra_config}, f)
    seed = env.pop("_SEED", None)   # files to put in the support folder first: {relative path: text}
    for rel, text in (seed() if callable(seed) else seed or {}).items():
        os.makedirs(os.path.dirname(f"{d}/support/{rel}"), exist_ok=True)
        with open(f"{d}/support/{rel}", "w") as f: f.write(text)
    extra = env.pop("_ARGS", [])
    e = {"POINKY_SUPPORT_DIR": f"{d}/support", "POINKY_TIMELINE_DIR": f"{d}/tl", "POINKY_MUTE": "1",
         "POINKY_SPEECH_LOG": f"{d}/speech.txt", "POINKY_CLAUDE_CMD": FAKE, "FAKE_CLAUDE_LOG": f"{d}/fake.txt",
         "POINKY_SPEECH_WAV": f"{d}/played.f32", "POINKY_OVERLAY_LOG": f"{d}/overlay.txt", "POINKY_TYPEBOX_LOG": f"{d}/box.txt"}
    e.update(env)
    # POINKY_TEST_SCREEN=<picture>: every screenshot is that picture (the test copy never sees the real screen).
    if os.environ.get("POINKY_TEST_SCREEN"): e["POINKY_TEST_SCREEN"] = os.environ["POINKY_TEST_SCREEN"]
    if audio: e.pop("POINKY_MUTE", None)
    if api: e["POINKY_API_URL"] = f"http://127.0.0.1:{api}/v1/messages"
    # (A scenario with a window of its own to act in launches in front, so that window can be the key one.)
    cmd = ["open", "-n"] if "--doer-target" in args else ["open", "-n", "-g"]
    for k, v in e.items(): cmd += ["--env", f"{k}={v}"]
    cmd += [APP, "--args"]
    for q in asks: cmd += ["--ask", q]
    cmd += [a.replace("{dir}", d) for a in args] + list(extra) + ["--quit-after", str(quit_after)]
    before = pids()
    subprocess.run(cmd, check=True)
    pid = None
    for _ in range(40):
        new = pids() - before
        if new: pid = new.pop(); break
        time.sleep(0.25)
    hung = False
    deadline = time.time() + quit_after + 12
    while pid and time.time() < deadline:
        try: os.kill(pid, 0)
        except ProcessLookupError: break
        time.sleep(0.5)
    else:
        if pid:
            hung = True
            os.kill(pid, 9)
    if server: server.terminate()
    events = []
    for fn in sorted(f for f in os.listdir(f"{d}/tl") if f.endswith(".jsonl")):
        for line in open(f"{d}/tl/{fn}"):
            events.append(json.loads(line))
    speech, spoken = [], []
    if os.path.exists(f"{d}/speech.txt"):
        rows = [l.split("\t") for l in open(f"{d}/speech.txt").read().splitlines() if l.strip()]
        speech = [r[0] for r in rows]
        spoken = [r[1] if len(r) > 1 else "" for r in rows]
    # What was played (float32): its length and its loudest sample (0.0 = digital silence).
    wav = {"secs": 0.0, "peak": 0.0}
    if os.path.exists(f"{d}/played.f32"):
        import array
        a = array.array("f"); a.frombytes(open(f"{d}/played.f32", "rb").read())
        rate = int(open(f"{d}/played.f32.rate").read() or 48000)
        wav = {"secs": len(a) / rate, "peak": max((abs(x) for x in a), default=0.0)}
    def lines(fn): return open(f"{d}/{fn}").read().splitlines() if os.path.exists(f"{d}/{fn}") else []
    cfg = json.load(open(f"{d}/support/config.json"))
    # What each fake session was sent: (pid, role, text), in order.
    sent = []
    if os.path.exists(f"{d}/fake.txt"):
        for l in open(f"{d}/fake.txt"):
            parts = l.rstrip("\n").split(" ", 5)
            if len(parts) == 6 and parts[1] == "pid" and parts[4] == "question:":
                sent.append((int(parts[2]), parts[3], json.loads(parts[5])))
    return {"events": events, "speech": speech, "spoken": spoken, "wav": wav, "overlay": lines("overlay.txt"),
            "box": lines("box.txt"), "config": cfg, "hung": hung, "dir": d, "sent": sent,
            "fake": open(f"{d}/fake.txt").read() if os.path.exists(f"{d}/fake.txt") else ""}


def evs(r, name, **match):
    return [e for e in r["events"] if e["ev"] == name and all(e.get(k) == v for k, v in match.items())]


def states(r):
    return [e["to"] for e in r["events"] if e["ev"] == "state"]


# Each: (questions, quit-after, env, check). check returns a list of failures (empty: passed).
def c_answer(r):
    f = []
    if r["speech"] != ["Fake answer."]: f.append(f"said {r['speech']}")
    if states(r)[-1:] != ["idle"]: f.append(f"ended in {states(r)[-1:]}")
    return f


def c_stuffed(r):
    # Claude Code never reads its input: the screenshot message can't be written. The main thread must stay
    # free, so the watchdog restarts it, the user hears one line, and the next question goes out.
    f = []
    if r["hung"]: f.append("the app froze (didn't quit by itself)")
    if not evs(r, "brain.restart"): f.append("no watchdog restart")
    if len(r["speech"]) != 1: f.append(f"said {r['speech']} (expected one apology)")
    if len(evs(r, "capture")) < 2: f.append("the second question never got a screenshot")
    return f


def c_hang(r):
    # The watchdog fails the question; its spoken error is "speaking", not "thinking" (so the stuck detector
    # doesn't fire on top of it, and a key press doesn't glue the next question onto the failed one).
    f = []
    if evs(r, "stuck"): f.append("the stuck detector fired while the error was being said")
    if len(r["speech"]) != 1: f.append(f"said {r['speech']} (expected one apology)")
    seq = states(r)
    i = max(i for i, e in enumerate(r["events"]) if e["ev"] == "error") if evs(r, "error") else None
    after = [e["to"] for e in r["events"][i:] if e["ev"] == "state"] if i is not None else []
    if after[:1] != ["speaking"]: f.append(f"states after the error: {after}")
    return f


def c_teacher_order(r):
    # The teacher starts alongside the talker ("explain…"); a quick teacher must not be heard before the
    # talker's hand-over line.
    want = ["Sure, let me show you.", "Here is the sketch."]
    return [] if r["speech"] == want else [f"said {r['speech']}, want {want}"]


def c_teacher_fail(r):
    # The talker said "let me show you" and the teacher failed: a short line, not silence.
    f = []
    if len(r["speech"]) != 2 or r["speech"][0] != "Sure, let me show you." or "drawing" not in r["speech"][1]:
        f.append(f"said {r['speech']}")
    if states(r)[-2:] != ["ready", "idle"]: f.append(f"ended with {states(r)[-2:]}")
    return f


def c_doer(r):
    # A walkthrough (here Poinky doing it, four steps with a 1.2 s look each): it never says "ready" until
    # it's done, and every step's line is said once, in order.
    f = []
    want = ["Okay, doing it.", "Step one is here.", "Step two is here.", "Step four.", "All done."]
    if r["speech"] != want: f.append(f"said {r['speech']}")
    seq = states(r)
    try: last = len(seq) - 1 - seq[::-1].index("speaking")
    except ValueError: last = 0
    first = seq.index("thinking") if "thinking" in seq else 0
    if "ready" in seq[first:last]: f.append(f"went 'ready' between steps: {seq}")
    return f


def c_start_stall(r):
    # The session never finishes starting (speech engine): the stuck detector must see it (it only ran once
    # a session was up) and start over.
    f = []
    if not evs(r, "stuck", state="starting"): f.append("no stuck detection while starting")
    if not evs(r, "reset"): f.append("no reset")
    return f


DOER = {"FAKE_CLAUDE_REPLY": "<say>Okay, doing it.</say><do>wait a moment</do>",
        "FAKE_SLOW_ROLE": "guide", "FAKE_FIRST_TOKEN_SECS": "1.2",
        "FAKE_GUIDE_REPLIES": json.dumps(['<say>Step one is here.</say><act>{"do":"wait","s":0.2}</act>',
                                          '<say>Step two is here.</say><act>{"do":"wait","s":0.2}</act>',
                                          '<act>{"do":"wait","s":0.2}</act>',
                                          '<say>Step four.</say><act>{"do":"wait","s":0.2}</act>',
                                          '<done>All done.</done>'])}
def c_api_interrupt(r):
    # The API brain: a long reply is cut off by the next question, which must not wait for the old stream to
    # finish (it waited the whole rest of it: the brain answers one question at a time).
    f = []
    toks = [e for e in r["events"] if e["ev"] == "firstToken"]
    if len(toks) < 2: return [f"{len(toks)} first tokens: {[e['ev'] for e in r['events']]}"]
    if toks[1].get("after", 99) > 1.5: f.append(f"the second answer started {toks[1].get('after')} s after it was asked")
    if not r["speech"] or r["speech"][-1] != "Short.": f.append(f"said {r['speech']}")
    return f


LONG = "<say>" + " ".join(f"Word{i}." for i in range(60)) + "</say>"

def c_doer_quiet(r):
    # Many steps that only click (nothing said): each step is progress, so "thinking" that long isn't stuck.
    f = []
    if evs(r, "stuck"): f.append("the stuck detector reset a working walkthrough")
    if r["speech"][-1:] != ["All done."]: f.append(f"said {r['speech']}")
    return f


QUIET = {**DOER, "POINKY_STUCK_SECS": "5",
         "FAKE_GUIDE_REPLIES": json.dumps(['<act>{"do":"wait","s":0.2}</act>'] * 6 + ['<done>All done.</done>'])}
HANDOVER = {"FAKE_CLAUDE_REPLY": "<say>Sure, let me show you.</say>"}

def c_said(*words):
    # One spoken error line, with these words: what happened, not a generic "got stuck".
    def check(r):
        if len(r["speech"]) != 1 or not all(w in r["speech"][0] for w in words): return [f"said {r['speech']}, want one line with {words}"]
        return []
    return check


def c_blind(r):
    # The display is asleep (every capture fails): the question goes without a picture, told so, and is answered.
    f = []
    if r["speech"] != ["Fake answer."]: f.append(f"said {r['speech']}")
    if not evs(r, "capture.failed"): f.append("no capture.failed in the timeline")
    log = open(r["dir"] + "/fake.txt").read() if os.path.exists(r["dir"] + "/fake.txt") else ""
    if "couldn't be captured" not in log: f.append("the talker wasn't told there's no screenshot")
    return f


def c_gone_folder(r):
    # A helper for a folder that's gone: said plainly, the closest folder offered, and a yes starts it there.
    f = []
    sp = r["speech"]
    if len(sp) < 3 or "isn't there anymore" not in sp[1] or "Want me to start it in" not in sp[1]: f.append(f"said {sp}")
    elif "on it" not in sp[2]: f.append(f"the yes didn't start it: {sp}")
    return f


def c_audio_lost(r):
    # The output device goes away for good mid-answer (Apple's voice): the turn still ends ("speaking" never cleared).
    f = []
    seq = states(r)
    if "speaking" not in seq: f.append(f"never spoke: {seq}")
    if seq[-2:] != ["ready", "idle"]: f.append(f"ended with {seq[-3:]} (stuck on speaking?)")
    return f


def c_synth_hang(r):
    # Apple's voice never answers: "speaking" with nothing heard is caught, logged and recovered from.
    f = []
    if not evs(r, "stuck", state="speaking"): f.append("no stuck detection while speaking")
    if not evs(r, "reset"): f.append("no reset")
    return f


def c_search(r):
    # <search>: "speaking" only while the short line is heard; the search itself is "thinking" (looking it up).
    f = []
    ev = [e for e in r["events"] if e["ev"] == "state"]
    seq = [e["to"] for e in ev]
    if r["speech"] != ["One sec.", "It is sunny."]: f.append(f"said {r['speech']}")
    # The longest "speaking" stretch must be short (the search takes 6 s).
    longest = max([b["t"] - a["t"] for a, b in zip(ev, ev[1:]) if a["to"] == "speaking"] or [0])
    if longest > 4: f.append(f"'speaking' for {longest:.1f} s while it searched: {seq}")
    if "thinking" not in seq[seq.index("speaking"):] if "speaking" in seq else True: f.append(f"states {seq}")
    return f


# Quiet mode and typed answers (Quiet.swift): nothing is played (the WAV of what was played is digital silence, but
# as long as reading takes), while captions, lesson steps and <end/> work as with the voice.
TWO = {"FAKE_CLAUDE_REPLY": "<say>The first sentence of the answer is here. The second one follows it.</say>"}
LESSON = {**HANDOVER, "FAKE_ARTIST_REPLY": '<lesson title="Heart"><say>The heart has four rooms.</say><step>[{"op":"text","x":40,"y":40,"text":"four"}]</step>'
          '<say>Blood goes in a loop.</say><step>[{"op":"text","x":40,"y":90,"text":"loop"}]</step></lesson>'}

def silent(r, f, min_secs):
    if r["wav"]["peak"] != 0.0: f.append(f"something was played (peak {r['wav']['peak']:.3f})")
    if r["wav"]["secs"] < min_secs: f.append(f"the silence was only {r['wav']['secs']:.1f} s (timing lost)")
    if any(s != "(quiet)" for s in r["spoken"]): f.append(f"a voice was given text: {r['spoken']}")

def c_quiet(r):
    f = []
    want = ["The first sentence of the answer is here.", "The second one follows it."]
    if r["speech"] != want: f.append(f"captions {r['speech']}")
    silent(r, f, 2.0)
    caps = [l for l in r["overlay"] if "SB.caption('claude'" in l and "second one" in l]
    if not caps or "The first sentence" not in caps[-1]: f.append("the bubble didn't get the whole answer")
    if not any("SB.captionMode(" in l and '"read"' in l for l in r["overlay"]): f.append("the bubble wasn't in reading mode")
    if not any("SB.captionDone(" in l and ", true)" in l for l in r["overlay"]): f.append("the answer wasn't kept to read (captionDone)")
    return f

def c_quiet_end(r):
    f = []
    silent(r, f, 1.0)
    ends = evs(r, "session.end")
    if not ends: f.append("<end/> didn't end the session")
    return f

def c_quiet_lesson(r):
    f = []
    want = ["Sure, let me show you.", "The heart has four rooms.", "Blood goes in a loop."]
    if r["speech"] != want: f.append(f"captions {r['speech']}")
    silent(r, f, 3.0)
    ov = r["overlay"]
    def first(pred):
        return next((i for i, l in enumerate(ov) if pred(l)), None)
    cap1 = first(lambda l: "SB.caption('claude'" in l and "four rooms" in l)
    step1 = first(lambda l: "SB.lessonStep(" in l)
    cap2 = first(lambda l: "SB.caption('claude'" in l and "in a loop" in l)
    steps = [i for i, l in enumerate(ov) if "SB.lessonStep(" in l]
    if cap1 is None or step1 is None or step1 < cap1: f.append(f"the first step didn't wait for its sentence (caption {cap1}, step {step1})")
    if cap2 is None or len(steps) < 2 or steps[1] < cap2: f.append("the second step didn't wait for its sentence")
    t = lambda i: float(ov[i].split()[0])
    if cap1 is not None and cap2 is not None and t(cap2) - t(cap1) < 1.4: f.append(f"the lesson lines came {t(cap2) - t(cap1):.2f} s apart (the pen needs time)")
    return f

def c_voice(r):
    # The same answer with quiet mode off: something is played (so the silence checks above can fail).
    f = []
    if r["wav"]["peak"] < 0.01: f.append(f"nothing was played (peak {r['wav']['peak']})")
    if any(s == "(quiet)" for s in r["spoken"]): f.append("it went quiet")
    return f

def c_typed(r):
    f = []
    silent(r, f, 1.0)
    box = "\n".join(r["box"])
    if 'asked "make this shorter"' not in box: f.append(f"the box didn't show the question: {r['box'][:3]}")
    if "We ship Friday, tested and ready." not in box: f.append("the box didn't get the answer")
    if 'done copy="We ship Friday, tested and ready."' not in box: f.append(f"Copy wouldn't copy the rewrite: {[l for l in r['box'] if l.startswith('done')]}")
    if any("SB.caption('claude'" in l and "We ship Friday" in l for l in r["overlay"]): f.append("the answer also went to the bubble")
    if "closed" in r["box"][:-1]: f.append("the box closed while answering")
    return f

def c_quiet_words(r):
    # "be quiet" (no model) → quiet, the next answer is silent, "you can talk again" → spoken again.
    f = []
    if not evs(r, "quiet", on=True, by="words"): f.append("“be quiet” didn't turn it on")
    if not evs(r, "quiet", on=False, by="words"): f.append("“you can talk again” didn't turn it off")
    if r["config"].get("quiet") is not False: f.append(f"config quiet = {r['config'].get('quiet')}")
    sp = dict(zip(r["speech"], r["spoken"]))
    if sp.get("Quiet mode is on. I'll write my answers instead of saying them.") != "(quiet)": f.append(f"the confirmation was said: {sp}")
    if sp.get("Fake answer.") != "(quiet)": f.append("the answer in quiet mode was said")
    if sp.get("Okay, I'll talk out loud again.", "(quiet)") == "(quiet)": f.append("talking again wasn't said out loud")
    fake = open(r["dir"] + "/fake.txt").read() if os.path.exists(r["dir"] + "/fake.txt") else ""
    if any(" talker question" in l and "be quiet" in l for l in fake.splitlines()): f.append("“be quiet” went to the talker")
    return f

REWRITE = {"FAKE_CLAUDE_REPLY": "<say>Here's a shorter version: We ship Friday, tested and ready. Want me to swap it in?</say>"
           "<offer say=\"Swapping it in.\"><do>Replace the selected text with exactly: We ship Friday, tested and ready.</do></offer>"}
def asked(r, role):
    """The text each session of `role` was sent, in order (talker, artist, summarizer, notes…)."""
    return [t for _, ro, t in r["sent"] if ro == role]


def conversation(r):
    out = []
    cdir = f"{r['dir']}/support/conversations"
    for fn in sorted(os.listdir(cdir)) if os.path.isdir(cdir) else []:
        out += [json.loads(l) for l in open(f"{cdir}/{fn}") if l.strip()]
    return out


LESSON1 = ('<lesson title="checking number one"><say>Your factoring is right.</say><step>[{"op":"text","x":40,"y":60,"text":"(x-2)(x-3)=0"}]</step>'
           '<say>But your answer is wrong: the signs flip, so x is 2 or 3.</say><step>[{"op":"text","x":40,"y":140,"text":"x = 2 or 3"}]</step></lesson>')

def c_teacher_record(r):
    # r01: the teacher said answer 1 was wrong; the talker, the summary, the log and the daily note must all know.
    f = []
    talk = asked(r, "talker")
    if len(talk) < 2: return [f"the talker got {len(talk)} questions"]
    if "What you just showed and said" not in talk[1] or "the signs flip" not in talk[1] or "finished" not in talk[1]:
        f.append("the talker's next message lacks the lesson: " + talk[1][:600])
    summ = asked(r, "summarizer")
    if not any("Poinky's sketch:" in t and "finished" in t and "the signs flip" in t for t in summ):
        f.append(f"no summary update with the finished lesson ({len(summ)} updates)")
    if any("User: explain number one" in t and "Poinky's sketch" not in t for t in summ):
        f.append("the summary got the question before its lesson ended (it says 'about to show')")
    notes = asked(r, "notes")
    if not notes or "[Sketch:" not in notes[0] or "finished" not in notes[0]: f.append("the daily note's input lacks the lesson: " + (notes[0][:400] if notes else "none"))
    log = [e for e in conversation(r) if e.get("you") == "explain number one"]
    if not log or "finished" not in (log[0].get("lesson") or ""): f.append(f"the conversation log lacks the lesson: {log}")
    return f


LESSON6 = ('<lesson title="the heart">' + "".join(f'<say>Heart line {i} is a sentence about the heart that takes a moment.</say>'
           f'<step>[{{"op":"text","x":40,"y":{40 + 60 * i},"text":"step {i}"}}]</step>' for i in range(1, 7)) + '</lesson>')
LESSON_NEXT = '<lesson title="the heart" continue="true"><say>Picking up from there.</say></lesson>'

def c_teacher_interrupt(r):
    # A follow-up while the lesson is still being written: the same teacher session answers it (interrupted, not
    # restarted) and is told where the user stopped hearing it.
    f = []
    art = [(pid, t) for pid, ro, t in r["sent"] if ro == "artist"]
    if len(art) != 2: return [f"the teacher got {len(art)} briefs"]
    if art[0][0] != art[1][0]: f.append(f"a new teacher process answered ({art[0][0]} then {art[1][0]})")
    if "interrupt" not in r["fake"]: f.append("the teacher's turn was never interrupted")
    if "was cut off" not in art[1][1] or "continue=" not in art[1][1]: f.append("the second brief doesn't say the lesson was cut off: " + art[1][1][:500])
    if not evs(r, "lesson.end", how="interrupted"): f.append("no interrupted lesson in the timeline")
    if evs(r, "brain.restart"): f.append("a brain was restarted")
    talk = asked(r, "talker")
    if len(talk) < 2 or ("interrupted" not in talk[1] and "Heart line" in r["fake"] and evs(r, "lesson.end", how="interrupted") and
                         evs(r, "lesson.end", how="interrupted")[0].get("heard", 0) > 0):
        f.append("the talker wasn't told the lesson was cut off")
    return f


def seed_previous(mins=4, app="Notebook Test App", window="bugs.md", you="can you make the first paragraph shorter",
                  poinky="Sure. The first paragraph is the Mint timer and sketchboard bug list, so I'll shorten that one."):
    def make():
        at = time.time() - mins * 60
        day = time.strftime("%Y-%m-%d", time.localtime(at))
        return {f"conversations/{day}.jsonl": json.dumps({"at": at, "you": you, "poinky": poinky, "app": app, "window": window}) + "\n"}
    return make


def c_carry_dropped(r):
    talk = asked(r, "talker")
    if not talk: return ["no question"]
    # (Checked by the block's own words: the real front window can contain anything, even "Mint timer".)
    return ["the old answer about another app was sent as context: " + talk[0][:700]] if "previous session" in talk[0] or "so I'll shorten that one" in talk[0] else []


def c_carry_kept(r):
    talk = asked(r, "talker")
    if not talk: return ["no question"]
    t = talk[0]
    return [] if "Mint timer" in t and "NOT the screen now" in t and "Notebook Test App" in t else ["the previous session isn't there, labeled: " + t[:700]]


def seed_reminder(secs=7):
    def make():
        at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + secs))
        return {"reminders.json": json.dumps([{"id": "r1", "text": "stand up and stretch", "at": at}])}
    return make


def c_reminder_fired(r):
    f = []
    if not any("stand up and stretch" in s for s in r["speech"]): f.append(f"the reminder wasn't said: {r['speech']}")
    talk = asked(r, "talker")
    if len(talk) < 2 or "Already went off" not in talk[1] or "stand up and stretch" not in talk[1]:
        f.append("the talker doesn't know it went off: " + (talk[1][:600] if len(talk) > 1 else "no second question"))
    if not any("reminder went off" in (e.get("note") or "") for e in conversation(r)): f.append("not in the conversation log")
    return f



def c_doer_keys(r):
    # The doer presses every kind of shortcut (⌥, ⇧, ⌘, ⌃, ⌃⌥, fn) into a window of the app's own, then clicks
    # and types there. Its key presses used to leave their modifiers held: ⌥ switched on marking mode and every
    # later click became a red pin instead of reaching the app (and ⌃⌥ could open the mic).
    f = []
    log = open(f"{r['dir']}/target.txt").read().splitlines() if os.path.exists(f"{r['dir']}/target.txt") else []
    if any("ABORT" in l for l in log): return ["the target window wasn't in front (nothing was pressed)"]
    clicks = [l for l in log if l.startswith("click left")]
    if len(clicks) < 2: f.append(f"{len(clicks)} of 2 clicks reached the window: {log[-6:]}")
    if any("mods=-" not in l for l in clicks): f.append(f"clicks carried modifiers: {clicks}")
    want = {"126": "option", "125": "option+shift", "124": "cmd", "14": "ctrl"}
    for code, mods in want.items():
        if not any(l.startswith(f"key {code} mods={mods} ") for l in log): f.append(f"key {code} with {mods} never arrived")
    if not any("chars= ok" in l for l in log): f.append("the typed text never arrived")
    if evs(r, "marking", on=True): f.append("marking mode switched on")
    if evs(r, "mark"): f.append(f"{len(evs(r, 'mark'))} red pins/marks were dropped")
    if evs(r, "keys.down"): f.append("the talk keys fired (mic / interrupt)")
    if r["speech"][-1:] != ["Done."]: f.append(f"said {r['speech']}")
    return f


COMBOS = ["option+up", "option+shift+down", "shift+left", "cmd+right", "cmd+shift+left", "option+j", "ctrl+e",
          "ctrl+option+j", "cmd+option+j", "ctrl+shift+j", "fn+left", "shift+tab"]
DOER_KEYS = {"FAKE_CLAUDE_REPLY": "<say>Okay, doing it.</say><do>press keys in the test window</do>", "POINKY_REAL_KEYS": "1",
             "FAKE_GUIDE_REPLIES": json.dumps(
                 ["<say>Pressing keys.</say>" + "".join(f'<act>{{"do":"key","keys":"{k}"}}</act>' for k in COMBOS),
                  '<act>{"do":"click","find":"TARGET WINDOW"}</act>',
                  '<act>{"do":"key","keys":"option+up"}</act><act>{"do":"click","find":"second line here"}</act>'
                  '<act>{"do":"type","text":" ok"}</act>',
                  '<done>Done.</done>'])}

SCENARIOS = {
    "answer": (["what is this"], 10, {}, c_answer),
    "stuffed": (["what is this", "again"], 26, {"FAKE_CLAUDE_MODE": "stuffed", "POINKY_STALL_SECS": "8",
                                                "POINKY_STUCK_SECS": "60", "POINKY_ASK_GAP": "16"}, c_stuffed),
    "teacher-order": (["explain how the heart works"], 10, HANDOVER, c_teacher_order),
    "teacher-fail": (["explain how the heart works"], 10, {**HANDOVER, "FAKE_ARTIST_MODE": "fail"}, c_teacher_fail),
    "teacher-crash": (["explain how the heart works"], 10, {**HANDOVER, "FAKE_ARTIST_MODE": "crash"}, c_teacher_fail),
    "doer": (["do it for me"], 22, DOER, c_doer),
    "doer-quiet": (["do it for me"], 26, QUIET, c_doer_quiet),
    "start-stall": (["hi"], 14, {"POINKY_TEST_STALL_START": "60", "POINKY_STUCK_SECS": "6"}, c_start_stall),
    "api-interrupt": (["tell me a long story", "stop, say something short"], 16,
                      {"_API": "18765", "FAKE_API_WORD_SECS": "0.12", "POINKY_ASK_GAP": "2",
                       "FAKE_API_REPLIES": json.dumps([LONG, "<say>Short.</say>"])}, c_api_interrupt),
    "audio-lost": (["tell me a long story"], 16, {"FAKE_CLAUDE_REPLY": LONG, "POINKY_TEST_AUDIO_LOST": "3"}, c_audio_lost),
    "synth-hang": (["what is this"], 16, {"POINKY_TEST_SYNTH_HANG": "1", "POINKY_STUCK_SECS": "5"}, c_synth_hang),
    "search": (["what's the weather"], 16, {"FAKE_CLAUDE_REPLIES": json.dumps(["<say>One sec.</say><search>weather today</search>", "<say>It is sunny.</say>"]),
                                            "FAKE_SEARCH_SECS": "6"}, c_search),
    "gone-folder": (["have a helper fix it", "yes"], 14,
                    {"FAKE_CLAUDE_REPLIES": json.dumps(['<say>Mint will fix it.</say><agent title="Fix" dir="/tmp/poinky-gone-folder/app">Fix the tests.</agent>']),
                     "POINKY_HELPER_CMD": os.path.join(ROOT, "tools/fake-helper.py"), "POINKY_ASK_GAP": "5"}, c_gone_folder),
    "blind": (["what's two plus two"], 10, {"POINKY_TEST_CAPTURE_FAIL": "1"}, c_blind),
    "crash": (["what is this"], 10, {"FAKE_CLAUDE_MODE": "crash"}, c_said("quit")),
    "stall-line": (["what is this"], 16, {"FAKE_CLAUDE_MODE": "hang", "POINKY_STALL_SECS": "6"}, c_said("stopped answering")),
    "quiet": (["what is this"], 12, {**TWO, "_CONFIG": '{"quiet": true}', "_AUDIO": "1"}, c_quiet),
    "quiet-end": (["bye"], 12, {"FAKE_CLAUDE_REPLY": "<say>Bye for now, see you later.</say><end/>", "_CONFIG": '{"quiet": true}'}, c_quiet_end),
    "quiet-lesson": (["explain how the heart works"], 16, {**LESSON, "_CONFIG": '{"quiet": true}'}, c_quiet_lesson),
    "voice": (["what is this"], 12, TWO, c_voice),
    "typed": ([], 12, {**REWRITE, "_ARGS": ["--type", "make this shorter"]}, c_typed),
    "quiet-words": (["be quiet", "what is this", "you can talk again"], 18, {"POINKY_ASK_GAP": "4"}, c_quiet_words),
    "teacher-record": (["explain number one", "wait why is it wrong"], 26,
                       {"FAKE_CLAUDE_REPLIES": json.dumps(["<say>Sure, let me show you.</say>", "<say>Because the signs flip.</say>"]),
                        "FAKE_ARTIST_REPLY": LESSON1, "POINKY_ASK_WAIT": "1", "_ARGS": ["--end-after", "17"]}, c_teacher_record),
    "teacher-interrupt": (["explain how the heart works", "explain the next step"], 22,
                          {**HANDOVER, "FAKE_ARTIST_REPLIES": json.dumps([LESSON6, LESSON_NEXT]), "FAKE_ARTIST_PIECES": "14",
                           "FAKE_ARTIST_PIECE_SECS": "0.5", "POINKY_ASK_GAP": "6"}, c_teacher_interrupt),
    "carry-dropped": (["can you make the first paragraph shorter"], 9, {"_SEED": seed_previous()}, c_carry_dropped),
    "carry-kept": (["what did we talk about earlier"], 9, {"_SEED": seed_previous()}, c_carry_kept),
    "reminder-fired": (["hi", "did my reminder go off"], 20, {"_SEED": seed_reminder(), "POINKY_REMINDER_TICK": "1",
                                                              "POINKY_ASK_GAP": "11"}, c_reminder_fired),
    "doer-keys": (["do it for me"], 24, DOER_KEYS, c_doer_keys, ["--doer-target", "{dir}/target.txt"]),
    "hang": (["what is this"], 22, {"FAKE_CLAUDE_MODE": "hang", "POINKY_STALL_SECS": "8", "POINKY_STUCK_SECS": "12"}, c_hang),
}


def main():
    names = [a for a in sys.argv[1:] if not a.startswith("-")]
    if "--list" in sys.argv:
        print("\n".join(SCENARIOS)); return 0
    if not os.path.exists(EXE):
        print("build/Poinky.app is missing: run ./build.sh first"); return 1
    failed = 0
    for name in names or SCENARIOS:
        asks, quit_after, env, check, *args = SCENARIOS[name]
        if args and "--doer-target" in args[0] and not wait_until_idle():
            print(f"  skip {name}: the Mac stayed in use (it needs the keyboard focus for ~20 s)")
            continue
        r = run(name, asks, quit_after, env, args[0] if args else ())
        problems = check(r)
        if problems:
            failed += 1
            print(f"  \033[31mFAIL\033[0m {name}: " + "; ".join(problems) + f"  ({r['dir']})")
        else:
            print(f"  \033[32mok\033[0m   {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
