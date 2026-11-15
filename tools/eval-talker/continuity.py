#!/usr/bin/env python3
"""Continuity across a talker swap: a 12-question study session on Haiku where question 2 gives a fact
("my exam is on Thursday and it covers chapters 3 to 5") and question 12 needs it after the talker was
swapped for a fresh one. Compares the recap the app used to send (the last 8 exchanges, clipped to
200/300 characters) with the new one (`SessionSummary` + the last 5 exchanges, `CallController.recapLines`).

  python3 tools/eval-talker/continuity.py [--runs 2] [--label continuity]

Uses the real talker prompt and message format (run.py) and the real summarizer prompt (read from
SessionSummary.swift). ~25 small Haiku calls. Results in results/<label>.json.
"""
import argparse, base64, json, os, re, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import run as R           # noqa: E402
import scenarios as S     # noqa: E402

QUESTIONS = [
    "what's this lecture about?",
    "ok so my exam is on Thursday and it covers chapters 3 to 5",
    "what's the difference between the light reactions and the Calvin cycle",
    "where does the oxygen come from",
    "what is ATP for",
    "and NADPH?",
    "why are leaves green",
    "what's chlorophyll a versus b",
    "is photosynthesis just respiration backwards",
    "what's a good way to memorize the steps",
    "how long should I study each day",
]
FINAL = "so which chapters should I review tonight?"
CTX = S.LECTURE_CTX[:2]   # front app + document, no selection (it would make every question about one paragraph)


def summary_prompt():
    src = open(os.path.join(R.ROOT, "Sources/Poinky/SessionSummary.swift"), encoding="utf-8").read()
    m = re.search(r'static let prompt = """\n(.*?)\n\s*"""', src, re.S)
    out = ""
    for l in m.group(1).split("\n"):   # like Swift: a line ending in "\" continues, the others end with a newline
        l = l.strip()
        out += l[:-1] if l.endswith("\\") else l + "\n"
    return out.rstrip("\n")


