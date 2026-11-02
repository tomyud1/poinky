#!/usr/bin/env python3
"""A stand-in for `claude` that replays a recorded helper run, so helpers can be tested
(and their animations and sounds tuned) without spending tokens.

Poinky uses it instead of Claude Code when POINKY_HELPER_CMD points at this file:

    POINKY_HELPER_CMD=tools/fake-helper.py build/Poinky.app/Contents/MacOS/Poinky --helper-test out.txt fix-bug,todo-blocked

It speaks the same protocol as `claude -p --input-format stream-json --output-format stream-json`:
user messages come in on stdin (one JSON per line), events go out on stdout.

Which run it plays (from tools/helper-runs/):
  - POINKY_FAKE_RUN=<name or path>, or
  - "fixture:<name>" anywhere in the first message, or
  - fix-bug.
POINKY_FAKE_SPEED=4 plays four times faster.

Like Claude Code: a message that arrives while it works is folded into the current turn; one that
arrives after a turn ended starts a new turn; when stdin closes it finishes the turn and exits.
"""
import json, os, queue, re, sys, threading, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "helper-runs")
SPEED = float(os.environ.get("POINKY_FAKE_SPEED", "1") or 1)

inbox = queue.Queue()

def read_stdin():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        content = (msg.get("message") or {}).get("content", "")
        if isinstance(content, list):
            content = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
        inbox.put(content)
    inbox.put(None)   # stdin closed

def emit(obj):
    obj = {k: v for k, v in obj.items() if k != "_t"}
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

def load(name):
    path = name if os.path.sep in name or name.endswith(".jsonl") else os.path.join(RUNS, name + ".jsonl")
    with open(path) as f:
        lines = [json.loads(l) for l in f if l.strip()]
    # Split into turns: each ends with a result (or an exit).
    turns, cur = [], []
    for o in lines:
        cur.append(o)
        if o.get("type") in ("result", "_exit"):
            turns.append(cur); cur = []
    if cur:
        turns.append(cur)
    return turns

def main():
    threading.Thread(target=read_stdin, daemon=True).start()
    first = inbox.get()
    if first is None:
        return 0
    m = re.search(r"fixture:([\w-]+)", first)
    name = os.environ.get("POINKY_FAKE_RUN") or (m.group(1) if m else "fix-bug")
    try:
        turns = load(name)
    except OSError as e:
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "duration_ms": 0,
              "result": f"fake-helper: no run named {name!r} ({e})", "session_id": ""})
        return 1
    session = str(uuid.uuid4())
    emit({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": session,
          "model": "fake-helper", "permissionMode": "acceptEdits"})

    closed = False
    def play(turn, extra=None):
        """Plays one turn with its recorded timing. Returns an exit code if the run ends the process."""
        nonlocal closed
        folded = []
        t_prev = None
        start = time.time()
        for o in turn:
            t = o.get("_t", 0)
            if o.get("type") == "system":   # keeps the delay between start-up and the first step
                t_prev = t
                continue
            if t_prev is not None:
                deadline = time.time() + max(0, (t - t_prev)) / SPEED
                while True:   # wait, while picking up messages that arrive mid-turn
                    left = deadline - time.time()
                    if left <= 0:
                        break
                    try:
                        msg = inbox.get(timeout=left)
                        if msg is None:
                            closed = True
                        else:
                            folded.append(msg)
                    except queue.Empty:
                        pass
            t_prev = t
            if o.get("type") == "_exit":
                return o.get("code", 1)
            if o.get("type") == "result":
                o = dict(o, session_id=session, duration_ms=int((time.time() - start) * 1000))
                notes = folded + ([extra] if extra else [])
                if notes:
                    o["result"] = (o.get("result") or "") + " Also handled: " + "; ".join(notes)
            elif "session_id" in o:
                o = dict(o, session_id=session)
            emit(o)
        return None

    code = play(turns[0])
    if code is not None:
        return code
    i = 1
    while not closed:
        msg = inbox.get()
        if msg is None:
            break
        if i < len(turns):
            code = play(turns[i]); i += 1
        else:   # a canned short turn for any further message
            code = play([
                {"type": "assistant", "_t": 0, "message": {"role": "assistant", "content": [{"type": "text", "text": "On it."}]}},
                {"type": "assistant", "_t": 1.0, "message": {"role": "assistant", "content": [
                    {"type": "tool_use", "id": "toolu_fake_" + str(i), "name": "Read", "input": {"file_path": os.path.join(os.getcwd(), "README.md")}}]}},
                {"type": "result", "subtype": "success", "is_error": False, "_t": 2.5, "result": "Done: " + msg},
            ])
        if code is not None:
            return code
    return 0

if __name__ == "__main__":
    sys.exit(main())
