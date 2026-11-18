#!/usr/bin/env python3
"""How long you wait for Poinky, stage by stage: scripted holds of the talk keys (no microphone) through the built
app with the real model (or tools/fake-claude.py), then a table per question from the timeline it wrote.

  tools/latency.py [--sessions 3] [--per 3] [--gap 20] [--runs 1] [--label base] [--fake] [--keep DIR]
  tools/latency.py --report DIR [DIR …]          # the table again, for runs made earlier (several: pooled)

Each session: holds of `--hold` s with live words, the final words just before you let go, `--slot` s per
question; then the session ends (as the idle timeout would: the daily note is written) and the next starts `--gap`
s later. The recognizer is scripted, so "heard" here is only Poinky's mic tail; Apple's own settling is measured
by tools/test-listener.sh. Scratch settings (POINKY_SUPPORT_DIR, memory and conversation log on, Phonon linked
in like tools/e2e/seed.sh), audio at volume 0. It draws the buddy on the real screen: other agents' runs share it,
so it holds ~/Desktop/poinky-wt/screen.lock (POINKY_SCREEN_LOCK) while the app runs. `--keep DIR` reuses a support
folder (notes and memory carry over, as in real use). Uses (sessions × per) real talker questions per run.

Stages, from the moment the keys go up: heard (final words), capture done, sent (the message written to Claude
Code), first token, first sentence handed to the voice, first audio chunk back, first sound played; plus Claude
Code's own split (requestMs: its time before the request; ttftMs: the model's first token) and cached tokens.
"""
import argparse, glob, json, os, random, shutil, statistics, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
QUESTIONS = ["what is this page about", "what should I look at first here", "sum up what's on my screen in a sentence",
             "is there anything here I should fix", "what app am I in right now", "what's the main point of this",
             "explain the top part of my screen briefly", "what would you do next here", "anything odd on this screen",
             "what's the title of this window", "give me one tip about what I'm looking at", "read me the heading"]


def script(sessions, per, hold, slot, gap, seed):
    rnd = random.Random(seed)
    steps, t = [], 2.0
    for s in range(sessions):
        for q in range(per):
            words = rnd.choice(QUESTIONS)
            w = words.split()
            steps += [{"at": t, "keys": "down"},
                      {"at": t + 0.5, "words": " ".join(w[:2]), "live": True},
                      {"at": t + hold * 0.6, "words": " ".join(w[:-1]), "live": True},
                      {"at": t + hold - 0.08, "words": words[0].upper() + words[1:] + "?", "final": True},
                      {"at": t + hold, "keys": "up"}]
            t += slot
        steps.append({"at": t - 0.5, "endSession": True})
        t += gap
    steps.append({"at": t, "quit": True})
    return steps, t


def seed_support(d):
    os.makedirs(d, exist_ok=True)
    cfg = os.path.join(d, "config.json")
    c = json.load(open(cfg)) if os.path.exists(cfg) else {}
    c.update({"homeShown": True, "checkForUpdates": False, "buddyAutoHide": 0, "memoryEnabled": True,
              "conversationLog": True})
    json.dump(c, open(cfg, "w"), indent=2)
    open(os.path.join(d, "welcome.json"), "w").write('{"done":true,"page":4}')
    real = os.path.expanduser("~/Library/Application Support/Poinky/phonon")
    if os.path.isdir(real) and not os.path.exists(os.path.join(d, "phonon")):
        os.symlink(real, os.path.join(d, "phonon"))


def run_once(args, out):
    os.makedirs(out, exist_ok=True)
    support = args.keep or os.path.join(out, "support")
    seed_support(support)
    steps, end = script(args.sessions, args.per, args.hold, args.slot, args.gap, args.seed)
    sp = os.path.join(out, "script.json")
    json.dump({"steps": steps}, open(sp, "w"))
    env = {"POINKY_SUPPORT_DIR": support, "POINKY_MUTE": "1", "POINKY_TIMELINE_DIR": os.path.join(out, "timeline"),
           "POINKY_SPEECH_LOG": os.path.join(out, "speech.log"), "POINKY_RAW_LOG": os.path.join(out, "raw.jsonl"),
           "POINKY_RECEIPTS_DIR": os.path.join(out, "receipts")}
    if args.fake:
        env["POINKY_CLAUDE_CMD"] = os.path.join(ROOT, "tools", "fake-claude.py")
        env["FAKE_FIRST_TOKEN_SECS"] = str(args.fake_first_token)
        env["FAKE_CLAUDE_REPLY"] = "<say>Sure, this page is a test page with a few lines of text on it.</say>"
    for kv in args.env:
        k, v = kv.split("=", 1); env[k] = v
    app = os.environ.get("POINKY_APP", os.path.join(ROOT, "build", "Poinky.app"))
    cmd = ["open", "-n", "-g", "-W"] + sum([["--env", f"{k}={v}"] for k, v in env.items()], []) + \
          [app, "--args", "--listen-test", sp, os.path.join(out, "out.txt"), "--quit-after", str(int(end + 15))]
    lock = os.environ.get("POINKY_SCREEN_LOCK", os.path.expanduser("~/Desktop/poinky-wt/screen.lock"))
    if os.path.isdir(os.path.dirname(lock)):
        cmd = ["lockf", "-t", "1500", lock] + cmd
    load = os.getloadavg()[0]
    t0 = time.time()
    subprocess.run(cmd, timeout=end + 1600)
    json.dump({"load": load, "loadAfter": os.getloadavg()[0], "secs": time.time() - t0, "fake": args.fake},
              open(os.path.join(out, "run.json"), "w"))
    return out


