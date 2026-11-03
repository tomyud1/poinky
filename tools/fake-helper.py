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

A run can ask for permission (or ask a question), like Claude Code with --permission-prompt-tool stdio:
a line {"type": "_ask", "_t": ..., "request": {...can_use_tool...}, "allow": [...], "deny": [...]} sends a
control_request and waits (as long as it takes) for the matching control_response, then plays the
"allow" or "deny" events (their _t: seconds after the answer). In them, {answers} becomes the answers
given to a question (JSON), {permissions} the permission changes sent with a yes, and {message} the
reason given with a no.

An interrupt (control_request subtype "interrupt", as Poinky sends for "wait") ends the current turn
right away with an error_during_execution result; the next message gets a short canned turn.

With --replay-user-messages each message is echoed back with a uuid (a checkpoint). A rewind_files
request (undo) answers like Claude Code: with dry_run, the files it would put back (README.md in its
folder); otherwise it writes the checkpoint it was given to .fake-undo in its folder, for tests to check.
A line {"type": "_write", "path": "rel/path", "text": "..."} writes that file in its folder (for worktree tests).
"""
import json, os, queue, re, sys, threading, time, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
RUNS = os.path.join(HERE, "helper-runs")
SPEED = float(os.environ.get("POINKY_FAKE_SPEED", "1") or 1)

inbox = queue.Queue()      # user messages (text), None when stdin closes
answers = {}               # control responses by request id
answered = threading.Condition()
INTERRUPT = ("interrupt",)  # put in the inbox when Poinky interrupts the current turn
out_lock = threading.Lock()

def read_stdin():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        req = msg.get("request") or {}
        if msg.get("type") == "control_request" and req.get("subtype") == "rewind_files":
            body = {"canRewind": True}
            if req.get("dry_run"):
                body.update({"filesChanged": [os.path.join(os.getcwd(), "README.md")], "insertions": 1, "deletions": 1})
            else:
                with open(os.path.join(os.getcwd(), ".fake-undo"), "w") as f:
                    f.write(str(req.get("user_message_id")))
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": msg.get("request_id"), "response": body}})
            continue
        if msg.get("type") == "control_request" and req.get("subtype") == "interrupt":
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": msg.get("request_id"), "response": {}}})
            inbox.put(INTERRUPT)
            continue
        if msg.get("type") == "control_response":
            r = msg.get("response") or {}
            with answered:
                answers[r.get("request_id")] = r.get("response") or {}
                answered.notify_all()
            continue
        content = (msg.get("message") or {}).get("content", "")
        if isinstance(content, list):
            content = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
        if "--replay-user-messages" in sys.argv:
            echo = {"type": "user", "message": {"role": "user", "content": content}, "uuid": str(uuid.uuid4()), "isReplay": True}
            if started.is_set():
                emit(echo)
            else:
                first_echo.append(echo)   # after the session starts
        inbox.put(content)
    inbox.put(None)   # stdin closed
    with answered:
        answered.notify_all()

stdin_closed = threading.Event()
started = threading.Event()   # the session is up (its first message is echoed after that)
first_echo = []

def wait_answer(rid):
    """Waits (forever, like Claude Code) for the answer to a request. None if stdin closed first."""
    with answered:
        while rid not in answers:
            if stdin_closed.is_set():
                return None
            answered.wait(0.2)
        return answers.pop(rid)

def emit(obj):
    obj = {k: v for k, v in obj.items() if k != "_t"}
    with out_lock:
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
    # POINKY_FAKE_NO_AUTO=1: like a Claude Code without auto mode (fails before starting).
    argv = sys.argv[1:]
    if os.environ.get("POINKY_FAKE_NO_AUTO") == "1" and "--permission-mode" in argv and argv[argv.index("--permission-mode") + 1] == "auto":
        sys.stderr.write("Error: permission mode auto is not available\n")
        return 1
    threading.Thread(target=read_stdin, daemon=True).start()
    first = inbox.get()
    if first is None:
        return 0
    m = re.search(r"fixture:([\w-]+)", first)
    # --resume <id>: the same session goes on (as Claude Code does).
    session = argv[argv.index("--resume") + 1] if "--resume" in argv else str(uuid.uuid4())
    if "--resume" in argv and not m and not os.environ.get("POINKY_FAKE_RUN"):
        # Picking up an earlier session: a short turn about what it was asked now.
        emit({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": session, "model": "fake-helper", "permissionMode": "auto"})
        started.set()
        for e in first_echo:
            emit(e)
        play_canned = [
            {"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "Picking up where I left off."}]}},
            {"type": "assistant", "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": "toolu_resume", "name": "Read", "input": {"file_path": os.path.join(os.getcwd(), "README.md")}}]}},
            {"type": "result", "subtype": "success", "is_error": False, "session_id": session, "duration_ms": 900,
             "result": "Continued the same session: " + first.split("\n\n")[1 if "\n\n" in first else 0][:120]},
        ]
        for o in play_canned:
            time.sleep(0.6 / SPEED)
            emit(o)
        while inbox.get() is not None:
            pass
        return 0
    name = os.environ.get("POINKY_FAKE_RUN") or (m.group(1) if m else "fix-bug")
    try:
        turns = load(name)
    except OSError as e:
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "duration_ms": 0,
              "result": f"fake-helper: no run named {name!r} ({e})", "session_id": ""})
        return 1

    mode = argv[argv.index("--permission-mode") + 1] if "--permission-mode" in argv else "default"
    emit({"type": "system", "subtype": "init", "cwd": os.getcwd(), "session_id": session,
          "model": "fake-helper", "permissionMode": mode})
    started.set()
    for e in first_echo:
        emit(e)

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
                        if msg is INTERRUPT:
                            emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": session,
                                  "duration_ms": int((time.time() - start) * 1000), "result": ""})
                            return "interrupted"
                        if msg is None:
                            closed = True
                            stdin_closed.set()
                        else:
                            folded.append(msg)
                    except queue.Empty:
                        pass
            t_prev = t
            if o.get("type") == "_ask":
                rid = str(uuid.uuid4())
                emit({"type": "control_request", "request_id": rid, "request": o["request"]})
                # Messages that arrive while it waits are folded in, as usual.
                got = threading.Event()
                def collect():
                    while not stdin_closed.is_set() and not got.is_set():
                        try:
                            msg = inbox.get(timeout=0.2)
                        except queue.Empty:
                            continue
                        if msg is None:
                            stdin_closed.set()
                            with answered:
                                answered.notify_all()
                            return
                        if msg is not INTERRUPT:
                            folded.append(msg)
                collector = threading.Thread(target=collect, daemon=True)
                collector.start()
                resp = wait_answer(rid)
                got.set()
                collector.join()
                if resp is None:
                    return 1   # nobody to answer: Claude Code would end too
                allowed = resp.get("behavior") == "allow"
                given = json.dumps(((resp.get("updatedInput") or {}).get("answers")) or {})
                branch = json.dumps(o.get("allow" if allowed else "deny", []))
                perms = json.dumps(resp.get("updatedPermissions") or [])
                branch = branch.replace("{answers}", given.replace('"', "'")).replace("{message}", (resp.get("message") or "").replace('"', "'"))
                branch = branch.replace("{permissions}", perms.replace('"', "'"))
                prev = 0
                for b in json.loads(branch):
                    time.sleep(max(0, b.get("_t", 0) - prev) / SPEED)
                    prev = b.get("_t", 0)
                    emit(dict(b, session_id=session) if "session_id" in b else b)
                continue
            if o.get("type") == "_write":   # a file it writes (relative to its folder), for worktree tests
                path = os.path.join(os.getcwd(), o["path"])
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "w") as f:
                    f.write(o.get("text", ""))
                continue
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
    if code not in (None, "interrupted"):
        return code
    i = 1
    if code == "interrupted":
        i = len(turns)   # what's left of the recording no longer fits: canned turns from here
    while not closed:
        msg = inbox.get()
        if msg is None:
            break
        if msg is INTERRUPT:
            continue
        if i < len(turns):
            code = play(turns[i]); i += 1
        else:   # a canned short turn for any further message
            code = play([
                {"type": "assistant", "_t": 0, "message": {"role": "assistant", "content": [{"type": "text", "text": "On it."}]}},
                {"type": "assistant", "_t": 1.0, "message": {"role": "assistant", "content": [
                    {"type": "tool_use", "id": "toolu_fake_" + str(i), "name": "Read", "input": {"file_path": os.path.join(os.getcwd(), "README.md")}}]}},
                {"type": "result", "subtype": "success", "is_error": False, "_t": 2.5, "result": "Done: " + msg},
            ])
        if code == "interrupted":
            i = len(turns)
        elif code is not None:
            return code
    return 0

if __name__ == "__main__":
    sys.exit(main())
