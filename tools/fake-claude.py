#!/usr/bin/env python3
"""A stand-in for `claude -p --input-format stream-json` in tests of Poinky's call loop (no tokens).

FAKE_CLAUDE_MODE:
  answer  (default) streams FAKE_CLAUDE_REPLY (default "<say>Fake answer.</say>") and a result for each message;
          a note-writer session answers with a note (plus "ABOUT: $FAKE_NOTE_ABOUT" if set);
          a session-summary session answers with the current summary's lines plus "- Asked: <question>" for
          each new exchange (FAKE_SUMMARY_MODE=hang: the summarizer never answers; fail: it answers with an error)
  hang    reads messages and never answers (the stall watchdog / stuck detector must recover)
  deaf    never answers and ignores interrupts too
  crash   exits as soon as a message arrives
  stuffed never reads its input (a Claude Code that hangs while starting): a big message can't be written to it
  signedout  answers every message with Claude Code's "Not logged in" error; `auth status` says loggedIn false
FAKE_TOKENS_PER_TURN: talker results report usage growing by that many input tokens per message (size-based rotation).
`--version` and `auth status` answer like the real CLI (signed in, except in "signedout" mode).
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
if "--version" in argv:
    print("2.1.300 (Claude Code)"); sys.exit(0)
if argv[1:3] == ["auth", "status"]:
    print(json.dumps({"loggedIn": mode != "signedout", "authMethod": "claude.ai"}, indent=2)); sys.exit(1 if mode == "signedout" else 0)
prompt = argv[argv.index("--system-prompt") + 1] if "--system-prompt" in argv else ""
writes_notes = "private notes" in prompt
summarizes = "running summary of one voice session" in prompt
note(f"start pid {os.getpid()} identity={'## Who you are' in prompt} about_me={'## About the user' in prompt} notes={'## Recent sessions' in prompt} note_writer={writes_notes} summarizer={summarizes}")
busy = False
turns = 0
if mode == "stuffed":
    time.sleep(3600); sys.exit(0)
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
    if mode == "signedout":
        out({"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in · Please run /login"})
        continue
    if mode in ("hang", "deaf"): busy = True; continue
    if summarizes:
        smode = os.environ.get("FAKE_SUMMARY_MODE", "answer")
        if smode == "hang": busy = True; continue
        if smode == "fail":
            out({"type": "result", "subtype": "success", "is_error": True, "result": "API Error: 529 overloaded"}); continue
        cur = text.split("Newest exchanges", 1)[0]
        lines = [l for l in cur.split("\n") if l.startswith("- ")]
        lines += ["- Asked: " + l[6:] for l in text.split("\n") if l.startswith("User: ")]
        time.sleep(float(os.environ.get("FAKE_SUMMARY_SECS", "0.3")))
        out({"type": "result", "subtype": "success", "is_error": False, "result": "\n".join(lines[-12:])})
        continue
    if writes_notes:
        extra = ("\nABOUT: " + os.environ["FAKE_NOTE_ABOUT"]) if os.environ.get("FAKE_NOTE_ABOUT") else ""
        out({"type": "result", "subtype": "success", "is_error": False, "result": "- The user tested Poinky with fake questions." + extra})
        continue
    reply = os.environ.get("FAKE_CLAUDE_REPLY", "<say>Fake answer.</say>")
    for piece in [reply[:len(reply)//2], reply[len(reply)//2:]]:
        out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": piece}}})
        time.sleep(0.05)
    turns += 1
    per = int(os.environ.get("FAKE_TOKENS_PER_TURN", "0"))
    usage = {"input_tokens": 3, "cache_read_input_tokens": per * turns, "output_tokens": 20} if per else None
    out({"type": "result", "subtype": "success", "is_error": False, "result": reply, **({"usage": usage} if usage else {})})
