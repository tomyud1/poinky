#!/usr/bin/env python3
"""Photos of your work (CallController+Photo.swift, PhonePhoto.swift) with a fake iPhone and the fake brain: no
tokens, no phone, no mic.

The fake phone (POINKY_FAKE_PHONE) plays Continuity Camera: it "takes" a given file after a delay, or there's no
device, or the menu is closed, or the picture never comes. Each scenario launches build/Poinky.app once in a
scratch support folder, clicks the card's buttons with `--photo <action>` (as the paper's "📷 My work" and the card
do), says things with `--ask`, drops files with `--photo-drop`, then checks the timeline, the card (POINKY_OVERLAY_LOG),
what the fake brain received (FAKE_CLAUDE_LOG: how many images each message had), what was said, the receipts, the
study state, and that no picture is left behind (the inbox is empty; a study session keeps its pages, 0600).

  study       start → "📷 My work" → + Page → Check now (2 pages, wrong) → "check my work" with the sheet in front
              (the phone is asked; 1 page, right; auto after the countdown)
  question    "I'll take a picture of the circuit, what's wrong with it?" → the question goes with the photo, once
  nodevice    no iPhone nearby: the card says so with the other ways in; said out loud when asked by voice
  cancel      the menu closed (the card goes), then a pick whose picture never comes (it times out)
  recent      "use the photo I just AirDropped" → the newest picture (not the screenshot, not the old one) → yes →
              the next question takes it; an iPad PDF dropped on the paper → 2 pages with "is this right?"

A window of the test's own covers the screen while it runs (tools/tests/cover-window.swift), so screenshots never
show anything else; the run stops if that window isn't in front. Run under the screen lock when agents share the
Mac:  lockf -t 1500 ~/Desktop/poinky-wt/screen.lock python3 tools/test-photo.py [scenario…] [--keep]
"""
import json, os, re, stat, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Poinky.app")
EXE = os.path.join(APP, "Contents/MacOS/Poinky")
SHEET = os.path.join(ROOT, "tools/study/sheet-he.pdf")
WORK = os.path.join(ROOT, "tools/study/work")
HARD = os.path.join(ROOT, "tools/study/hard")

sys.path.insert(0, os.path.join(ROOT, "tools"))
import importlib.util
spec = importlib.util.spec_from_file_location("test_study", os.path.join(ROOT, "tools/test-study.py"))
ts = importlib.util.module_from_spec(spec); spec.loader.exec_module(ts)

SCRIPT = dict(ts.SCRIPT)
SCRIPT["check"] = [ts.lesson("check", ["Let me go through both pages.", "Your third line factors it wrong."], cont=False)
                   + '<verdict result="wrong" line="3">factored x²−4x+3 as (x−1)(x+3)</verdict>',
                   ts.lesson("check", ["Let me go through it.", "Every line is right."], cont=False)
                   + '<verdict result="right" line="0">all right</verdict>']


def pids():
    return set(map(int, subprocess.run(["pgrep", "-f", EXE], capture_output=True, text=True).stdout.split()))


def cover(d, secs):
    """The test's own window in front; returns (process, ok)."""
    exe = os.path.join(d, "cover-window")
    if not os.path.exists(exe):
        subprocess.run(["swiftc", "-O", os.path.join(ROOT, "tools/tests/cover-window.swift"), "-o", exe], check=True, capture_output=True)
    st = os.path.join(d, "cover.txt")
    if os.path.exists(st): os.remove(st)
    shot = os.path.join(d, "sheet.png")
    if not os.path.exists(shot):
        subprocess.run(["sips", "-s", "format", "png", SHEET, "--out", shot], capture_output=True)
    p = subprocess.Popen([exe, str(secs), st, shot])
    for _ in range(40):
        time.sleep(0.25)
        s = open(st).read().strip() if os.path.exists(st) else ""
        if s == "front": return p, True
        if s == "notfront": break
    p.kill()
    return p, False


