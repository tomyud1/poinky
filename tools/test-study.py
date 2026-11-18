#!/usr/bin/env python3
"""Study sessions with the fake brain (tools/fake-claude.py): no tokens, no mic.

Runs build/Poinky.app twice in one scratch support folder with typed questions (`--ask`) and photos of work
(`--study-photo`), scripted teacher and solver replies (FAKE_STUDY_SCRIPT), then checks the timeline, what
was said, the saved state (Poinky/study/<sheet>/state.json) and the solved PDF:
  launch 1: start → the question is presented → part א → hint ×3 → "I'll try" → a photo (wrong) → "show me"
            (the corrected continuation) → yes (part ב) → a photo (right) → stop
  launch 2: "let's continue the homework" → the resume offer → yes (part ג) → "show me" → "where is the PDF"
The app is on screen while it runs (it needs Screen Recording and an awake display), so run it under the
screen lock when other agents share the Mac. Usage: tools/test-study.py [--keep]
"""
import json, os, re, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "build/Poinky.app")
EXE = os.path.join(APP, "Contents/MacOS/Poinky")
SHEET = os.path.join(ROOT, "tools/study/sheet-he.pdf")
WORK = os.path.join(ROOT, "tools/study/work")

QUESTION = {"number": "1", "title": "שער במיכל", "language": "he",
            "statement": "מיכל פתוח מלא במים בעלי צפיפות ρ עד גובה H. בדופן יש שער בגובה a וברוחב b, עם ציר O בקצה העליון בעומק d.",
            "givens": ["ρ: צפיפות המים", "d: עומק הציר", "a, b: גובה ורוחב השער"], "figure": "מיכל עם שער בדופן הימנית",
            "parts": [{"label": "א", "text": "מצאו את גודל הכוח ההידרוסטטי השקול הפועל על השער.", "say": "Find the total hydrostatic force on the gate."},
                      {"label": "ב", "text": "מצאו את העומק של מרכז הלחץ.", "say": "Find the depth of the centre of pressure."},
                      {"label": "ג", "text": "מצאו את הכוח F שמחזיק את השער סגור.", "say": "Find the force F that holds the gate shut."}],
            "finalAnswers": {}, "complete": True, "box": [200, 150, 600, 400]}


def lesson(title, lines, cont=True):
    out = '<lesson title="%s"%s>' % (title, ' continue="true"' if cont else "")
    for i, l in enumerate(lines):
        out += f'<say>{l}</say><step>[{{"op":"text","id":"t{i}{abs(hash(l)) % 999}","text":"{l}","size":22}}]</step>'
    return out + "</lesson>"


SCRIPT = {
    "present": "<question>" + json.dumps(QUESTION, ensure_ascii=False) + "</question>"
               + lesson("Question 1 · a gate in a tank", ["A tank of water with a gate in its wall.", "The gate hangs on a hinge at depth d."], cont=False),
    "hint": [lesson("hint", ["Hint one: pressure grows with depth."]),
             lesson("hint", ["Hint two: add up pressure times area along the gate."]),
             lesson("hint", ["Hint three: the strip at depth y has area b dy."])],
    "check": [lesson("check", ["Let me go through it line by line.", "Your second line uses one pressure for the whole gate."], cont=False)
              + '<verdict result="wrong" line="2">used the pressure at the hinge for the whole gate</verdict>',
              lesson("check", ["Let me go through it line by line.", "Every line is right."], cont=False)
              + '<verdict result="right" line="0">all right</verdict>'],
    "fix": lesson("fix", ["From your first line, integrate along the gate.", "So F is rho g b a times d plus a over two."]),
    "solve": lesson("solve", ["Take moments about the hinge.", "So F is rho g b a times d over two plus a over three."]),
    "ask": lesson("ask", ["Good question: gauge pressure leaves out the air."]),
    "solver": "".join(f'<part label="{l}"><work>worked {l}</work><answer>answer {l}</answer><confidence>high</confidence></part>' for l in "אבג"),
}


def pids():
    return set(map(int, subprocess.run(["pgrep", "-f", EXE], capture_output=True, text=True).stdout.split()))


def launch(d, items, quit_after, wait=2.5):
    env = {"POINKY_SUPPORT_DIR": f"{d}/support", "POINKY_TIMELINE_DIR": f"{d}/tl", "POINKY_SPEECH_LOG": f"{d}/speech.txt",
           "POINKY_CLAUDE_CMD": os.path.join(ROOT, "tools/fake-claude.py"), "FAKE_STUDY_SCRIPT": f"{d}/script.json",
           "POINKY_STUDY_DOCUMENT": SHEET, "POINKY_LESSON_DIR": f"{d}/out", "POINKY_ASK_WAIT": str(wait),
           "POINKY_MUTE": "1", "FAKE_CLAUDE_REPLY": "<say>Fake talker answer.</say>"}
    cmd = ["open", "-n", "-g"]
    for k, v in env.items(): cmd += ["--env", f"{k}={v}"]
    cmd += [APP, "--args"]
    for kind, v in items: cmd += [kind, v]
    cmd += ["--quit-after", str(quit_after)]
    before = pids()
    subprocess.run(cmd, check=True)
    pid = None
    for _ in range(40):
        new = pids() - before
        if new: pid = new.pop(); break
        time.sleep(0.25)
    end = time.time() + quit_after + 15
    while pid and time.time() < end:
        try: os.kill(pid, 0)
        except ProcessLookupError: return True
        time.sleep(0.5)
    if pid: os.kill(pid, 9)
    return False


