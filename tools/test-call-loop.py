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
APP = os.environ.get("POINKY_APP") or os.path.join(ROOT, "build/Poinky.app")   # (another build: checks that fail before a fix)
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
    seed = env.pop("_SEED", None)   # files to put in the support folder first: {relative path: text}
    for rel, text in (seed() if callable(seed) else seed or {}).items():
        os.makedirs(os.path.dirname(f"{d}/support/{rel}"), exist_ok=True)
        with open(f"{d}/support/{rel}", "w") as f: f.write(text)
    extra = env.pop("_ARGS", [])
    e = {"POINKY_SUPPORT_DIR": f"{d}/support", "POINKY_TIMELINE_DIR": f"{d}/tl", "POINKY_MUTE": "1",
         "POINKY_SPEECH_LOG": f"{d}/speech.txt", "POINKY_CLAUDE_CMD": FAKE, "FAKE_CLAUDE_LOG": f"{d}/fake.txt"}
    e.update(env)
    if api: e["POINKY_API_URL"] = f"http://127.0.0.1:{api}/v1/messages"
    cmd = ["open", "-n", "-g"]
    for k, v in e.items(): cmd += ["--env", f"{k}={v}"]
    cmd += [APP, "--args"]
    for q in asks: cmd += ["--ask", q]
    cmd += list(args) + list(extra) + ["--quit-after", str(quit_after)]
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
    # What each fake session was sent: (pid, role, text), in order.
    sent = []
    if os.path.exists(f"{d}/fake.txt"):
        for l in open(f"{d}/fake.txt"):
            parts = l.rstrip("\n").split(" ", 5)
            if len(parts) == 6 and parts[1] == "pid" and parts[4] == "question:":
                sent.append((int(parts[2]), parts[3], json.loads(parts[5])))
    return {"events": events, "speech": speech, "hung": hung, "dir": d, "sent": sent,
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
    return ["the old answer about another app was sent as context: " + talk[0][:700]] if "Mint timer" in talk[0] else []


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
