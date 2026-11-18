#!/usr/bin/env python3
"""The call loop with the fake brain (tools/fake-claude.py): no tokens, no mic.

Each scenario launches build/Poinky.app in a scratch support folder, asks typed questions (`--ask`), quits
(`--quit-after`), and checks the timeline and the speech log (what was captioned and said). It needs the
build's Screen Recording permission and an awake display, and it speaks through the speakers, so it's a
local check (not CI). A run that doesn't quit by itself is killed (by its own pid) and fails.

Usage: tools/test-call-loop.py [scenario …]     (no names: all of them; --list shows them)
"""
import json, os, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Poinky.app")
EXE = os.path.join(APP, "Contents/MacOS/Poinky")
FAKE = os.path.join(ROOT, "tools/fake-claude.py")


def pids():
    out = subprocess.run(["pgrep", "-f", EXE], capture_output=True, text=True).stdout.split()
    return set(map(int, out))


def run(name, asks, quit_after, env=None, args=()):
    env = dict(env or {})
    api = env.pop("_API", None)   # the API brain, against tools/fake-api.py on this port
    extra_config = json.loads(env.pop("_CONFIG", "{}"))   # more settings in config.json
    args = list(args) + json.loads(env.pop("_ARGS", "[]"))   # more arguments (e.g. --type)
    if not env.pop("_AUDIO", None): env.setdefault("POINKY_MUTE", "1")   # played at volume 0 (the WAV still records it)
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
    e = {"POINKY_SUPPORT_DIR": f"{d}/support", "POINKY_TIMELINE_DIR": f"{d}/tl",
         "POINKY_SPEECH_LOG": f"{d}/speech.txt", "POINKY_CLAUDE_CMD": FAKE, "FAKE_CLAUDE_LOG": f"{d}/fake.txt",
         "POINKY_SPEECH_WAV": f"{d}/played.f32", "POINKY_OVERLAY_LOG": f"{d}/overlay.txt", "POINKY_TYPEBOX_LOG": f"{d}/box.txt"}
    e.update(env)
    if api: e["POINKY_API_URL"] = f"http://127.0.0.1:{api}/v1/messages"
    cmd = ["open", "-n", "-g"]
    for k, v in e.items(): cmd += ["--env", f"{k}={v}"]
    cmd += [APP, "--args"]
    for q in asks: cmd += ["--ask", q]
    cmd += list(args) + ["--quit-after", str(quit_after)]
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
    for fn in sorted(os.listdir(f"{d}/tl")):
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
    return {"events": events, "speech": speech, "spoken": spoken, "wav": wav, "overlay": lines("overlay.txt"),
            "box": lines("box.txt"), "config": cfg, "hung": hung, "dir": d}


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
    "quiet": (["what is this"], 12, {**TWO, "_CONFIG": '{"quiet": true}', "_AUDIO": "1"}, c_quiet),
    "quiet-end": (["bye"], 12, {"FAKE_CLAUDE_REPLY": "<say>Bye for now, see you later.</say><end/>", "_CONFIG": '{"quiet": true}'}, c_quiet_end),
    "quiet-lesson": (["explain how the heart works"], 16, {**LESSON, "_CONFIG": '{"quiet": true}'}, c_quiet_lesson),
    "voice": (["what is this"], 12, TWO, c_voice),
    "typed": ([], 12, {**REWRITE, "_ARGS": '["--type", "make this shorter"]'}, c_typed),
    "quiet-words": (["be quiet", "what is this", "you can talk again"], 18, {"POINKY_ASK_GAP": "4"}, c_quiet_words),
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
        asks, quit_after, env, check = SCENARIOS[name]
        r = run(name, asks, quit_after, env)
        problems = check(r)
        if problems:
            failed += 1
            print(f"  \033[31mFAIL\033[0m {name}: " + "; ".join(problems) + f"  ({r['dir']})")
        else:
            print(f"  \033[32mok\033[0m   {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