def launch(d, items, quit_after, env_extra):
    env = {"POINKY_SUPPORT_DIR": f"{d}/support", "POINKY_TIMELINE_DIR": f"{d}/tl", "POINKY_SPEECH_LOG": f"{d}/speech.txt",
           "POINKY_CLAUDE_CMD": os.path.join(ROOT, "tools/fake-claude.py"), "FAKE_STUDY_SCRIPT": f"{d}/script.json",
           "FAKE_CLAUDE_LOG": f"{d}/fake.log", "POINKY_OVERLAY_LOG": f"{d}/overlay.log", "POINKY_RECEIPTS_DIR": f"{d}/receipts",
           "POINKY_LESSON_DIR": f"{d}/out", "POINKY_ASK_WAIT": "1.5", "POINKY_MUTE": "1", "POINKY_FAKE_PHONE_DELAY": "1",
           "FAKE_CLAUDE_REPLY": "<say>Fake talker answer.</say>"}
    env.update(env_extra)
    cmd = ["open", "-n", "-g"]
    for k, v in env.items(): cmd += ["--env", f"{k}={v}"]
    cmd += [APP, "--args"]
    for kind, v in items: cmd += [kind, v]
    cmd += ["--quit-after", str(quit_after)]
    cov, ok = cover(d, quit_after + 20)
    if not ok:
        print("ABORT: the test window couldn't get in front (someone is using the Mac?); nothing was launched")
        sys.exit(2)
    before = pids()
    subprocess.run(cmd, check=True)
    pid = None
    for _ in range(40):
        new = pids() - before
        if new: pid = new.pop(); break
        time.sleep(0.25)
    end = time.time() + quit_after + 15
    lost = False
    while pid and time.time() < end:
        if open(os.path.join(d, "cover.txt")).read().strip() == "lost":
            lost = True; os.kill(pid, 9); break
        try: os.kill(pid, 0)
        except ProcessLookupError: break
        time.sleep(0.5)
    else:
        if pid:
            try: os.kill(pid, 9)
            except ProcessLookupError: pass
    cov.kill()
    if lost:
        print("ABORT: the test window stopped being in front; the test copy was stopped"); sys.exit(2)


class Run:
    def __init__(self, d):
        self.d = d
        self.events = [json.loads(l) for f in sorted(os.listdir(f"{d}/tl")) for l in open(f"{d}/tl/{f}")] if os.path.isdir(f"{d}/tl") else []
        self.speech = [l.split("\t")[0] for l in open(f"{d}/speech.txt").read().splitlines()] if os.path.exists(f"{d}/speech.txt") else []
        self.fake = open(f"{d}/fake.log").read().splitlines() if os.path.exists(f"{d}/fake.log") else []
        self.overlay = open(f"{d}/overlay.log").read().splitlines() if os.path.exists(f"{d}/overlay.log") else []
        self.cards = []
        for l in self.overlay:
            m = re.search(r"SB\.workPhoto\((\{.*\})\)\s*$", l)
            if m:
                try: self.cards.append(json.loads(m.group(1)))
                except ValueError: pass
            elif "SB.workPhoto(null)" in l: self.cards.append(None)

    def ev(self, name, **kw):
        return [e for e in self.events if e["ev"] == name and all(e.get(k) == v for k, v in kw.items())]

    def questions(self, role):
        """(text, images) of each message the fake brain got in that role."""
        out = []
        for l in self.fake:
            m = re.search(r" (\w+) question: (\".*\")( images=(\d+))?$", l)
            if m and m.group(1) == role: out.append((json.loads(m.group(2)), int(m.group(4) or 0)))
        return out

    def states(self):
        return [c["state"] if c else None for c in self.cards]

    def inbox(self):
        p = f"{self.d}/support/photos/inbox"
        return [f for f in os.listdir(p)] if os.path.isdir(p) else []

    def receipts_also(self):
        out = []
        p = f"{self.d}/receipts"
        for f in sorted(os.listdir(p)) if os.path.isdir(p) else []:
            if f.endswith(".json"):
                try: out += json.load(open(f"{p}/{f}")).get("also", [])
                except ValueError: pass
        return out


checks = []


def check(name, cond, info=""):
    cond = bool(cond); checks.append(cond)
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  [{str(info)[:400]}]"))


def scratch(name):
    d = tempfile.mkdtemp(prefix=f"poinky-photo-{name}-")
    for sub in ["support", "tl", "out", "receipts", "dl"]: os.makedirs(f"{d}/{sub}")
    json.dump(SCRIPT, open(f"{d}/script.json", "w"), ensure_ascii=False)
    json.dump({"homeShown": True, "checkForUpdates": False, "sounds": False}, open(f"{d}/support/config.json", "w"))
    return d


