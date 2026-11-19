#!/usr/bin/env python3
"""Harder phone photos of handwritten work, for the photo clean-up (StudySource.clean) and the capture tests.

Same handwriting pages as make-work.py (headless Chrome renders them), photographed badly in the ways real
phone photos are bad. Writes tools/study/hard/*.jpg (plus one PNG and one PDF like an iPad export):
  low-light.jpg      a dim room: dark, warm, noisy, a little soft
  hard-shadow.jpg    the phone's own sharp shadow across half the page
  hand-corner.jpg    a hand holding the page down in the bottom corner
  steep.jpg          shot from the side: strong perspective, one corner of the page out of the picture
  sideways.jpg       stored sideways with an EXIF "rotate 90°" tag, as phones do
  two-columns.jpg    work in two columns
  light-desk.jpg     a white desk: the page's edge barely shows
  unreadable.jpg     Q1(c) English with its 4th line scribbled over (the teacher should ask about it)
  ipad-notes.png     a clean export of iPad notes on grid paper (nothing to fix: must not be damaged)
  ipad-notes.pdf     the same as a two-page PDF (page 2 goes on with the work)
Usage: python3 tools/study/make-hard.py   (needs Google Chrome, Pillow and numpy)
"""
import importlib.util, os, random, subprocess, tempfile
from PIL import Image, ImageDraw, ImageFilter, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "hard")
spec = importlib.util.spec_from_file_location("make_work", os.path.join(HERE, "make-work.py"))
mw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mw)

TWO_COL = """<!doctype html><html><head><meta charset="utf-8"><style>
body{margin:0;background:#f7f5ee}
.p{width:1100px;height:1400px;box-sizing:border-box;padding:90px 60px;display:flex;gap:40px;
  background-color:#f7f5ee;
  background-image:linear-gradient(rgba(70,110,190,.28) 1.5px,transparent 1.5px),linear-gradient(90deg,rgba(70,110,190,.28) 1.5px,transparent 1.5px);
  background-size:44px 44px}
.c{flex:1;border-right:2px solid rgba(31,42,85,.35)}
.c:last-child{border:0}
.l{font:40px/1.15 "Bradley Hand","Noteworthy",cursive;color:#1f2a55;margin:0 0 28px;white-space:nowrap}
.h{font:46px/1.2 "Bradley Hand",cursive;color:#1f2a55;margin:0 0 34px;text-decoration:underline}
</style></head><body><div class="p"><div class="c">%s</div><div class="c">%s</div></div></body></html>"""

UNREADABLE = ("en", "Q1 (c)", [
    "critical pts in [0,4]: x = 1, x = 3",
    "f(0) = 2",
    "f(1) = 1 − 6 + 9 + 2 = 6",
    "f(3) = 27 − 54 + 27 + 2 = 2",
    "f(4) = 64 − 96 + 36 + 2 = 6",
    "max = 6  at x = 1 and x = 4",
    "min = 2  at x = 0 and x = 3",
])


def render(html, name, tmp, size=(1100, 1400)):
    page = os.path.join(tmp, name + ".html")
    open(page, "w").write(html)
    shot = os.path.join(tmp, name + ".png")
    subprocess.run([mw.CHROME, "--headless=new", "--hide-scrollbars", f"--screenshot={shot}", f"--window-size={size[0]},{size[1]}",
                    "file://" + page], check=True, capture_output=True)
    return Image.open(shot).convert("RGB")


def place(page, quad, W=1500, H=1900, desk=(92, 78, 64), rnd=None, grain=True):
    rnd = rnd or random.Random(1)
    out = Image.new("RGB", (W, H), desk)
    d = ImageDraw.Draw(out)
    for y in range(0, H, 6):
        k = int(10 * rnd.random())
        d.line([(0, y), (W, y + rnd.randint(-3, 3))], fill=tuple(max(0, min(255, c - 8 + k)) for c in desk), width=6)
    pw, ph = page.size
    coeffs = mw.find_coeffs(quad, [(0, 0), (pw, 0), (pw, ph), (0, ph)])
    warped = page.transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC)
    mask = Image.new("L", (pw, ph), 255).transform((W, H), Image.PERSPECTIVE, coeffs, Image.BICUBIC)
    out.paste(warped, (0, 0), mask)
    return out


