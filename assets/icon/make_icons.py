"""Draws the XiaoNing Translate logo (no fonts: the character 宁 is drawn from strokes).

python3 assets/icon/make_icons.py [option] -> writes PNGs (and .ico) next to this file.
"""
import sys, os
from PIL import Image, ImageDraw

CLAY = (217, 119, 87)       # warm terracotta
CLAY_DARK = (189, 93, 58)
CREAM = (250, 249, 245)
INK = (41, 38, 35)
HERE = os.path.dirname(os.path.abspath(__file__))
SS = 4  # supersampling

# 宁 in a 100x100 box: 宀 (dot + roof) over 丁 (bar + hooked stem)
NING = [
    [(50, 12), (52, 22)],
    [(21, 43), (25, 31), (79, 31), (75, 41)],
    [(17, 55), (83, 55)],
    [(51, 55), (51, 84), (42, 79)],
]

def strokes(d, paths, box, width, color):
    x0, y0, size = box
    pt = lambda p: (x0 + p[0] / 100 * size, y0 + p[1] / 100 * size)
    w = width / 100 * size
    for path in paths:
        pts = [pt(p) for p in path]
        d.line(pts, fill=color, width=round(w), joint="curve")
        for (x, y) in (pts[0], pts[-1]):
            d.ellipse([x - w / 2, y - w / 2, x + w / 2, y + w / 2], fill=color)

def bubble(d, box, color, tail="left"):
    x0, y0, s = box
    r = s * 0.24
    d.rounded_rectangle([x0, y0, x0 + s, y0 + s * 0.84], radius=r, fill=color)
    if tail == "left":
        d.polygon([(x0 + s * 0.16, y0 + s * 0.72), (x0 + s * 0.40, y0 + s * 0.80), (x0 + s * 0.12, y0 + s * 0.97)], fill=color)

def render(option, px):
    S = px * SS
    im = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    if option == "A":   # clay tile, cream 宁
        d.rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 0.23, fill=CLAY)
        strokes(d, NING, (S * 0.14, S * 0.14, S * 0.72), 11, CREAM)
    elif option == "B":  # cream tile, clay speech bubble with cream 宁
        d.rounded_rectangle([0, 0, S - 1, S - 1], radius=S * 0.23, fill=CREAM)
        bubble(d, (S * 0.12, S * 0.12, S * 0.76), CLAY)
        strokes(d, NING, (S * 0.25, S * 0.17, S * 0.50), 12, CREAM)
    elif option == "C":  # clay speech bubble on its own, cream 宁
        bubble(d, (S * 0.02, S * 0.03, S * 0.96), CLAY)
        strokes(d, NING, (S * 0.19, S * 0.10, S * 0.62), 12, CREAM)
    elif option == "T":  # macOS menu-bar template: black bubble outline + 宁
        bubble(d, (S * 0.02, S * 0.03, S * 0.96), (0, 0, 0, 255))
        strokes(d, NING, (S * 0.19, S * 0.10, S * 0.62), 13, (0, 0, 0, 0))
    return im.resize((px, px), Image.LANCZOS)

if __name__ == "__main__":
    opt = sys.argv[1] if len(sys.argv) > 1 else "A"
    out = sys.argv[2] if len(sys.argv) > 2 else HERE
    os.makedirs(out, exist_ok=True)
    big = render(opt, 256)
    big.save(os.path.join(out, "icon.png"))
    big.save(os.path.join(out, "icon.ico"), sizes=[(16, 16), (20, 20), (24, 24), (32, 32), (48, 48), (64, 64), (256, 256)],
             append_images=[render(opt, s) for s in (16, 20, 24, 32, 48, 64)])
    render("T", 36).save(os.path.join(out, "menubar@2x.png"))
    render("T", 18).save(os.path.join(out, "menubar.png"))