def study():
    d = scratch("study")
    phone = f"{WORK}/slip-early.jpg;{HARD}/two-columns.jpg;{WORK}/all-right.jpg"
    launch(d, [("--ask", "let's do question 1 together"), ("--photo", "capture"), ("--photo", "add"), ("--photo", "use"),
               ("--ask", "check my work")], 75,
           {"POINKY_FAKE_PHONE": phone, "POINKY_STUDY_DOCUMENT": SHEET, "POINKY_PHOTO_COUNTDOWN": "8", "POINKY_PHOTO_SHEET_IN_FRONT": "1"})
    r = Run(d)
    outcomes = [e.get("outcome") for e in r.ev("photo.outcome")]
    check("study: three pictures came from the phone", outcomes[:3] == ["files:1"] * 3, outcomes)
    uses = r.ev("photo.use")
    check("study: they went to the study session (2 pages, then 1)", [(e.get("to"), e.get("pages")) for e in uses] == [("study", 2), ("study", 1)], uses)
    checks_ = r.ev("study.check")
    check("study: the checks had 2 pages, then 1", [e.get("pages") for e in checks_] == [2, 1], checks_)
    teach = [q for q in r.questions("artist") if q[0].startswith("STUDY: check")]
    check("study: the teacher got 2 pictures, then 1 (no screenshot)", [n for _, n in teach] == [2, 1], [(t[:40], n) for t, n in teach])
    check("study: it was told they're pages in order", teach and "last 2 images (one page each, in order)" in teach[0][0], teach[:1])
    check("study: 'check my work' with the sheet in front asked the phone", any(e.get("voice") for e in r.ev("photo.capture")), r.ev("photo.capture"))
    check("study: the card showed waiting, then what came", "waiting" in r.states() and "got" in r.states(), r.states())
    got = [c for c in r.cards if c and c["state"] == "got"]
    check("study: + Page made one card with both pages", any(len(c.get("thumbs", [])) == 2 for c in got), [len(c.get("thumbs", [])) for c in got])
    check("study: Retake / + Page / Check now on the card", got and [b["id"] for b in got[0]["buttons"]] == ["retake", "add", "use"], got[:1])
    state = ts.load_state(d)
    parts = state and state["questions"][0]["parts"]
    att = parts and parts[0]["attempts"]
    check("study: the attempt keeps both pages in order", att and len(att[0].get("images") or []) == 2 and att[0]["verdict"] == "wrong", att)
    check("study: then right with one page", att and len(att) == 2 and att[1]["verdict"] == "right", att)
    folder = state and os.path.join(d, "support/study", state["id"])
    files = sorted(os.listdir(folder)) if folder else []
    mine = [f for f in files if "-mine-" in f]
    check("study: cleaned pages and originals kept in the sheet's folder", len([f for f in mine if f.endswith("-original.jpg")]) == 3
          and len([f for f in mine if not f.endswith("-original.jpg")]) == 3, mine)
    check("study: those files are private (0600)", mine and all(stat.S_IMODE(os.stat(os.path.join(folder, f)).st_mode) == 0o600 for f in mine),
          [oct(stat.S_IMODE(os.stat(os.path.join(folder, f)).st_mode)) for f in mine])
    check("study: nothing left in the inbox", not r.inbox(), r.inbox())
    return d


def question():
    d = scratch("question")
    launch(d, [("--ask", "I'll take a picture of the circuit, what's wrong with it?"), ("--ask", "and what about the resistor?")], 30,
           {"POINKY_FAKE_PHONE": f"{HARD}/hand-corner.jpg", "POINKY_PHOTO_COUNTDOWN": "2"})
    r = Run(d)
    talk = r.questions("talker")
    check("question: the capture started by voice", r.ev("photo.capture") and r.ev("photo.capture")[0].get("voice"), r.ev("photo.capture"))
    check("question: 'point your iPhone' was said", any("iPhone" in s for s in r.speech), r.speech[:4])
    withphoto = [t for t in talk if "with their iPhone" in t[0]]
    check("question: the question went with the photo (screenshot + 1)", len(withphoto) == 1 and withphoto[0][1] == 2, [(t[:60], n) for t, n in talk])
    check("question: it's the question that was asked", withphoto and "what's wrong with it" in withphoto[0][0], withphoto[:1])
    later = [t for t in talk if "resistor" in t[0]]
    check("question: the next question doesn't send it again", later and later[0][1] <= 1, [(t[:50], n) for t, n in later])
    check("question: the receipt says a photo from your phone went", any("from your phone" in a for a in r.receipts_also()), r.receipts_also())
    check("question: the card said it was sent with the question", any(c and c["state"] == "sent" for c in r.cards), r.states())
    check("question: nothing left in the inbox", not r.inbox(), r.inbox())
    return d


