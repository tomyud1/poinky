#!/usr/bin/env python3
"""Talker eval: drives `claude -p` with the talker's real system prompt (assembled like BrainFactory.make)
and realistic messages (assembled like CallController.talkerText) with a rendered screenshot, then scores
the reply. See README.md.

  python3 tools/eval-talker/run.py                      # every scenario, once
  python3 tools/eval-talker/run.py -s coder-fix hebrew  # some of them
  python3 tools/eval-talker/run.py --runs 2 --label after
  python3 tools/eval-talker/run.py --print-prompt       # just show the assembled system prompt
"""
import argparse, base64, tempfile, concurrent.futures as cf, json, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
import scenarios as S  # noqa: E402

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
NOW = "Now: Sunday, 15 November 2026, 2:10 PM (America/New_York)."
NAMES = ["Mint", "Coral", "Violet", "Amber", "Rose", "Sky"]


# ---------- the system prompt, as BrainFactory.make builds it for the talker ----------

def swift_literal(s):
    return s.replace('\\n', '\n').replace('\\"', '"').replace('\\\\', '\\')


def lookup_section():
    """LookUp.promptSection with conversation history and web search on (the defaults), read from Recall.swift."""
    src = open(os.path.join(ROOT, "Sources/Poinky/Recall.swift"), encoding="utf-8").read()
    block = src[src.index("enum LookUp"):]
    block = block[:block.index("\n        return s\n")]
    parts = re.findall(r'(?:var s =|s \+=) "((?:[^"\\]|\\.)*)"', block)
    return "".join(swift_literal(p) for p in parts)


def identity_section():
    """Identity.promptSection with the default identity.md and an empty user.md (Identity.content strips
    `<!-- -->` and `# ` lines)."""
    src = open(os.path.join(ROOT, "Sources/Poinky/Identity.swift"), encoding="utf-8").read()
    m = re.search(r'static let defaultIdentity = """\n(.*?)\n\s*"""', src, re.S)
    text = "\n".join(l.strip() for l in m.group(1).split("\n"))
    text = re.sub(r"<!--[\s\S]*?-->", "", text)
    text = "\n".join(l for l in text.split("\n") if not l.startswith("# ")).strip()
    return "\n\n## Who you are (written by the user; it wins over the style notes above if they differ)\n" + text + "\n"


def memory_section(facts):
    s = "\n\n## What you know about the user (from earlier conversations)\n"
    src = open(os.path.join(ROOT, "Sources/Poinky/Memory.swift"), encoding="utf-8").read()
    m = re.search(r's \+= "(- Their Mac account name is (?:[^"\\]|\\.)*)"', src)
    s += swift_literal(m.group(1)).replace("\\(NSFullUserName())", "Alex Rivera").replace("\\(first)", "Alex")
    s += ("\n".join(facts) + "\n") if facts else "- Nothing else yet: this may be one of your first conversations.\n"
    return s


def system_prompt(facts=(), prompt_dir=None):
    pd = prompt_dir or os.path.join(ROOT, "prompts")
    p = open(os.path.join(pd, "talker-prompt.md"), encoding="utf-8").read()
    p += identity_section()
    p += memory_section(list(facts))
    p += lookup_section()
    return p


# ---------- the message, as CallController.talkerText builds it ----------

def _controller():
    return open(os.path.join(ROOT, "Sources/Poinky/CallController.swift"), encoding="utf-8").read()


ROUTE_SRC = [os.path.join(ROOT, "Sources/Poinky/TalkerRoute.swift"), os.path.join(ROOT, "tools/tests/talker-route/main.swift")]
_routes = {}


