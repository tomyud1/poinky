#!/usr/bin/env python3
"""Grade a shot run: Claude looks at each sheet.png and scores the 3D explanation.

    python3 eval3d/grade.py eval3d/runs/NAME [--only heart,dna] [--model sonnet] [--jobs 4]

Writes grade.json in each question folder and prints a table plus the average. Scores are 1-10:
  looks      - does the model look like the real thing (detail, proportions, materials)?
  correct    - is it right (parts in the right places, right motion, right science)?
  staging    - can you see what matters (framing, sizes, nothing hidden, labels readable)?
  teaching   - do the steps and animations actually explain the answer?
"""
import argparse, concurrent.futures as cf, json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KEYS = ["looks", "correct", "staging", "teaching"]

PROMPT = """You are grading a 3D explanation made by an AI tutor. The user asked: "{q}"

Read the image {sheet}. It's a grid of snapshots taken while the tutor talked: each caption is the sentence being
spoken, in order, and the snapshot shows the 3D model at the end of that sentence.{errs}

Score each from 1 to 10 (10 = as good as a polished product demo, 5 = gets the idea across but looks crude or has
clear mistakes, 1 = broken or useless):
- looks: does the model look like the real thing (detail, proportions, materials)?
- correct: is it right (parts in the right places and orientation, right motion, right science)?
- staging: can you see what matters (framing, sizes, nothing important hidden or tiny, labels readable)?
- teaching: do the steps and animations actually explain the answer?

Then list the 1-3 most important problems, concretely (what's wrong in which snapshot).
Reply with only JSON: {{"looks": n, "correct": n, "staging": n, "teaching": n, "problems": ["..."]}}"""


def grade(d, q, model):
    errs = (d / "errors.txt").read_text().strip() if (d / "errors.txt").exists() else ""
    note = f"\n\nThe code also had these errors (the rest still ran):\n{errs[:1500]}" if errs else ""
    prompt = PROMPT.format(q=q, sheet=(d / "sheet.png").resolve(), errs=note)
    r = subprocess.run(["claude", "-p", "--model", model, "--allowedTools", "Read", "--output-format", "json", prompt],
                       capture_output=True, text=True, cwd=ROOT, timeout=300)
    try:
        text = json.loads(r.stdout).get("result", "")
        g = json.loads(re.search(r"\{[\s\S]*\}", text).group(0))
    except Exception as e:
        return {"error": f"{e}: {r.stdout[-300:]} {r.stderr[-300:]}"}
    (d / "grade.json").write_text(json.dumps(g, indent=2))
    return g


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--only", default="")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    qs = {q["id"]: q for q in json.loads((ROOT / "eval3d" / "questions.json").read_text())}
    dirs = sorted(d for d in Path(a.run).iterdir() if (d / "sheet.png").exists())
    if a.only:
        dirs = [d for d in dirs if d.name in a.only.split(",")]
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = dict(zip(dirs, ex.map(lambda d: grade(d, qs.get(d.name, {}).get("user", d.name), a.model), dirs)))
    tot = {k: [] for k in KEYS}
    print(f"{'':12s} " + " ".join(f"{k:>8s}" for k in KEYS))
    for d, g in res.items():
        if "error" in g:
            print(f"{d.name:12s} error: {g['error'][:200]}")
            continue
        for k in KEYS:
            tot[k].append(g.get(k, 0))
        print(f"{d.name:12s} " + " ".join(f"{g.get(k, 0):8}" for k in KEYS))
        for p in g.get("problems", []):
            print(f"{'':14s}- {p}")
    if tot["looks"]:
        print(f"{'average':12s} " + " ".join(f"{sum(v) / len(v):8.1f}" for v in tot.values()))


if __name__ == "__main__":
    main()
