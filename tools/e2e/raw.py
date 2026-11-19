#!/usr/bin/env python3
"""tools/e2e/raw.py <rundir> [--all]: the talker / teacher replies of a run (raw.jsonl), skipping the summarizer."""
import json, sys
d = sys.argv[1]
for l in open(d + "/raw.jsonl"):
    o = json.loads(l)
    p = o["prompt"]
    role = "talker" if p.startswith("You are Poinky") else "teacher" if "teacher" in p[:40] else p[:30]
    if role.startswith("You keep") and "--all" not in sys.argv: continue
    q = o["q"]
    said = q[q.find("User said"):][:200] if "User said" in q else q[:160]
    print(f"=== {role} ({o['model']}) {o.get('error') or ''}\nQ: {said!r}\nR: {o['reply']}\n")