def main():
    d = tempfile.mkdtemp(prefix="poinky-study-")
    os.makedirs(f"{d}/support"); os.makedirs(f"{d}/tl"); os.makedirs(f"{d}/out")
    json.dump(SCRIPT, open(f"{d}/script.json", "w"), ensure_ascii=False)
    json.dump({"homeShown": True, "checkForUpdates": False, "sounds": False}, open(f"{d}/support/config.json", "w"))
    ok1 = launch(d, [("--ask", "let's do question 1 together"), ("--ask", "give me a hint"), ("--ask", "another hint please"),
                     ("--ask", "one more hint"), ("--ask", "I'll try it myself"), ("--study-photo", f"{WORK}/hebrew-wrong.jpg"),
                     ("--ask", "show me"), ("--ask", "yes"), ("--study-photo", f"{WORK}/hebrew-right.jpg"),
                     ("--ask", "let's stop for today")], 110)
    state1 = load_state(d)
    ok2 = launch(d, [("--ask", "let's continue the homework"), ("--ask", "yes"), ("--ask", "show me the solution"),
                     ("--ask", "where is the pdf")], 60)
    state2 = load_state(d)
    events = [json.loads(l) for f in sorted(os.listdir(f"{d}/tl")) for l in open(f"{d}/tl/{f}")]
    speech = [l.split("\t")[0] for l in open(f"{d}/speech.txt").read().splitlines()] if os.path.exists(f"{d}/speech.txt") else []
    intents = [e.get("intent") for e in events if e["ev"] == "study.heard"]
    verdicts = [e.get("result") for e in events if e["ev"] == "study.verdict"]
    pdfs = [f for f in os.listdir(f"{d}/out") if f.endswith(".pdf")]
    checks = []
    def check(name, cond, info=""):
        cond = bool(cond); checks.append(cond); print(("PASS " if cond else "FAIL ") + name + ("" if cond else f"  [{info}]"))
    check("launches quit by themselves", ok1 and ok2)
    check("the question was presented, then part א", any("hydrostatic force" in s for s in speech), speech[:6])
    check("three hints, then no more", intents.count("hint") >= 3 and any("as far as hints go" in s for s in speech), intents)
    check("I'll try: waits quietly", "tryIt" in intents and any("take your time" in s for s in speech))
    check("photos checked: wrong, then right", verdicts[:2] == ["wrong", "right"], verdicts)
    check("after the wrong one: a hint or the continuation", any("how it goes on" in s for s in speech))
    check("'show me' after a wrong check is the continuation (fix)", any(e["ev"] == "study.teach" and e.get("kind") == "fix" for e in events))
    a1 = state1 and state1["questions"][0]["parts"]
    check("state after launch 1: א shown, ב solved by you", a1 and a1[0]["status"] == "shown" and a1[1]["status"] == "solvedByUser",
          a1 and [p["status"] for p in a1])
    check("א kept 3 hints and 2 attempts", a1 and a1[0]["hints"] == 3 and len(a1[0]["attempts"]) == 1 and len(a1[1]["attempts"]) == 1)
    check("the solver's reference is saved", a1 and all(p.get("reference") for p in a1))
    check("papers kept for each worked part", a1 and a1[0]["pages"] and a1[1]["pages"] is not None, a1 and [p["pages"] for p in a1])
    check("stop says where we are", any("stop here" in s for s in speech))
    check("launch 2 offers to pick up at part ג", any("pick up there" in s and "Gimel" in s for s in speech), [s for s in speech if "stopped" in s])
    a2 = state2 and state2["questions"][0]["parts"]
    check("state after launch 2: ג shown", a2 and a2[2]["status"] == "shown", a2 and [p["status"] for p in a2])
    check("a solved PDF next to the lessons", len(pdfs) == 1, pdfs)
    if pdfs:
        pages, text = pdf_pages(f"{d}/out/{pdfs[0]}")
        # The sheet's 2 pages, then א, ב, ג (each at least a page).
        check("PDF: the sheet, then parts א, ב, ג in order", pages >= 5 and ordered(text, ["סעיף א", "סעיף ב", "סעיף ג"]), (pages, text[:300]))
        check("PDF: ב has your own work (you solved it)", "הפתרון שלי" not in text.split("סעיף ב")[0] and "סעיף ב" in text)
    check("where is the PDF: said", any("It's " in s and "in out" in s for s in speech), speech[-3:])
    print(f"{sum(checks)}/{len(checks)} passed   (files in {d})")
    sys.exit(0 if all(checks) else 1)


def load_state(d):
    root = f"{d}/support/study"
    for sid in os.listdir(root) if os.path.isdir(root) else []:
        p = f"{root}/{sid}/state.json"
        if os.path.exists(p): return json.load(open(p))
    return None


def ordered(text, words):
    pos = [text.find(w) for w in words]
    return all(p >= 0 for p in pos) and pos == sorted(pos)


def pdf_pages(path):
    code = ('import PDFKit; let d = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!; '
            'print(d.pageCount); for i in 0..<d.pageCount { print(d.page(at: i)?.string ?? "") }')
    out = subprocess.run(["swift", "-e", code, path], capture_output=True, text=True).stdout.split("\n", 1)
    return int(out[0] or 0), out[1] if len(out) > 1 else ""


if __name__ == "__main__":
    main()