class Session:
    """One `claude -p` stream-json session, like ClaudeCodeBrain (several questions, one process)."""
    def __init__(self, prompt, model="haiku"):
        exe = R.find_claude()
        args = [exe, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                "--include-partial-messages", "--model", model, "--tools", "", "--strict-mcp-config",
                "--disable-slash-commands", "--setting-sources", "", "--no-session-persistence",
                "--system-prompt", prompt, "--settings", '{"alwaysThinkingEnabled":false}']
        env = dict(os.environ, MAX_THINKING_TOKENS="0", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
        body = R.no_thinking_body(model)
        if body:
            env["CLAUDE_CODE_EXTRA_BODY"] = body
        self.dir = tempfile.mkdtemp(prefix="poinky-cont-")
        self.p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  cwd=self.dir, env=env)

    def ask(self, text, jpg=None):
        content = [{"type": "text", "text": text}]
        if jpg:
            img = base64.b64encode(open(jpg, "rb").read()).decode()
            content.insert(0, {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": img}})
        self.p.stdin.write((json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n").encode())
        self.p.stdin.flush()
        out, tokens = "", 0
        for raw in self.p.stdout:
            try:
                o = json.loads(raw)
            except ValueError:
                continue
            if o.get("type") == "stream_event":
                d = o.get("event", {}).get("delta", {})
                if d.get("type") == "text_delta":
                    out += d["text"]
            elif o.get("type") == "result":
                u = o.get("usage", {})
                tokens = sum(u.get(k, 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
                out = out or o.get("result", "")
                break
        return out, tokens

    def close(self):
        try:
            self.p.stdin.close(); self.p.wait(timeout=10)
        except Exception:
            self.p.kill()


def said(reply):
    return " ".join(m.strip() for m in re.findall(r"<say>([\s\S]*?)</say>", reply)) or reply.strip()


def message(q, recap=None):
    text = R.message_text(dict(said=q, ctx=CTX, cursor=(520, 230)))
    if recap:   # the app puts it right after the scene description
        text = text.replace("Nothing is drawn on screen right now.", "Nothing is drawn on screen right now.\n" + "\n".join(recap), 1)
    return text


def clip(s, n):
    t = s.replace("\n", " ").strip()
    return t[:n - 1] + "…" if len(t) > n else t


def old_recap(history):
    lines = ["(This session's earlier messages were cleared to keep you fast; old screenshots are gone. What was said, oldest first, so follow-ups still make sense:)"]
    return lines + [f"- User: {clip(u, 200)} / You: {clip(a, 300)}" for u, a in history[-8:]]


def new_recap(history, summary):
    lines = ["(This session's earlier messages were cleared to keep you fast; old screenshots are gone. So follow-ups still make sense:)"]
    if summary:
        m = re.search(r'lines\.append\("(The session so far(?:[^"\\]|\\.)*)" \+ gist\)', R._controller())
        lines.append(R.swift_literal(m.group(1)) + summary)   # the header CallController.recapLines uses
    lines.append("The last exchanges, oldest first:")
    return lines + [f"- User: {clip(u, 500)} / You: {clip(a, 1000)}" for u, a in history[-5:]]


def summary_message(summary, user, poinky):
    s = "Current summary:\n" + (summary or "(none yet: this is the start of the session)")
    s += f"\n\nNewest exchanges, oldest first:\n\nUser: {clip(user, 600)}\nPoinky: {clip(poinky, 1500)}"
    return s + "\n\nWrite the updated summary now (only the lines)."


def parse_summary(reply):
    # like SessionSummary.parse: every line but fences and headers, each starting with "- "
    lines = [l.strip() for l in reply.split("\n") if l.strip()]
    lines = [l for l in lines if not l.startswith("```") and not re.match(r"(current|updated) summary|here'?s|here is", l.lower())
             and not (l.endswith(":") and len(l) < 40)]
    lines = [l if l.startswith("- ") else "- " + (l[2:] if l.startswith(("* ", "• ")) else l) for l in lines]
    out, size = [], 0
    for l in lines:
        if size + len(l) + 1 > 1200:
            break
        out.append(l); size += len(l) + 1
    return "\n".join(out)


def knows_chapters(reply):
    """Says the exam's scope from question 2: chapters 3 to 5 (or 3, 4 and 5)."""
    s = said(reply).lower().replace("–", "-").replace("—", "-")
    return bool(re.search(r"\b(3|three)\s*(to|through|-|and)\s*(5|five)\b|\b(3|three),\s*(4|four),?\s*and\s*(5|five)\b", s))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=2, help="how many times to ask the last question per recap")
    ap.add_argument("--label", default="continuity")
    ap.add_argument("--rescore", nargs="*", help="score saved results/<label>.json again (no model calls)")
    ap.add_argument("--reuse-summary", action="store_true", help="with --reuse: also take its summary (only the last question is asked)")
    ap.add_argument("--reuse", help="take questions 1-11 and the talker's answers from results/<label>.json (only the summary and the last question are asked again)")
    a = ap.parse_args()
    if a.rescore:
        for label in a.rescore:
            r = json.load(open(os.path.join(HERE, "results", label + ".json")))["results"]
            print(label, "  ".join("%s: scope %d/%d, exam day %d/%d" % (k, sum(knows_chapters(x["reply"]) for x in v), len(v),
                                    sum("thursday" in said(x["reply"]).lower() for x in v), len(v)) for k, v in r.items()))
        return
    outdir = os.path.join(R.ROOT, "build", "eval-talker"); os.makedirs(outdir, exist_ok=True)
    jpg = R.render(next(s for s in S.SCENARIOS if s["id"] == "student-explain"), outdir)
    prompt = R.system_prompt()

    saved = json.load(open(os.path.join(HERE, "results", a.reuse + ".json"))) if a.reuse else {}
    old = saved.get("session")
    talker = None if old else Session(prompt)
    summarizer = None if a.reuse_summary else Session(summary_prompt())
    time.sleep(4)
    history, summary, log = [], "", []
    for i, q in enumerate(QUESTIONS, 1):
        if old:
            reply, tokens = "<say>%s</say>" % old[i - 1]["said"], old[i - 1]["tokens"]
        else:
            reply, tokens = talker.ask(message(q), jpg)
        history.append((q, said(reply)))
        t0 = time.time()
        if not summarizer:
            summary = saved["summary"]
            log.append(dict(q=q, said=said(reply), tokens=tokens))
            continue
        s, _ = summarizer.ask(summary_message(summary, q, said(reply)))
        if not parse_summary(s):
            print("    (summary reply not used: %r)" % s[:200])
        summary = parse_summary(s) or summary
        log.append(dict(q=q, said=said(reply), tokens=tokens, summary_ms=int((time.time() - t0) * 1000)))
        print(f"{i:2}. {q}\n    → {clip(said(reply), 140)}  [{tokens} tokens]")
    if talker:
        talker.close()
    if summarizer:
        summarizer.close()
    print("\nSummary (%d chars):\n%s\n" % (len(summary), summary))

    results = {}
    for name, recap in [("before", old_recap(history)), ("after", new_recap(history, summary))]:
        results[name] = []
        for _ in range(a.runs):
            fresh = Session(prompt)
            time.sleep(4)
            reply, tokens = fresh.ask(message(FINAL, recap), jpg)
            fresh.close()
            ok = knows_chapters(reply)
            results[name].append(dict(reply=reply, ok=ok, tokens=tokens))
            print(f"{name:6} {'PASS' if ok else 'FAIL'}: {clip(said(reply), 200)}")
    home = os.path.expanduser("~")
    path = os.path.join(HERE, "results", a.label + ".json")
    with open(path, "w", encoding="utf-8") as f:
        f.write(json.dumps(dict(session=log, summary=summary, final=FINAL, results=results),
                           indent=1, ensure_ascii=False).replace(home, "~"))
    print("\nbefore %d/%d, after %d/%d → %s" % (sum(r["ok"] for r in results["before"]), a.runs,
                                               sum(r["ok"] for r in results["after"]), a.runs, os.path.relpath(path, R.ROOT)))


if __name__ == "__main__":
    main()