def nodevice():
    d = scratch("nodevice")
    launch(d, [("--photo", "capture"), ("--ask", "I'll send you a photo from my phone")], 20, {"POINKY_FAKE_PHONE": "none"})
    r = Run(d)
    check("no device: both captures ended with no device", [e.get("outcome") for e in r.ev("photo.outcome")] == ["noDevice", "noDevice"], r.ev("photo.outcome"))
    err = [c for c in r.cards if c and c["state"] == "error"]
    check("no device: the card says so and gives the other ways in", err and "drop a photo" in err[-1]["text"] and "AirDrop" in err[-1]["text"], err[-1:])
    check("no device: Try again / Choose a file on the card", err and [b["id"] for b in err[0]["buttons"]] == ["retry", "file"], err[:1])
    check("no device: said only when asked out loud", len([s for s in r.speech if "can't find your iPhone" in s]) == 1, r.speech)
    return d


def cancel():
    d = scratch("cancel")
    launch(d, [("--photo", "capture"), ("--photo", "capture")], 20, {"POINKY_FAKE_PHONE": "cancel;timeout", "POINKY_PHONE_TIMEOUT": "3"})
    r = Run(d)
    check("cancel: closed menu, then a picture that never came", [e.get("outcome") for e in r.ev("photo.outcome")] == ["cancelled", "timedOut"], r.ev("photo.outcome"))
    check("cancel: the card went away after the closed menu", None in r.states() and r.states().index(None) < len(r.states()) - 1, r.states())
    check("cancel: after the wait the card says no photo came", r.cards and r.cards[-1] and r.cards[-1]["state"] == "error" and "No photo" in r.cards[-1]["text"], r.cards[-1:])
    return d


def recent():
    d = scratch("recent")
    dl = f"{d}/dl"
    subprocess.run(["cp", f"{WORK}/sign-last.jpg", f"{dl}/IMG_0412.jpg"])
    subprocess.run(["cp", f"{WORK}/all-right.jpg", f"{dl}/old.jpg"])
    subprocess.run(["cp", f"{HARD}/ipad-notes.png", f"{dl}/Screenshot 2026-11-18 at 10.00.00.png"])
    old = time.time() - 86400
    os.utime(f"{dl}/old.jpg", (old, old))
    launch(d, [("--ask", "use the photo I just airdropped"), ("--ask", "yes"), ("--ask", "what does this say?"),
               ("--photo-drop", f"{HARD}/ipad-notes.pdf"), ("--ask", "is this right?")], 40,
           {"POINKY_RECENT_DIRS": dl, "POINKY_FAKE_PHONE": "none"})
    r = Run(d)
    conf = [c for c in r.cards if c and c["state"] == "confirm"]
    check("recent: it asks about the newest picture (not the screenshot or the old one)", conf and conf[0]["text"] == "IMG_0412.jpg", conf[:1])
    check("recent: said where it found it", any("Downloads" in s or "dl" in s for s in r.speech if "found a picture" in s), r.speech[:3])
    talk = r.questions("talker")
    q1 = [t for t in talk if "what does this say" in t[0]]
    check("recent: the next question took it", q1 and q1[0][1] == 2 and "AirDropped" in q1[0][0], [(t[:50], n) for t, n in q1])
    q2 = [t for t in talk if "is this right" in t[0]]
    check("recent: an iPad PDF dropped on the paper is 2 pages with the question", q2 and q2[0][1] == 3 and "pages in order" in q2[0][0], [(t[:50], n) for t, n in q2])
    art = [q for q in r.questions("artist") if "is this right" in q[0]]
    check("recent: the teacher checking it got the same pages", not art or art[0][1] == 3, [(t[:50], n) for t, n in art])
    check("recent: your own file stays where it was", os.path.exists(f"{dl}/IMG_0412.jpg"))
    check("recent: nothing left in the inbox", not r.inbox(), r.inbox())
    return d


SCENARIOS = {"study": study, "question": question, "nodevice": nodevice, "cancel": cancel, "recent": recent}


def main():
    names = [a for a in sys.argv[1:] if not a.startswith("--")] or list(SCENARIOS)
    dirs = []
    for n in names:
        print(f"== {n}")
        dirs.append(SCENARIOS[n]())
    print(f"{sum(checks)}/{len(checks)} passed   (files in {' '.join(dirs)})")
    sys.exit(0 if all(checks) else 1)


if __name__ == "__main__":
    main()
