#!/usr/bin/env python3
"""Run 3D kit code in a headless browser and save snapshots (for trying kit changes quickly).

    python3 eval3d/try.py code.js out.png [--wait 3] [--views iso,side,top]

Several --views give one picture per camera angle, side by side in out.png. Errors are printed.
"""
import argparse, base64, sys, time
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("code")
    ap.add_argument("out")
    ap.add_argument("--wait", type=float, default=3.0)
    ap.add_argument("--views", default="")
    ap.add_argument("--size", default="960x720")
    a = ap.parse_args()
    w, h = map(int, a.size.split("x"))
    code = Path(a.code).read_text()
    with sync_playwright() as pw:
        b = pw.chromium.launch(args=["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"])
        page = b.new_page(viewport={"width": w, "height": h})
        page.goto((ROOT / "eval3d" / "player.html").as_uri())
        page.wait_for_function("typeof play === 'function'")
        errs = page.evaluate("""code => { openScene('try'); writer.feed(code); return writer.end(); }""", code)
        time.sleep(a.wait)
        shots = []
        for v in [x for x in a.views.split(",") if x] or [""]:
            if v:
                page.evaluate("v => kit.view(v, {dur: 0.01})", v)
                time.sleep(1.2)
            shots.append(page.screenshot())
        errs += page.evaluate("errorsSoFar()")
        if len(shots) == 1:
            Path(a.out).write_bytes(shots[0])
        else:
            cells = "".join(f'<img src="data:image/png;base64,{base64.b64encode(s).decode()}">' for s in shots)
            page.set_viewport_size({"width": w * len(shots) // 2, "height": h // 2})
            page.set_content(f'<body style="margin:0;display:flex">{cells}<style>img{{width:{100 / len(shots)}%}}</style></body>')
            page.screenshot(path=a.out)
        b.close()
    for e in errs:
        print("error:", e)
    print("saved", a.out)


if __name__ == "__main__":
    main()
