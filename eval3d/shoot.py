#!/usr/bin/env python3
"""Replay saved teacher replies in a headless browser and take snapshots along the way.

    python3 eval3d/shoot.py eval3d/runs/NAME [--only iron-dome]

For each question folder: plays reply.txt (and reply-2.txt as a follow-up in the same scene) at the
speed it was written, saves a snapshot at the end of every spoken line, and puts them together in
sheet.png. Errors from the 3D code go to errors.txt.
"""
import argparse, base64, json, sys, time
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
W, H = 960, 720


def cps_of(timing):
    t = timing or {}
    if t.get("chars") and t.get("total_s") and t.get("first_text_s") is not None:
        return max(80.0, t["chars"] / max(0.5, t["total_s"] - t["first_text_s"]))
    return 250.0


def play(page, reply, cps, frames, prefix):
    info = page.evaluate("([r, c]) => play(r, c)", [reply, cps])
    start = time.time()
    for i, s in enumerate(info["snaps"]):
        wait = s["t"] - (time.time() - start)
        if wait > 0:
            time.sleep(wait)
        path = frames / f"{prefix}{i:02d}.png"
        page.screenshot(path=str(path))
        yield path, s["label"]


def sheet(page, shots, out, title):
    cells = "".join(
        f'<figure><img src="data:image/png;base64,{base64.b64encode(p.read_bytes()).decode()}"><figcaption>{i+1}. {l}</figcaption></figure>'
        for i, (p, l) in enumerate(shots))
    page.set_viewport_size({"width": 1500, "height": 900})
    page.set_content(f"""<html><body style="margin:0;background:#111;color:#ddd;font:13px -apple-system">
      <h3 style="margin:8px 12px">{title}</h3>
      <div style="display:grid;grid-template-columns:repeat(3,1fr);gap:6px;padding:6px">{cells}</div>
      <style>img{{width:100%;display:block}} figure{{margin:0}} figcaption{{padding:3px 4px;color:#aaa}}</style></body></html>""")
    page.screenshot(path=str(out), full_page=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    run = Path(a.run)
    qs = {q["id"]: q for q in json.loads((ROOT / "eval3d" / "questions.json").read_text())}
    dirs = sorted(d for d in run.iterdir() if d.is_dir())
    if a.only:
        dirs = [d for d in dirs if d.name in a.only.split(",")]
    with sync_playwright() as pw:
        browser = pw.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"])
        for d in dirs:
            replies = [d / "reply.txt"] if (d / "reply.txt").exists() else sorted(d.glob("reply-*.txt"))
            if not replies:
                continue
            timing = json.loads((d / "timing.json").read_text()) if (d / "timing.json").exists() else {}
            frames = d / "frames"; frames.mkdir(exist_ok=True)
            page = browser.new_page(viewport={"width": W, "height": H})
            page.goto((ROOT / "eval3d" / "player.html").as_uri())
            page.wait_for_function("typeof play === 'function'")
            shots = []
            for n, r in enumerate(replies):
                cps = cps_of(timing.get(f"turn{n+1}"))
                shots += list(play(page, r.read_text(), cps, frames, f"t{n+1}-"))
            errs = page.evaluate("errorsSoFar()")
            (d / "errors.txt").write_text("\n".join(errs))
            q = qs.get(d.name, {})
            sheet(page, shots, d / "sheet.png", f"{d.name}: {q.get('user', '')}  ({len(errs)} errors)")
            page.close()
            print(f"{d.name:12s} {len(shots)} frames, {len(errs)} errors", flush=True)
        browser.close()


if __name__ == "__main__":
    main()