def route(q, marked=False, work=""):
    """TalkerRoute.classify, the app's own code (built once into build/eval-talker/talker-route)."""
    key = (q, marked, work)
    if key in _routes:
        return _routes[key]
    exe = os.path.join(ROOT, "build", "eval-talker", "talker-route")
    if not os.path.exists(exe) or os.path.getmtime(exe) < max(os.path.getmtime(f) for f in ROUTE_SRC):
        os.makedirs(os.path.dirname(exe), exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", exe] + ROUTE_SRC, check=True)
    out = subprocess.run([exe, "--json"], input=json.dumps([{"q": q, "marked": marked, "work": work}]).encode(),
                         capture_output=True, check=True).stdout
    _routes[key] = json.loads(out)[0]
    return _routes[key]


def extra(name):
    """A part of the instructions sent only with some questions (TalkerExtras)."""
    return open(os.path.join(ROOT, "prompts", name + ".md"), encoding="utf-8").read().strip()


def teacher_line(kind, like):
    """CallController.teacherLine, read from the source."""
    src = _controller()
    body = src[src.index("static func teacherLine"):]
    lits = re.findall(r'"(\(The teacher is ALREADY(?:[^"\\]|\\.)*)"', body[:body.index("\n    }\n")])
    line = swift_literal(lits[0] if kind == "check" else lits[1])
    return line.replace("\\(like)", like)


def message_text(sc):
    q = sc["said"]
    lines = [f'User said: "{q}"', NOW, f"Screenshot size: {S.W}x{S.H} px (coordinates use this size)."]
    lines += sc.get("ctx", [])
    if sc.get("cursor"):
        x, y = sc["cursor"]
        lines.append(f'Mouse cursor is at ({x}, {y}) (just where the mouse is: a hint for "this"/"here", not necessarily the topic).')
    lines.append("Nothing is drawn on screen right now.")
    selection = "".join(re.findall(r"«([\s\S]*)»", "\n".join(sc.get("ctx", []))))
    rt = route(q, False, selection)
    if "app" in rt["flags"]:
        lines.append("Current Poinky settings: voice Easton at speed 1.00 (engine phonon); buddy on; sounds on at 70% volume; "
                     "teacher on; hold to talk ⌃⌥; hands-free call ⌃⌥Space; language en-US; memory on")
    if sc.get("agents"):
        lines.append(sc["agents"])
    used = re.findall(r"#\d+ (\w+)", sc.get("agents", ""))
    free = [n for n in NAMES if n not in used]
    if "nextNames(3)" in _controller():
        lines.append(f"If you start an agent now, it will be called {free[0]} (several: {', '.join(free[:3])}, in that order).")
    else:
        lines.append(f"If you start an agent now, it will be called {free[0]}.")
    if rt["teacher"] != "none":
        lines.append(teacher_line(rt["teacher"], rt["handOver"]))
    if rt.get("hint"):
        lines.append(rt["hint"])
    m = re.search(r'static let formatReminder = "((?:[^"\\]|\\.)*)"', _controller())
    if m:
        lines.append(swift_literal(m.group(1)))
    # TalkerExtras: first in the message, only when the question can use them.
    extras = []
    if "app" in rt["flags"]:
        extras.append(extra("poinky-manual"))
    if sc.get("agents") or "helpers" in rt["flags"]:
        extras.append(extra("talker-helpers"))
    if "video" in rt["flags"]:
        extras.append(extra("talker-video"))
    return "\n".join(extras + lines)


# ---------- screenshots ----------

def render(sc, outdir):
    html = os.path.join(outdir, sc["id"] + ".html")
    png = os.path.join(outdir, sc["id"] + ".png")
    jpg = os.path.join(outdir, sc["id"] + ".jpg")
    if os.path.exists(jpg) and os.path.getmtime(jpg) > os.path.getmtime(os.path.join(HERE, "scenarios.py")):
        return jpg
    open(html, "w", encoding="utf-8").write(sc["html"])
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", "--force-device-scale-factor=1",
                    f"--window-size={S.W},{S.H}", f"--screenshot={png}", "file://" + html],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "80", png, "--out", jpg],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return jpg


# ---------- running claude -p like ClaudeCodeBrain ----------

