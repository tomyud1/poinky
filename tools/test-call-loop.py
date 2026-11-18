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
APP = os.path.join(ROOT, "build/Poinky.app")
EXE = os.path.join(APP, "Contents/MacOS/Poinky")
FAKE = os.path.join(ROOT, "tools/fake-claude.py")


def pids():
    out = subprocess.run(["pgrep", "-f", EXE], capture_output=True, text=True).stdout.split()
    return set(map(int, out))


def run(name, asks, quit_after, env=None, args=()):
    env = dict(env or {})
    api = env.pop("_API", None)   # the API brain, against tools/fake-api.py on this port
    server = None
    if api:
        server = subprocess.Popen([sys.executable, os.path.join(ROOT, "tools/fake-api.py"), api],
                                  env={**os.environ, **{k: v for k, v in env.items() if k.startswith("FAKE_API")}})
        time.sleep(0.5)
    d = tempfile.mkdtemp(prefix=f"poinky-loop-{name}-")
    os.makedirs(f"{d}/support"); os.makedirs(f"{d}/tl")
    with open(f"{d}/support/config.json", "w") as f:
        json.dump({"homeShown": True, "checkForUpdates": False, "sounds": False,
                   **({"brain": "api", "apiKey": "test"} if api else {})}, f)
    e = {"POINKY_SUPPORT_DIR": f"{d}/support", "POINKY_TIMELINE_DIR": f"{d}/tl",
         "POINKY_SPEECH_LOG": f"{d}/speech.txt", "POINKY_CLAUDE_CMD": FAKE, "FAKE_CLAUDE_LOG": f"{d}/fake.txt",
         "POINKY_MUTE": os.environ.get("POINKY_MUTE", "1")}   # (POINKY_MUTE=0 to hear it)
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
    speech = []
    if os.path.exists(f"{d}/speech.txt"):
        speech = [l.split("\t")[0] for l in open(f"{d}/speech.txt").read().splitlines() if l.strip()]
    return {"events": events, "speech": speech, "hung": hung, "dir": d}


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
    "blind": (["what's two plus two"], 10, {"POINKY_TEST_CAPTURE_FAIL": "1"}, c_blind),
    "crash": (["what is this"], 10, {"FAKE_CLAUDE_MODE": "crash"}, c_said("quit")),
    "stall-line": (["what is this"], 16, {"FAKE_CLAUDE_MODE": "hang", "POINKY_STALL_SECS": "6"}, c_said("stopped answering")),
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