def finish(img, dst, noise=18, blur=0.7, quality=80, exif=None):
    W, H = img.size
    n = Image.effect_noise((W, H), noise).convert("RGB")
    img = Image.blend(img, n, 0.06).filter(ImageFilter.GaussianBlur(blur))
    img = img.resize((W * 2 // 3, H * 2 // 3))
    if exif:
        img.save(dst, "JPEG", quality=quality, exif=exif)
    else:
        img.save(dst, "JPEG", quality=quality)
    print("wrote", dst)


def main():
    os.makedirs(OUT, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="poinky-hard-")
    pages = {name: render(mw.html(*spec), name, tmp) for name, spec in mw.SAMPLES.items()}
    std = [(170, 150), (1340, 120), (1390, 1780), (120, 1750)]

    # A dim room: dark, warm, noisy, soft.
    img = place(pages["sign-last"], std, rnd=random.Random(2))
    img = ImageEnhance.Brightness(img).enhance(0.38)
    warm = Image.new("RGB", img.size, (255, 170, 80))
    img = Image.blend(img, Image.composite(warm, img, Image.new("L", img.size, 40)), 0.5)
    finish(img, os.path.join(OUT, "low-light.jpg"), noise=40, blur=1.3, quality=70)

    # The phone's sharp shadow across half the page.
    img = place(pages["slip-early"], std, rnd=random.Random(3))
    shade = Image.new("L", img.size, 0)
    ImageDraw.Draw(shade).polygon([(0, 1900), (0, 900), (800, 700), (1100, 1900)], fill=150)
    shade = shade.filter(ImageFilter.GaussianBlur(6))
    img = Image.composite(Image.new("RGB", img.size, (25, 22, 30)), img, shade)
    finish(img, os.path.join(OUT, "hard-shadow.jpg"))

    # A hand in the bottom-right corner.
    img = place(pages["hebrew-right"], std, rnd=random.Random(4))
    hand = Image.new("L", img.size, 0)
    hd = ImageDraw.Draw(hand)
    hd.ellipse([1050, 1450, 1650, 2100], fill=255)
    for i in range(4):
        hd.rounded_rectangle([1000 - i * 70, 1300 + i * 40, 1080 - i * 70, 1650 + i * 40], 40, fill=255)
    hand = hand.filter(ImageFilter.GaussianBlur(5))
    img = Image.composite(Image.new("RGB", img.size, (214, 160, 128)), img, hand)
    finish(img, os.path.join(OUT, "hand-corner.jpg"))

    # From the side: strong perspective, the top-right corner out of the picture.
    img = place(pages["all-right"], [(380, 260), (1620, -60), (1450, 1880), (40, 1560)], rnd=random.Random(5))
    finish(img, os.path.join(OUT, "steep.jpg"))

    # Stored sideways with an EXIF orientation of 6 (rotate 90° clockwise to view).
    img = place(pages["sign-last"], std, rnd=random.Random(6)).rotate(90, expand=True)
    exif = Image.Exif()
    exif[0x0112] = 6
    finish(img, os.path.join(OUT, "sideways.jpg"), exif=exif.tobytes())

    # Two columns.
    rnd = random.Random(7)
    def col(lines):
        return "".join(f'<div class="l" style="margin-left:{rnd.uniform(-6, 10):.0f}px">{l}</div>' for l in lines)
    left = ['<div class="h">Q1 (b)</div>'] + []
    a = mw.SAMPLES["slip-early"][2]
    page2 = render(TWO_COL % ('<div class="h">Q1 (b)</div>' + col(a[:4]), col(a[4:]) + '<div class="l">so both are maxima?</div>'), "two", tmp)
    finish(place(page2, std, rnd=random.Random(8)), os.path.join(OUT, "two-columns.jpg"))

    # A white desk.
    img = place(pages["all-right"], std, desk=(236, 234, 228), rnd=random.Random(9))
    finish(img, os.path.join(OUT, "light-desk.jpg"))

    # One line scribbled over.
    pg = render(mw.html(*UNREADABLE), "unreadable", tmp)
    d = ImageDraw.Draw(pg)
    r = random.Random(11)
    y0 = 90 + 60 + 40 + 3 * (53 + 30) + 10
    pts = [(170 + i * 22, y0 + r.randint(-26, 26)) for i in range(30)]
    d.line(pts, fill=(31, 42, 85), width=7)
    d.line([(p[0] + 9, p[1] + r.randint(-14, 14)) for p in pts], fill=(31, 42, 85), width=6)
    finish(place(pg, std, rnd=random.Random(12)), os.path.join(OUT, "unreadable.jpg"))

    # iPad notes, exported: as a PNG, and as a two-page PDF.
    lines = mw.SAMPLES["hebrew-right"][2]
    p1 = render(mw.html("he", "שאלה 1 סעיף א", lines[:5]), "ipad1", tmp)
    p2 = render(mw.html("he", "(המשך)", lines[5:]), "ipad2", tmp)
    p1.save(os.path.join(OUT, "ipad-notes.png"))
    print("wrote", os.path.join(OUT, "ipad-notes.png"))
    p1.save(os.path.join(OUT, "ipad-notes.pdf"), save_all=True, append_images=[p2], resolution=110)
    print("wrote", os.path.join(OUT, "ipad-notes.pdf"))


if __name__ == "__main__":
    main()