def find_claude():
    if os.environ.get("POINKY_EVAL_CLAUDE"):
        return os.environ["POINKY_EVAL_CLAUDE"]
    home = os.path.expanduser("~")
    for p in [f"{home}/.local/bin/claude", f"{home}/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]:
        if os.access(p, os.X_OK):
            return p
    return shutil.which("claude")


def no_thinking_body(model="haiku"):
    """The CLAUDE_CODE_EXTRA_BODY ClaudeCodeBrain sends on Automatic effort (`noThinkingBody(for:)`)."""
    src = open(os.path.join(ROOT, "Sources/Poinky/ClaudeCodeBrain.swift"), encoding="utf-8").read()
    if "static func noThinkingBody(for" not in src:
        return None
    m = model.lower()
    kind = "disabled" if "haiku" in m else "between_tools" if "sonnet" in m else None
    return kind and '{"thinking":{"type":"%s"},"context_management":{"edits":[]}}' % kind


def run_once(sc, jpg, model, workdir, prompt, keep_thinking=False):
    exe = find_claude()
    if not exe:
        raise SystemExit("claude not found: set POINKY_EVAL_CLAUDE=/path/to/claude")
    args = [exe, "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", model, "--tools", "", "--strict-mcp-config",
            "--disable-slash-commands", "--setting-sources", "", "--no-session-persistence",
            "--system-prompt", prompt, "--settings", '{"alwaysThinkingEnabled":false}']
    env = dict(os.environ, MAX_THINKING_TOKENS="0", CLAUDE_CODE_DISABLE_AUTO_MEMORY="1")
    body = None if keep_thinking else no_thinking_body(model)
    if body:
        env["CLAUDE_CODE_EXTRA_BODY"] = body
    p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=workdir, env=env)
    time.sleep(4)   # the app starts the talker ahead of time, so the question doesn't pay for startup
    img = base64.b64encode(open(jpg, "rb").read()).decode()
    msg = {"type": "user", "message": {"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": img}},
        {"type": "text", "text": message_text(sc)}]}}
    t0 = time.time()
    p.stdin.write((json.dumps(msg) + "\n").encode()); p.stdin.flush()
    text, first, first_say, usage = "", None, None, {}
    for raw in p.stdout:
        try:
            o = json.loads(raw)
        except ValueError:
            continue
        if o.get("type") == "stream_event":
            ev = o.get("event", {})
            d = ev.get("delta", {})
            if ev.get("type") == "content_block_delta" and d.get("type") == "text_delta":
                if first is None:
                    first = time.time() - t0
                text += d["text"]
                if first_say is None and re.search(r"<say>[^<]*?\w[^<]*?([.!?,]\s|</say>)", text):
                    first_say = time.time() - t0
        elif o.get("type") == "result":
            usage = o.get("usage", {})
            if not text:
                text = o.get("result", "")
            break
    total = time.time() - t0
    try:
        p.stdin.close()
        p.wait(timeout=10)
    except Exception:
        p.kill()
    return dict(raw=text, first_token=first, first_sentence=first_say, total=total,
                input_tokens=sum(usage.get(k, 0) for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens")))


# ---------- parsing and scoring ----------

TAGS = ["say", "visual", "draw", "guide", "do", "agent", "remember", "forget", "remind", "remind-cancel", "set",
        "tell", "video", "search", "recall", "replace"]


OFFER_RE = r"<offer(\s[^>]*)?>([\s\S]*?)</offer>"


def parse_reply(raw):
    """Tags like TalkParser finds them. An `<offer>` (prepared for a yes, not run now, see Offer.swift) is
    kept aside: `tags["offer"]` has its (attrs, body) and `offer` its own parsed tags; nothing inside it
    counts as a top-level tag."""
    offers = [((m.group(1) or "").strip(), m.group(2).strip()) for m in re.finditer(OFFER_RE, raw)]
    full, raw = raw, re.sub(OFFER_RE, "", raw)
    raw = raw.split("<offer")[0]
    tags = {}
    for t in TAGS:
        for m in re.finditer(r"<%s(\s[^>]*)?>([\s\S]*?)</%s>" % (re.escape(t), re.escape(t)), raw):
            tags.setdefault(t, []).append(((m.group(1) or "").strip(), m.group(2).strip()))
    for t in ["end", "stop", "undo", "video-cancel", "video-close", "video-play"]:
        for m in re.finditer(r"<%s(\s[^>]*)?/>" % re.escape(t), raw):
            tags.setdefault(t, []).append(((m.group(1) or "").strip(), ""))
    say = " ".join(b for _, b in tags.get("say", []))
    draw = tags.get("draw", [("", "")])[0][1]
    offer = None
    if offers:
        tags["offer"] = offers
        offer = parse_reply(offers[0][1])
        m = re.search(r'say\s*=\s*"([^"]*)"', offers[0][0])
        offer["say_attr"] = m.group(1) if m else ""
    return dict(raw=full, tags=tags, say=say, draw=draw, offer=offer)


def generic_checks(r):
    out = []
    out.append(("has <say>", bool(r["say"].strip())))
    out.append(("spoken style (no markdown/URL/emoji)",
                not re.search(r"\*\*|`|^\s*[-#]\s|https?://|www\.|[\U0001F300-\U0001FAFF]", r["say"], re.M)))
    if r["draw"]:
        try:
            json.loads(r["draw"]); ok = True
        except ValueError:
            ok = False
        out.append(("<draw> is valid JSON", ok))
    out.append(("math said for the ear (no ² = ( ) symbols)", not re.search(r"[²³√=×÷^]|\(\s*x|x\s*[−+-]\s*\d\s*\)", r["say"])))
    out.append(("no praise opener (\"good question\")", not re.search(r"\b(good|great|excellent|nice) question\b", r["say"], re.I)))
    if r["tags"].get("visual"):
        out.append(("hands over in one short line (the sketch explains)", len(r["say"].split()) <= 20))
    out.append(("nothing outside the tags", not re.sub(r"<(\w[\w-]*)(\s[^>]*)?>[\s\S]*?</\1>|<[\w-]+(\s[^>]*)?/>", "", r["raw"]).strip()))
    return out


def score(sc, reply):
    r = parse_reply(reply["raw"])
    checks = [(n, bool(f(r))) for n, f in sc["checks"]]
    gen = generic_checks(r)
    return dict(id=sc["id"], who=sc["who"], said=sc["said"], checks=checks, generic=gen,
                passed=all(ok for _, ok in checks + gen), say=r["say"], tags=sorted(r["tags"].keys()), **reply)


def rescore(labels):
    """Prints a table: each scenario's checks passed per saved run (the newest file for a scenario wins
    within a label list like before,before-extra)."""
    cols = []
    for label in labels:
        merged = {}
        for part in label.split(","):
            for r in json.load(open(os.path.join(HERE, "results", part + ".json"), encoding="utf-8")):
                merged.setdefault(r["id"], []).append(r)
        cols.append((label, merged))
    passed = {l: 0 for l, _ in cols}
    print("| scenario | " + " | ".join(l for l, _ in cols) + " |")
    print("|---|" + "---|" * len(cols))
    for sc in S.SCENARIOS:
        cells = []
        for label, merged in cols:
            runs = merged.get(sc["id"])
            if not runs:
                cells.append("–"); continue
            parts = []
            for r in runs:
                s = score(sc, {k: r.get(k) for k in ("raw", "first_token", "first_sentence", "total", "input_tokens")})
                fails = [n for n, ok in s["checks"] + s["generic"] if not ok]
                passed[label] += not fails
                ft = r.get("first_sentence") or r.get("first_token") or 0
                parts.append(("pass" if not fails else "FAIL: " + "; ".join(fails)) + f" ({ft:.1f}s)")
            cells.append("<br>".join(parts))
        print(f"| {sc['id']} | " + " | ".join(cells) + " |")
    for label, merged in cols:
        fs = sorted(r.get("first_sentence") or r.get("first_token") or 99 for runs in merged.values() for r in runs)
        print(f"\n{label}: {passed[label]}/{len(fs)} passed, first spoken words median {fs[len(fs)//2]:.2f}s, max {fs[-1]:.2f}s")


# ---------- replay: saved replies through the same parsing and checks, plus the app's own parser (no tokens) ----------

FIXTURES = os.path.join(HERE, "fixtures.json")


def outcome(sc, raw):
    s = score(sc, {"raw": raw})
    return sorted(n for n, ok in s["checks"] + s["generic"] if not ok)


def record_fixtures(labels, per=2):
    """fixtures.json from saved results: each scenario's newest `per` replies (labels oldest first) plus its
    newest failing one, each with the checks it fails now (replay expects exactly those)."""
    runs = {}
    for label in labels:
        for part in label.split(","):
            for r in json.load(open(os.path.join(HERE, "results", part + ".json"), encoding="utf-8")):
                if r.get("raw"):
                    runs.setdefault(r["id"], []).append((part, r["raw"]))
    out = []
    for sc in S.SCENARIOS:
        rs = runs.get(sc["id"], [])[::-1]   # newest first
        picked = rs[:per]
        bad = next(((l, raw) for l, raw in rs if outcome(sc, raw)), None)
        if bad and bad not in picked:
            picked.append(bad)
        for label, raw in picked:
            out.append(dict(id=sc["id"], source=label, raw=raw, fails=outcome(sc, raw)))
    json.dump(out, open(FIXTURES, "w", encoding="utf-8"), indent=1, ensure_ascii=False)
    print(f"recorded {len(out)} replies for {len({f['id'] for f in out})} scenarios in {os.path.relpath(FIXTURES, ROOT)}")


def words(s):
    return re.findall(r"[^\W_]+", (s or "").lower())


def compare_parsers(r, sw):
    """What the eval's parser found (`parse_reply`) against the app's TalkParser (parse-replies.swift)."""
    bad = []
    t = r["tags"]
    def first(tag):
        return t[tag][0][1] if t.get(tag) else None
    if t.get("say") and words(r["say"]) != words(sw.get("say")):
        bad.append(f"spoken text differs: {r['say'][:80]!r} vs {sw.get('say', '')[:80]!r}")
    for tag in ("do", "visual", "search", "recall", "guide"):
        mine, app = first(tag), sw.get(tag)
        if (mine or None) != (app or None):
            bad.append(f"<{tag}>: {str(mine)[:60]!r} vs {str(app)[:60]!r}")
    agents = [(re.search(r'title\s*=\s*"([^"]*)"', a) or [None, "Agent"])[1] for a, b in t.get("agent", []) if b]
    if agents != [a["title"] for a in sw.get("agent", [])]:
        bad.append(f"agents: {agents} vs {[a['title'] for a in sw.get('agent', [])]}")
    reminds = [(re.search(r'at\s*=\s*"([^"]*)"', a) or [None, None])[1] for a, b in t.get("remind", []) if b]
    if [x for x in reminds if x] != [x["at"] for x in sw.get("remind", [])]:
        bad.append(f"reminders: {reminds} vs {[x['at'] for x in sw.get('remind', [])]}")
    for tag in ("set", "tell"):
        if len([b for _, b in t.get(tag, []) if b]) != len(sw.get(tag, [])):
            bad.append(f"<{tag}> count differs")
    if bool(t.get("end")) != bool(sw.get("end")):
        bad.append("<end/> differs")
    o, so = r.get("offer"), sw.get("offer")
    if bool(o) != bool(so):
        bad.append(f"<offer>: {bool(o)} vs {bool(so)}")
    elif o and not so.get("empty") and (first_of(o, "do") or None) != (so.get("do") or None):
        bad.append("the offer's <do> differs")
    elif o and not so.get("empty") and (first_of(o, "replace") or None) != (so.get("replace") or None):
        bad.append("the offer's <replace> differs")
    return bad


def first_of(r, tag):
    return r["tags"][tag][0][1] if r["tags"].get(tag) else None


def replay(parser=None):
    fx = json.load(open(FIXTURES, encoding="utf-8"))
    by_id = {s["id"]: s for s in S.SCENARIOS}
    app = None
    if parser:
        tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False, encoding="utf-8")
        json.dump([{"raw": f["raw"]} for f in fx], tmp, ensure_ascii=False); tmp.close()
        app = json.loads(subprocess.run([parser, tmp.name], capture_output=True, check=True).stdout)
        os.unlink(tmp.name)
    problems = 0
    for i, f in enumerate(fx):
        sc = by_id.get(f["id"])
        if not sc:
            print(f"FAIL {f['id']}: no such scenario any more (record the fixtures again)"); problems += 1; continue
        now = outcome(sc, f["raw"])
        msgs = []
        if now != sorted(f["fails"]):
            msgs.append(f"checks changed: recorded {f['fails'] or 'pass'}, now {now or 'pass'}")
        if app is not None:
            msgs += compare_parsers(parse_reply(f["raw"]), app[i])
        if msgs:
            problems += 1
            print(f"FAIL {f['id']} ({f['source']})")
            for m in msgs:
                print(f"       {m}")
    n = len(fx)
    print(f"{n - problems}/{n} saved replies parse and score as recorded" + (" (and the app's TalkParser agrees)" if app is not None else ""))
    return problems == 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-s", "--scenarios", nargs="*")
    ap.add_argument("--runs", type=int, default=1)
    ap.add_argument("--model", default="haiku", help="the talker's model (the app's default: haiku)")
    ap.add_argument("--label", default="run")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--keep-thinking", action="store_true", help="don't send the app's no-thinking body (how it was before)")
    ap.add_argument("--print-prompt", action="store_true")
    ap.add_argument("--rescore", nargs="+", metavar="LABEL", help="score saved results again with the current checks (no model calls)")
    ap.add_argument("--print-message", metavar="ID")
    ap.add_argument("--replay", action="store_true", help="no model calls: score the saved replies in fixtures.json again (CI)")
    ap.add_argument("--parser", help="with --replay: the built parse-replies tool, to check the app's TalkParser too")
    ap.add_argument("--record-fixtures", nargs="+", metavar="LABEL", help="make fixtures.json from saved results (oldest label first)")
    a = ap.parse_args()

    if a.replay:
        sys.exit(0 if replay(a.parser) else 1)
    if a.record_fixtures:
        record_fixtures(a.record_fixtures); return

    if a.print_prompt:
        print(system_prompt()); return
    if a.print_message:
        print(message_text(next(s for s in S.SCENARIOS if s["id"] == a.print_message))); return

    if a.rescore:
        rescore(a.rescore); return

    scs = [s for s in S.SCENARIOS if not a.scenarios or s["id"] in a.scenarios]
    out = os.path.join(ROOT, "build", "eval-talker")
    os.makedirs(out, exist_ok=True)
    # An empty folder outside any git repo for claude to run in, like the app's settings folder (inside a
    # repo, Claude Code would add that project's auto-memory to the context).
    work = tempfile.mkdtemp(prefix="poinky-eval-")
    jobs = []
    for sc in scs:
        jpg = render(sc, out)
        for i in range(a.runs):
            jobs.append((sc, jpg, i))

    results = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = {ex.submit(run_once, sc, jpg, a.model, work, system_prompt(sc.get("memory", ())), a.keep_thinking): (sc, i) for sc, jpg, i in jobs}
        for f in cf.as_completed(futs):
            sc, i = futs[f]
            try:
                res = score(sc, f.result())
            except Exception as e:  # noqa: BLE001
                res = dict(id=sc["id"], who=sc["who"], said=sc["said"], passed=False, error=str(e), checks=[], generic=[], say="", tags=[])
            res["run"] = i
            results.append(res)
            mark = "PASS" if res["passed"] else "FAIL"
            ft = res.get("first_sentence") or res.get("first_token") or 0
            print(f"{mark} {sc['id']:<20} {ft:5.2f}s  {res['say'][:110]!r}")
            for n, ok in res["checks"] + res["generic"]:
                if not ok:
                    print(f"       x {n}")
    results.sort(key=lambda r: ([s["id"] for s in scs].index(r["id"]), r["run"]))
    path = os.path.join(HERE, "results", a.label + ".json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    home = os.path.expanduser("~")   # keep the machine's home folder out of saved results (the model may expand ~)
    text = json.dumps(results, indent=1, ensure_ascii=False).replace(home + "/", "~/").replace(home, "~")
    # The model may also invent a home folder from the account's name: keep only the scenarios' own names.
    text = re.sub(r"/Users/(?!alex/|you/|x/)[^/\"\\\s]+/", "/Users/alex/", text)
    text = re.sub(r"/private/var/folders/[^/\"\\\s]+/[^/\"\\\s]+/T/poinky-eval-\w+", "/tmp/poinky-eval", text)
    open(path, "w", encoding="utf-8").write(text)
    n = sum(r["passed"] for r in results)
    fs = sorted(r.get("first_sentence") or 99 for r in results)
    print(f"\n{n}/{len(results)} passed; first spoken words median {fs[len(fs)//2]:.2f}s; saved {os.path.relpath(path, ROOT)}")


if __name__ == "__main__":
    main()
