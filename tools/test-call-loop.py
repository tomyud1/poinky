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
    d = tempfile.mkdtemp(prefix=f"poinky-loop-{name}-")
    os.makedirs(f"{d}/support"); os.makedirs(f"{d}/tl")
    with open(f"{d}/support/config.json", "w") as f:
        json.dump({"homeShown": True, "checkForUpdates": False, "sounds": False}, f)
    e = {"POINKY_SUPPORT_DIR": f"{d}/support", "POINKY_TIMELINE_DIR": f"{d}/tl",
         "POINKY_SPEECH_LOG": f"{d}/speech.txt", "POINKY_CLAUDE_CMD": FAKE, "FAKE_CLAUDE_LOG": f"{d}/fake.txt"}
    e.update(env or {})
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


SCENARIOS = {
    "answer": (["what is this"], 10, {}, c_answer),
    "stuffed": (["what is this", "again"], 26, {"FAKE_CLAUDE_MODE": "stuffed", "POINKY_STALL_SECS": "8",
                                                "POINKY_STUCK_SECS": "60", "POINKY_ASK_GAP": "16"}, c_stuffed),
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
