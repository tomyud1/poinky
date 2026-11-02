#!/usr/bin/env python3
"""Ask the real teacher (artist) prompt for 3D answers, the way the app does, and save the replies.

    python3 eval3d/run.py [--model sonnet] [--only iron-dome,heart] [--jobs 4] [--out eval3d/runs/NAME]

Each question runs in its own `claude -p` session (same flags as ClaudeCodeBrain). A question with a
"followup" sends a second message in the same session, like a follow-up in a call. Saves, per question:
reply.txt (or reply-1.txt / reply-2.txt) and timing.json (time to first text, to the 3D model's
opening tag, to its closing tag, and to the end).
"""
import argparse, concurrent.futures as cf, json, os, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def message(q, followup=False):
    lines = [f"Brief from the talker: {q['brief']}",
             f"User said: \"{q['user']}\"",
             "Talker said: \"Sure, let me build it for you.\"",
             "Screenshot size: 1512x982 px (coordinates use this size).",
             "(No screenshot is attached in this test. The user is looking at a web page in the middle of the screen.)",
             "Already drawn on screen:\n- scene3d id=\"(from your previous reply)\"" if followup else "Nothing is drawn on screen right now.",
             "Paper room: 800 units wide, about 520 units tall before it runs out of space. Keep the lesson within that (use newpage for more)."]
    return "\n".join(lines)


def ask(proc, text):
    """Send one user message; return (reply, timings)."""
    t0 = time.time()
    proc.stdin.write(json.dumps({"type": "user", "message": {"role": "user", "content": [{"type": "text", "text": text}]}}) + "\n")
    proc.stdin.flush()
    reply, first, open3d, close3d = "", None, None, None
    for line in proc.stdout:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "stream_event":
            ev = obj.get("event", {})
            d = ev.get("delta", {})
            if ev.get("type") == "content_block_delta" and d.get("type") == "text_delta":
                reply += d["text"]
                now = time.time() - t0
                first = first if first is not None else now
                if open3d is None and "<scene3d" in reply: open3d = now
                if close3d is None and "</scene3d>" in reply: close3d = now
        elif obj.get("type") == "assistant" and not reply:
            reply = "".join(c.get("text", "") for c in obj.get("message", {}).get("content", []) if c.get("type") == "text")
        elif obj.get("type") == "result":
            if obj.get("is_error"):
                raise RuntimeError(obj.get("result"))
            break
    total = time.time() - t0
    return reply, {"first_text_s": first, "scene_open_s": open3d, "scene_close_s": close3d, "total_s": round(total, 2), "chars": len(reply)}


def run_one(q, model, out, prompt):
    d = out / q["id"]
    d.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, MAX_THINKING_TOKENS="0")
    proc = subprocess.Popen(
        ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--include-partial-messages", "--model", model, "--tools", "", "--strict-mcp-config",
         "--disable-slash-commands", "--setting-sources", "", "--settings", '{"alwaysThinkingEnabled":false}',
         "--no-session-persistence", "--system-prompt", prompt],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env, cwd=str(d))
    try:
        timings = {}
        reply, timings["turn1"] = ask(proc, message(q))
        (d / ("reply-1.txt" if q.get("followup") else "reply.txt")).write_text(reply)
        if q.get("followup"):
            f = dict(q, **q["followup"])
            reply2, timings["turn2"] = ask(proc, message(f, followup=True))
            (d / "reply-2.txt").write_text(reply2)
        (d / "timing.json").write_text(json.dumps(timings, indent=1))
        return q["id"], timings
    finally:
        proc.stdin.close()
        proc.terminate()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--only", default="")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--out", default="")
    ap.add_argument("--prompt", default=str(ROOT / "prompts" / "artist-prompt.md"))
    a = ap.parse_args()
    qs = json.loads((ROOT / "eval3d" / "questions.json").read_text())
    if a.only:
        keep = set(a.only.split(","))
        qs = [q for q in qs if q["id"] in keep]
    out = Path(a.out) if a.out else ROOT / "eval3d" / "runs" / time.strftime("%Y%m%d-%H%M%S")
    out.mkdir(parents=True, exist_ok=True)
    prompt = Path(a.prompt).read_text()
    print(f"{len(qs)} questions → {out}", flush=True)
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = {ex.submit(run_one, q, a.model, out, prompt): q["id"] for q in qs}
        for f in cf.as_completed(futs):
            try:
                qid, t = f.result()
                t1 = t["turn1"]
                print(f"{qid:12s} first {t1['first_text_s'] or 0:5.1f}s  3D open {t1['scene_open_s'] or 0:5.1f}s  closed {t1['scene_close_s'] or 0:5.1f}s  total {t1['total_s']:5.1f}s  {t1['chars']} chars", flush=True)
            except Exception as e:
                print(f"{futs[f]:12s} FAILED: {e}", flush=True)
    print(out)


if __name__ == "__main__":
    main()
