#!/usr/bin/env python3
"""What the session-note writer adds to the user's "About me" (user.md), on six real sessions from a tester's
runs (names changed): five where it used to add trivia (the app in use, a page they viewed, a name Poinky called
them or read off a homework sheet, a sister's birthday the talker had already remembered) and one where the user
says what they study and how they like answers. The real note prompt (`DailyNotes.notePrompt`), the model the app
uses (the talker's, no thinking), the session text built like `writeDailyNote`, and the app's own filter
(`UserFacts.aboutLines`, built from the source).

  python3 tools/eval-talker/about-me.py --runs 2 --label mine     # ~12 Haiku calls
  python3 tools/eval-talker/about-me.py --before                  # score the replies saved from the tester's runs
"""
import argparse, json, os, re, subprocess, sys, tempfile, concurrent.futures as cf

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import run as R  # noqa: E402

SESSIONS = json.load(open(os.path.join(HERE, "about-me-sessions.json"), encoding="utf-8"))
SRC = [os.path.join(ROOT, "Sources/Poinky/UserFacts.swift"), os.path.join(ROOT, "tools/tests/user-facts/main.swift")]


def note_prompt():
    src = open(os.path.join(ROOT, "Sources/Poinky/Identity.swift"), encoding="utf-8").read()
    m = re.search(r'static let notePrompt = """\n(.*?)\n\s*"""', src, re.S)
    lines = [l.strip() for l in m.group(1).split("\n")]
    text = "".join(l[:-1] if l.endswith("\\") else l + "\n" for l in lines)
    return text.replace('\\"', '"').strip()


def session_text(s):
    text = "\n\n".join(f"User: {e['user']}\nPoinky: {e['poinky']}" for e in s["exchanges"])
    return f"A running summary of the whole session:\n{s['summary']}\n\nIts last exchanges:\n\n" + text


def kept(replies):
    exe = os.path.join(ROOT, "build", "eval-talker", "user-facts")
    if not os.path.exists(exe) or os.path.getmtime(exe) < max(os.path.getmtime(f) for f in SRC):
        os.makedirs(os.path.dirname(exe), exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", exe] + SRC, check=True)
    items = [{"reply": r, "userLines": [e["user"] for e in s["exchanges"]] + re.findall(r"«([^»]+)»", s["summary"])}
             for s, r in replies]
    return json.loads(subprocess.run([exe], input=json.dumps(items).encode(), capture_output=True, check=True).stdout)


def ask(prompt, text, workdir):
    exe = R.find_claude()
    args = [exe, "-p", "--output-format", "json", "--model", "haiku", "--tools", "", "--strict-mcp-config",
            "--disable-slash-commands", "--setting-sources", "", "--no-session-persistence",
            "--system-prompt", prompt, "--settings", '{"alwaysThinkingEnabled":false}']
    env = dict(os.environ, MAX_THINKING_TOKENS="0", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    body = R.no_thinking_body("haiku")
    if body:
        env["CLAUDE_CODE_EXTRA_BODY"] = body
    out = subprocess.run(args, input=text.encode(), capture_output=True, cwd=workdir, env=env, timeout=90).stdout
    return json.loads(out).get("result", "")


def verdict(s, facts):
    if not s["expect"] or (s.get("allowNothing") and not facts):
        return not facts
    return 1 <= len(facts) <= 2 and all(any(re.search(p, f, re.I) for p in s["expect"]) for f in facts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--label", default="about-me")
    ap.add_argument("--before", action="store_true", help="score the note replies saved from the tester's runs (old prompt)")
    a = ap.parse_args()
    if a.before:
        pairs = [(s, s["before"]) for s in SESSIONS if s["before"]]
        # The old writer kept every ABOUT line as it was.
        for s, r in pairs:
            facts = [l[6:].strip() for l in r.split("\n") if l.startswith("ABOUT:")]
            print(("ok  " if verdict(s, facts) else "FAIL") + f" {s['id']:<14} old writer added {facts or 'nothing'}")
        for (s, r), facts in zip(pairs, kept(pairs)):
            print(("ok  " if verdict(s, facts) else "FAIL") + f" {s['id']:<14} same replies through today's filter: {facts or 'nothing'}")
        return
    prompt, work = note_prompt(), tempfile.mkdtemp(prefix="poinky-aboutme-")
    jobs = [(s, i) for s in SESSIONS for i in range(a.runs)]
    with cf.ThreadPoolExecutor(4) as ex:
        replies = list(ex.map(lambda j: ask(prompt, session_text(j[0]), work), jobs))
    facts = kept([(s, r) for (s, _), r in zip(jobs, replies)])
    results, good = [], 0
    for (s, i), r, f in zip(jobs, replies, facts):
        ok = verdict(s, f)
        good += ok
        abouts = [l for l in r.split("\n") if l.startswith("ABOUT:")]
        print(("ok  " if ok else "FAIL") + f" {s['id']:<14} learned {f or 'nothing'}" + (f"   (wrote {abouts})" if abouts else ""))
        results.append(dict(id=s["id"], run=i, reply=r, learned=f, ok=ok))
    json.dump(results, open(os.path.join(HERE, "results", a.label + ".json"), "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"\n{good}/{len(results)} sessions: About me learned exactly what the user said about themselves (or nothing)")


if __name__ == "__main__":
    main()
