#!/usr/bin/env python3
"""Try a "second look": the teacher sees pictures of the model it just built and may fix it.

    python3 eval3d/check.py eval3d/runs/NAME --out eval3d/runs/NAME-checked [--only heart] [--model sonnet]

For each question: builds the reply's model in the player, takes kit.snapshot() pictures, asks Claude (with the
teacher prompt) to look at them and answer <ok/> or a fixing <step3d>, and writes a copy of the reply with that
fix right after the model, so shoot.py and grade.py can compare the two runs.
"""
import argparse, base64, concurrent.futures as cf, json, os, re, shutil, subprocess, time
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent

LOOK = """Second look at your 3D model id="{id}". The user asked: "{q}"
The images {imgs} show it as it is now, from two angles (labels aren't drawn). Here is the code you wrote:
```
{code}
```
Check it against the real thing, like an engineer would:
- parts in the wrong place: floating in the air, sunk inside another part, detached from what they belong to, on the wrong side
- wrong orientation: upside down, facing backward, a front that should face +x, wheels or rotors on the wrong axis
- proportions that are way off, or something important hidden inside or too small to see
- something missing that the explanation needs
If it's right, reply with only <ok/>. If not, reply with only one <step3d id="{id}"> that fixes the clear mistakes in place:
move, rotate, resize or remove parts (your variables and names still work), or add what's missing. Don't rebuild the model,
don't change what's already right, and don't add labels, camera moves or animations. No explanation: the <ok/> or the
<step3d> is your whole reply."""


def scene_of(reply):
    m = re.search(r'<scene3d\b([^>]*)>([\s\S]*?)(</scene3d>|$)', reply)
    if not m:
        return None, None, None
    sid = (re.search(r'id="([^"]*)"', m.group(1)) or [None, "model"])[1]
    return sid, m.group(2), m.end()


def snapshots(page, sid, code, d):
    page.goto((ROOT / "eval3d" / "player.html").as_uri())
    page.wait_for_function("typeof play === 'function'")
    page.evaluate("([id, c]) => { openScene(id); writer.feed(c); writer.end(); }", [sid, code])
    time.sleep(1.5)
    urls = page.evaluate("kit.snapshot()")
    paths = []
    for i, u in enumerate(urls):
        p = d / f"look-{i + 1}.jpg"
        p.write_bytes(base64.b64decode(u.split(",", 1)[1]))
        paths.append(p)
    return paths


def ask(q, sid, code, imgs, model):
    """Same flags as the app's teacher (no tools, no thinking), with the pictures inline."""
    prompt = LOOK.format(id=sid, q=q, imgs="below", code=code.strip())
    content = [{"type": "text", "text": prompt}] + [
        {"type": "image", "source": {"type": "base64", "media_type": "image/jpeg", "data": base64.b64encode(p.read_bytes()).decode()}}
        for p in imgs]
    env = dict(os.environ, MAX_THINKING_TOKENS="0")
    t0 = time.time()
    r = subprocess.run(
        ["claude", "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
         "--model", model, "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--setting-sources", "",
         "--settings", '{"alwaysThinkingEnabled":false}', "--no-session-persistence",
         "--system-prompt", (ROOT / "prompts" / "artist-prompt.md").read_text()],
        input=json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n",
        capture_output=True, text=True, env=env, cwd="/tmp", timeout=300)
    for line in r.stdout.splitlines():
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get("type") == "result":
            return obj.get("result", ""), time.time() - t0
    return f"(failed: {r.stdout[-200:]} {r.stderr[-200:]})", time.time() - t0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--out", required=True)
    ap.add_argument("--only", default="")
    ap.add_argument("--model", default="sonnet")
    ap.add_argument("--jobs", type=int, default=4)
    a = ap.parse_args()
    qs = {q["id"]: q for q in json.loads((ROOT / "eval3d" / "questions.json").read_text())}
    src, out = Path(a.run), Path(a.out)
    dirs = sorted(d for d in src.iterdir() if (d / "reply.txt").exists() or (d / "reply-1.txt").exists())
    if a.only:
        dirs = [d for d in dirs if d.name in a.only.split(",")]
    jobs = []
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"])
        page = b.new_page(viewport={"width": 960, "height": 720})
        for d in dirs:
            o = out / d.name; o.mkdir(parents=True, exist_ok=True)
            for f in d.glob("reply*.txt"):
                shutil.copy(f, o / f.name)
            if (d / "timing.json").exists():
                shutil.copy(d / "timing.json", o / "timing.json")
            first = o / ("reply.txt" if (o / "reply.txt").exists() else "reply-1.txt")
            sid, code, end = scene_of(first.read_text())
            if not code:
                continue
            jobs.append((d.name, o, first, sid, code, end, snapshots(page, sid, code, o)))
        b.close()

    def run(j):
        name, o, first, sid, code, end, imgs = j
        reply, secs = ask(qs.get(name, {}).get("user", name), sid, code, imgs, a.model)
        (o / "check.txt").write_text(reply)
        fix = re.search(r'<step3d\b[^>]*>[\s\S]*?</step3d>', reply)
        if fix:
            text = first.read_text()
            first.write_text(text[:end] + "\n" + fix.group(0) + "\n" + text[end:])
        return name, "fixed" if fix else "ok" if "<ok/>" in reply else "?", secs

    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for name, verdict, secs in ex.map(run, jobs):
            print(f"{name:12s} {verdict:6s} {secs:5.1f}s", flush=True)


if __name__ == "__main__":
    main()
