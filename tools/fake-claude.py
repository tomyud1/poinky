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
  limited answers with a rejected rate_limit_event (resets in an hour) and Claude Code's usage-limit error
FAKE_TOKENS_PER_TURN: talker results report usage growing by that many input tokens per message (size-based rotation).
Breaking it on purpose (tools/test-call-loop.py):
  FAKE_CLAUDE_REPLIES  a JSON list of talker replies, used in order (the last one repeats)
  FAKE_FIRST_TOKEN_SECS  wait this long before the first word (an interrupt still ends the turn)
  FAKE_PIECES / FAKE_PIECE_SECS  stream each reply in this many pieces (default 2), this far apart (0.05)
  FAKE_CRASH_AFTER=N   the talker exits after its Nth answer (Claude Code dying between questions)
  FAKE_ARTIST_MODE     the teacher: answer (FAKE_ARTIST_REPLY) / crash / hang / fail
  FAKE_SEARCH_MODE / FAKE_SEARCH_SECS  the web searcher: answer after that many seconds (default 0.3) / hang
`--version` and `auth status` answer like the real CLI (signed in, except in "signedout" mode).
Interrupt control_requests end the current turn with an error_during_execution result (like the real one),
except in "deaf" mode.
"""
import json, os, queue, sys, threading, time

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
role = ("summarizer" if summarizes else "notes" if writes_notes else "artist" if "teacher behind Poinky" in prompt
        else "searcher" if "look things up on the web for Poinky" in prompt
        else "guide" if "Poinky's guide" in prompt or "Poinky's hands" in prompt else "talker")
busy = False
turns = 0
if mode == "stuffed":
    time.sleep(3600); sys.exit(0)

inbox = queue.Queue()
def reader():
    for line in sys.stdin:
        try: inbox.put(json.loads(line))
        except ValueError: pass
    inbox.put(None)
threading.Thread(target=reader, daemon=True).start()
held = []   # questions that arrived while a reply was streaming

def interrupted(secs):
    """Waits `secs`, watching for an interrupt (True: the turn was interrupted and its result sent)."""
    end = time.time() + secs
    while True:
        left = end - time.time()
        if left <= 0: return False
        try: m = inbox.get(timeout=left)
        except queue.Empty: return False
        if m is None: sys.exit(0)
        if m.get("type") == "control_request":
            note("interrupt")
            out({"type": "control_response", "response": {"subtype": "success", "request_id": m.get("request_id")}})
            if mode != "deaf":
                out({"type": "result", "subtype": "error_during_execution", "is_error": True, "result": ""})
                return True
        else:
            held.append(m)

def stream(reply, first_wait=0.0):
    if interrupted(first_wait): return False
    n = max(1, int(os.environ.get("FAKE_PIECES", "2")))
    size = max(1, -(-len(reply) // n))
    gap = float(os.environ.get("FAKE_PIECE_SECS", "0.05"))
    for k in range(0, max(len(reply), 1), size):
        out({"type": "stream_event", "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": reply[k:k + size]}}})
        if interrupted(gap): return False
    return True

while True:
    msg = held.pop(0) if held else inbox.get()
    if msg is None: break
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
    note(f"pid {os.getpid()} {role} question: " + json.dumps(text))
    if mode == "crash": sys.exit(3)
    if mode == "signedout":
        out({"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in · Please run /login"})
        continue
    if mode == "limited":
        out({"type": "rate_limit_event", "rate_limit_info": {"status": "rejected", "resetsAt": int(time.time()) + 3600}})
        out({"type": "result", "subtype": "success", "is_error": True, "result": "Claude AI usage limit reached|" + str(int(time.time()) + 3600)})
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
    if role == "searcher":
        if os.environ.get("FAKE_SEARCH_MODE") == "hang": busy = True; continue
        if interrupted(float(os.environ.get("FAKE_SEARCH_SECS", "0.3"))): continue
        out({"type": "result", "subtype": "success", "is_error": False, "result": "- It is sunny today (example.com)"})
        continue
    if role == "artist":
        amode = os.environ.get("FAKE_ARTIST_MODE", "answer")
        if amode == "crash": sys.exit(3)
        if amode == "hang": busy = True; continue
        if amode == "fail":
            out({"type": "result", "subtype": "success", "is_error": True, "result": "API Error: 500 internal"}); continue
        reply = os.environ.get("FAKE_ARTIST_REPLY", '<lesson title="Fake"><say>Here is the sketch.</say><step>[{"op":"text","x":40,"y":40,"text":"hi"}]</step></lesson>')
    else:
        replies = json.loads(os.environ["FAKE_CLAUDE_REPLIES"]) if os.environ.get("FAKE_CLAUDE_REPLIES") else [os.environ.get("FAKE_CLAUDE_REPLY", "<say>Fake answer.</say>")]
        reply = replies[min(turns, len(replies) - 1)]
    first = float(os.environ.get("FAKE_FIRST_TOKEN_SECS", "0")) if role == "talker" else 0.0
    turns += 1
    if not stream(reply, first): continue
    per = int(os.environ.get("FAKE_TOKENS_PER_TURN", "0"))
    usage = {"input_tokens": 3, "cache_read_input_tokens": per * turns, "output_tokens": 20} if per else None
    out({"type": "result", "subtype": "success", "is_error": False, "result": reply, **({"usage": usage} if usage else {})})
    if role == "talker" and os.environ.get("FAKE_CRASH_AFTER") and turns >= int(os.environ["FAKE_CRASH_AFTER"]):
        note(f"pid {os.getpid()} exits after {turns} answers"); sys.exit(3)