def questions(run_dir):
    evs = []
    for f in sorted(glob.glob(os.path.join(run_dir, "timeline", "*.jsonl"))):
        evs += [json.loads(l) for l in open(f) if l.strip()]
    evs.sort(key=lambda e: e["t"])
    rows, cur, first_in_session = [], None, False
    for e in evs:
        ev = e["ev"]
        if ev == "session.start":
            first_in_session = True
        elif ev == "keys.up":
            cur = {"up": e["t"], "first": first_in_session}
            first_in_session = False
            rows.append(cur)
        elif cur is None:
            continue
        else:
            def put(k):
                if k not in cur: cur[k] = (e["t"] - cur["up"]) * 1000
            if ev == "heard": put("heard")
            elif ev == "capture": put("capture")
            elif ev == "brain.sent" and "capture" in cur: put("sent")
            elif ev == "firstToken": put("token")
            elif ev == "firstSentence": put("sentence")
            elif ev == "voice.chunk": put("chunk")
            elif ev == "firstSound": put("sound")
            elif ev == "usage" and "token" in cur and "cached" not in cur and e.get("in", 0) > 5000:
                cur["cached"] = e.get("cached", 0); cur["in"] = e.get("in", 0)
                cur["requestMs"] = e.get("requestMs", -1); cur["ttftMs"] = e.get("ttftMs", -1)
            elif ev in ("interrupt", "error", "brain.restart"):
                cur.setdefault("notes", []).append(ev)
    return rows


COLS = [("heard", "heard"), ("capture", "capture"), ("sent", "sent"), ("token", "token"), ("sentence", "sentence"),
        ("chunk", "chunk"), ("sound", "SOUND"), ("requestMs", "ccReq"), ("ttftMs", "ccTTFT"), ("cached", "cached")]


def fmt(v):
    return "-" if v is None else f"{v:.0f}" if isinstance(v, float) else str(v)


def report(dirs, label=""):
    rows = []
    for d in dirs:
        for r in questions(d):
            r["run"] = os.path.basename(d.rstrip("/")); rows.append(r)
        meta = os.path.join(d, "run.json")
        if os.path.exists(meta):
            m = json.load(open(meta)); print(f"# {d}: load {m['load']:.1f} → {m['loadAfter']:.1f}, {m['secs']:.0f} s")
    print(f"{'q':>3} {'1st':>3} " + " ".join(f"{h:>8}" for _, h in COLS) + "  (ms after keys up)")
    for i, r in enumerate(rows):
        print(f"{i+1:>3} {'*' if r['first'] else '':>3} " + " ".join(f"{fmt(r.get(k)):>8}" for k, _ in COLS)
              + ("  " + ",".join(r["notes"]) if r.get("notes") else ""))
    for name, sel in (("first of session", True), ("later", False)):
        sub = [r for r in rows if r["first"] == sel and "sound" in r]
        if not sub: continue
        med = {k: statistics.median([r[k] for r in sub if isinstance(r.get(k), (int, float)) and r[k] >= 0] or [0]) for k, _ in COLS}
        print(f"{'med':>3} {'*' if sel else '':>3} " + " ".join(f"{med[k]:>8.0f}" for k, _ in COLS) + f"  {label} {name}, n={len(sub)}")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sessions", type=int, default=3)
    ap.add_argument("--per", type=int, default=3)
    ap.add_argument("--hold", type=float, default=1.8)
    ap.add_argument("--slot", type=float, default=10)
    ap.add_argument("--gap", type=float, default=20)
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--label", default="run")
    ap.add_argument("--fake", action="store_true")
    ap.add_argument("--fake-first-token", type=float, default=0.8)
    ap.add_argument("--keep", help="support folder to reuse (notes and memory carry over)")
    ap.add_argument("--out", default=None)
    ap.add_argument("--env", action="append", default=[], help="KEY=VALUE for the app")
    ap.add_argument("--report", nargs="+")
    a = ap.parse_args()
    if a.report:
        report(a.report); return
    base = a.out or tempfile.mkdtemp(prefix=f"poinky-latency-{a.label}-")
    dirs = []
    for i in range(a.runs):
        a.seed += i
        dirs.append(run_once(a, os.path.join(base, f"{a.label}-{i+1}")))
    report(dirs, a.label)
    print(f"(runs in {base})")


if __name__ == "__main__":
    main()
