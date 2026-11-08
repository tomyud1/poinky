#!/usr/bin/env python3
"""A stand-in for `claude -p --input-format stream-json` in tests of Poinky's call loop (no tokens).

FAKE_CLAUDE_MODE:
  answer  (default) streams "<say>Fake answer.</say>" and a result for each message
  hang    reads messages and never answers (the stall watchdog / stuck detector must recover)
  deaf    never answers and ignores interrupts too
  crash   exits as soon as a message arrives
Interrupt control_requests end the current turn with an error_during_execution result (like the real one),
except in "deaf" mode.
"""
import json, os, sys, time

mode = os.environ.get("FAKE_CLAUDE_MODE", "answer")
log = os.environ.get("FAKE_CLAUDE_LOG")

def out(o):
    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()

def note(s):
    if log:
        with open(log, "a") as f: f.write(f"{time.time():.3f} {s}\n")

argv = sys.argv
prompt = argv[argv.index("--system-prompt") + 1] if "--system-prompt" in argv else ""
writes_notes = "private notes" in prompt
note(f"start pid {os.getpid()} identity={'## Who you are' in prompt} about_me={'## About the user' in prompt} notes={'## Recent sessions' in prompt} note_writer={writes_notes}")
busy = False
for line in sys.stdin:
    try: msg = json.loads(line)
    except ValueError: continue
    t = msg.get("type")
    if t == "control_request":
        note("interrupt")
        out({"type": "control_response", "response": {"subtype": "success", "request_id": msg.get("request_id")}})
        if busy and mode != "deaf":
            busy = False
            out({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": ""})
        continue
    if t != "user": continue
    text = " ".join(c.get("text", "") for c in msg["message"]["content"] if c.get("type") == "text")
    note(f"pid {os.getpid()} question: " + json.dumps(text))
    if mode == "crash": sys.exit(3)
    if mode in ("hang", "deaf"): busy = True; continue
    if writes_notes:
        out({"type": "result", "subtype": "success", "is_error": False, "result": "- The user tested Poinky with fake questions."})
        continue
    for piece in ["<say>Fake ", "answer.</say>"]:
        out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": piece}}})
        time.sleep(0.05)
    out({"type": "result", "subtype": "success", "is_error": False, "result": "<say>Fake answer.</say>"})
