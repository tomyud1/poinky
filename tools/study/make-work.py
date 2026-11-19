#!/usr/bin/env python3
"""Makes the test photos of handwritten work for study sessions (tools/study/work/*.jpg).

Each sample is written in a handwriting font on grid paper (headless Chrome renders it), then made to look
like a phone photo: a perspective tilt, a desk around the page, a soft shadow across it, uneven light, grain
and JPEG. The samples are original work on tools/study/sheet-en.html and sheet-he.html:
  slip-early.jpg     Q1(b) English: an algebra slip in the factoring (line 3), everything after follows from it
  sign-last.jpg      Q2(b) English: right until the last line, which subtracts instead of adds
  all-right.jpg      Q1(c) English: fully right
  hebrew-right.jpg   שאלה 1 סעיף א, Hebrew notes: fully right
  hebrew-wrong.jpg   שאלה 1 סעיף א, Hebrew notes: uses the depth of the hinge instead of the gate's centroid
Usage: python3 tools/study/make-work.py   (needs Google Chrome and Pillow)
"""
import os, random, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "work")
CHROME = os.environ.get("CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

SAMPLES = {
    "slip-early": ("en", "Q1 (b)", [
        "f'(x) = 3x² − 12x + 9",
        "= 3(x² − 4x + 3)",
        "= 3(x − 1)(x + 3)",
        "f'(x) = 0  →  x = 1,  x = −3",
        "f''(x) = 6x − 12",
        "f''(1) = −6 < 0  →  local max at x = 1",
        "f''(−3) = −30 < 0  →  local max at x = −3",
    ]),
    "sign-last": ("en", "Q2 (b)", [
        "v₀y = 15 sin 30° = 7.5 m/s",
        "at the top v_y = 0",
        "0 = v₀y² − 2g·Δh",
        "Δh = 7.5² / (2·9.8) = 56.25 / 19.6",
        "Δh = 2.87 m",
        "h_max = 20 − 2.87 = 17.13 m",
    ]),
    "all-right": ("en", "Q1 (c)", [
        "critical pts in [0,4]: x = 1, x = 3",
        "f(0) = 2",
        "f(1) = 1 − 6 + 9 + 2 = 6",
        "f(3) = 27 − 54 + 27 + 2 = 2",
        "f(4) = 64 − 96 + 36 + 2 = 6",
        "max = 6  at x = 1 and x = 4",
        "min = 2  at x = 0 and x = 3",
    ]),
    "hebrew-right": ("he", "שאלה 1 סעיף א", [
        "@לחץ מד בעומק y:",
        "p(y) = ρ g y",
        "@הכוח על השער (רוחב b):",
        "F = ∫ p dA = ∫<sub>d</sub><sup>d+a</sup> ρ g y · b dy",
        "= ρ g b [ y²/2 ]<sub>d</sub><sup>d+a</sup>",
        "= ρ g b ((d+a)² − d²) / 2",
        "= ρ g b (2ad + a²) / 2",
        "F = ρ g b a (d + a/2)",
        "@תשובה סופית ↑",
    ]),
    "hebrew-wrong": ("he", "שאלה 1 סעיף א", [
        "@לחץ מד בעומק y:",
        "p(y) = ρ g y",
        "@הלחץ על השער הוא בעומק d",
        "p = ρ g d",
        "@ולכן הכוח:",
        "F = p · A = ρ g d · a b",
        "F = ρ g a b d",
    ]),
}

PAGE = """<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;background:#f7f5ee}
.p{width:1100px;height:1400px;box-sizing:border-box;padding:90px 80px;
  background-color:#f7f5ee;
  background-image:linear-gradient(rgba(70,110,190,.28) 1.5px,transparent 1.5px),linear-gradient(90deg,rgba(70,110,190,.28) 1.5px,transparent 1.5px);
  background-size:44px 44px}
.l{font:46px/1.15 "Bradley Hand","Noteworthy",cursive;color:#1f2a55;margin:0 0 30px;white-space:nowrap}
.h{font:52px/1.2 "Bradley Hand",cursive;color:#1f2a55;margin:0 0 40px;text-decoration:underline}
sub,sup{font-size:60%%}
.he{font-family:"Corsiva Hebrew","Bradley Hand",cursive;direction:rtl;text-align:right}
</style></head><body><div class="p">%s</div></body></html>"""


def html(lang, head, lines):
    rnd = random.Random(hash(head) & 0xffff)
    out = [f'<div class="h {"he" if lang == "he" else ""}" style="transform:rotate({rnd.uniform(-1, 1):.2f}deg)">{head}</div>']
    for l in lines:
        note = l.startswith("@")
        text = l[1:] if note else l
        cls = "l he" if note else "l"
        dx = rnd.uniform(-12, 18)
        out.append(f'<div class="{cls}" style="margin-left:{dx:.0f}px;transform:rotate({rnd.uniform(-1.2, 1.2):.2f}deg)">{text}</div>')
    return PAGE % "\n".join(out)


def photo(src, dst, seed):
    rnd = random.Random(seed)
    page = Image.open(src).convert("RGB")
    W, H = 1500, 1900
    desk = Image.new("RGB", (W, H), (92, 78, 64))
    # Wood-ish desk.
    d = ImageDraw.Draw(desk)
    for y in range(0, H, 6):
        c = 84 + int(10 * rnd.random())
        d.line([(0, y), (W, y + rnd.randint(-3, 3))], fill=(c, c - 12, c - 26), width=6)
    # The page, tilted in perspective: where its corners land on the photo.
    pw, ph = page.size
    j = lambda: rnd.uniform(-45, 45)
    quad = [(170 + j(), 150 + j()), (1340 + j(), 120 + j()), (1390 + j(), 1780 + j()), (120 + j(), 1750 + j())]
    coeffs = find_coeffs(quad, [(0, 0), (pw, 0), (pw, ph), (0, ph)])
    warped = page.transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC, fillcolor=None)
    mask = Image.new("L", (pw, ph), 255).transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC)
    desk.paste(warped, (0, 0), mask)
    # A soft shadow across part of the page (a hand or a phone), and uneven light.
    shade = Image.new("L", (W, H), 0)
    sd = ImageDraw.Draw(shade)
    x0 = rnd.randint(-300, 200)
    sd.polygon([(x0, H), (x0 + 700, H), (x0 + 1100, int(H * 0.55)), (x0 + 500, int(H * 0.45))], fill=95)
    shade = shade.filter(ImageFilter.GaussianBlur(90))
    dark = Image.new("RGB", (W, H), (20, 18, 25))
    desk = Image.composite(dark, desk, shade)
    grad = Image.linear_gradient("L").resize((W, H)).rotate(rnd.choice([0, 90, 180, 270]))
    light = Image.new("RGB", (W, H), (255, 246, 225))
    desk = Image.blend(desk, Image.composite(light, desk, grad.point(lambda v: v // 6)), 0.6)
    # Grain and a little blur, then JPEG.
    noise = Image.effect_noise((W, H), 18).convert("RGB")
    desk = Image.blend(desk, noise, 0.06).filter(ImageFilter.GaussianBlur(0.7))
    desk.resize((W * 2 // 3 * 2 // 2, H * 2 // 3 * 2 // 2)).save(dst, "JPEG", quality=80)


def find_coeffs(pa, pb):
    """PIL perspective coefficients mapping output points pa to input points pb."""
    import numpy as np
    m = []
    for p1, p2 in zip(pa, pb):
        m.append([p1[0], p1[1], 1, 0, 0, 0, -p2[0] * p1[0], -p2[0] * p1[1]])
        m.append([0, 0, 0, p1[0], p1[1], 1, -p2[1] * p1[0], -p2[1] * p1[1]])
    A = np.array(m, dtype=float)
    B = np.array(pb, dtype=float).reshape(8)
    return np.linalg.solve(A, B).tolist()


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="poinky-work-")
    for i, (name, (lang, head, lines)) in enumerate(SAMPLES.items()):
        page = os.path.join(tmp, name + ".html")
        open(page, "w").write(html(lang, head, lines))
        shot = os.path.join(tmp, name + ".png")
        subprocess.run([CHROME, "--headless=new", "--hide-scrollbars", f"--screenshot={shot}", "--window-size=1100,1400",
                        "file://" + page], check=True, capture_output=True)
        photo(shot, os.path.join(OUT, name + ".jpg"), seed=i * 7 + 3)
        print("wrote", os.path.join(OUT, name + ".jpg"))


if __name__ == "__main__":
    main()
