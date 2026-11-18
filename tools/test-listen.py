#!/usr/bin/env python3
"""Runs the scripted listening scenarios in tools/listen-test/*.json through the built app (`--listen-test`):
the talk keys and the recognized words are scripted (no microphone, no keyboard), the call loop, the overlay and
the buddy's bubble are real. Answers come from tools/fake-claude.py (no tokens); audio plays at volume 0.

  tools/test-listen.py [name-filter]        (POINKY_APP=path/to/Poinky.app, default build/Poinky.app)

Each run draws the buddy on the real screen for ~10 s, with scratch settings (POINKY_SUPPORT_DIR). Prints each
probe's ok / FAIL line; the overlay's call log and the timeline of a run are kept in the printed folder.
"""
import json, os, subprocess, sys, tempfile

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
app = os.environ.get("POINKY_APP", os.path.join(root, "build", "Poinky.app"))
only = sys.argv[1] if len(sys.argv) > 1 else ""
work = tempfile.mkdtemp(prefix="poinky-listen-")
failed = 0
for name in sorted(os.listdir(os.path.join(root, "tools", "listen-test"))):
    if not name.endswith(".json") or only not in name:
        continue
    path = os.path.join(root, "tools", "listen-test", name)
    scenario = json.load(open(path))
    run = os.path.join(work, name[:-5])
    support = os.path.join(run, "support")
    os.makedirs(support)
    json.dump({"sounds": False, "voiceEngine": "apple", "homeShown": True, "buddyAutoHide": 0, "receipts": False,
               "conversationLog": False, "memoryEnabled": False, "checkForUpdates": False}, open(os.path.join(support, "config.json"), "w"))
    env = {"POINKY_SUPPORT_DIR": support, "POINKY_CLAUDE_CMD": os.path.join(root, "tools", "fake-claude.py"),
           "POINKY_MUTE": "1", "POINKY_OVERLAY_LOG": os.path.join(run, "overlay.log"),
           "POINKY_TIMELINE_DIR": os.path.join(run, "timeline"), **(scenario.get("env") or {})}
    out = os.path.join(run, "out.txt")
    cmd = ["open", "-n", "-g", "-W"] + sum([["--env", f"{k}={v}"] for k, v in env.items()], []) + \
          [app, "--args", "--listen-test", path, out, "--quit-after", "30"]
    print(name)
    subprocess.run(cmd, timeout=60)
    lines = open(out).read().splitlines() if os.path.exists(out) else ["FAIL no output"]
    checks = [l for l in lines if l.startswith(("ok", "FAIL"))]
    for l in checks:
        print("  " + l)
    if not checks or any(l.startswith("FAIL") for l in checks):
        failed += 1
print(f"(runs in {work})")
sys.exit(1 if failed else 0)
