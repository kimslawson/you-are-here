#!/usr/bin/env python3
"""Regenerate the You Are Here app icon (1024x1024, opaque RGB).

The icon is the app in miniature: grey "YOU / ARE" kicker stacked flush-left, a
big bright "HERE", and a rough treasure-map red X in the upper-right corner. On
near-black to match the app's bright-on-dark skin.

Usage:
    pip install Pillow
    python3 design/appicon.py
Writes: YouAreHere/Assets.xcassets/AppIcon.appiconset/AppIcon.png

Font: Liberation Sans Bold (a Helvetica/Arial metric-compatible grotesque) is a
stand-in for the app's Helvetica Neue. Point it at any bold grotesque you like.
"""
import os, random, math
from PIL import Image, ImageDraw, ImageFont

SS = 4                      # supersample for crisp anti-aliasing
W = 1024
S = W * SS
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "YouAreHere", "Assets.xcassets", "AppIcon.appiconset", "AppIcon.png")

# Pick the first font that exists.
FONT_CANDIDATES = [
    "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
    "/System/Library/Fonts/HelveticaNeue.ttc",
    "/Library/Fonts/Arial Bold.ttf",
]
FONTP = next((p for p in FONT_CANDIDATES if os.path.exists(p)), FONT_CANDIDATES[0])

BG    = (10, 10, 12)
WHITE = (247, 247, 242)
GREY  = (150, 154, 162)
RED   = (220, 36, 38)

def f(px): return ImageFont.truetype(FONTP, int(px))

def hand_stroke(d, p1, p2, w, color, rnd, segs=16, taper=0.5):
    """A single organic, hand-drawn stroke: width tapers thin->thick->thin and
    the path wanders slightly off the straight line."""
    x1, y1 = p1; x2, y2 = p2; dx, dy = x2 - x1, y2 - y1
    L = math.hypot(dx, dy); px, py = -dy / L, dx / L
    phase = rnd.uniform(0, 6); pts = []
    for i in range(segs + 1):
        t = i / segs
        wob = math.sin(t * math.pi * 1.7 + phase) * w * 0.16 + rnd.uniform(-w * 0.10, w * 0.10)
        pts.append((x1 + dx * t + px * wob, y1 + dy * t + py * wob, t))
    for i in range(segs):
        a = pts[i]; b = pts[i + 1]; tm = (a[2] + b[2]) / 2
        ww = max(1, int(w * (taper + (1 - taper) * math.sin(tm * math.pi))))
        d.line([a[0], a[1], b[0], b[1]], fill=color, width=ww)
        r = ww * 0.5
        d.ellipse([b[0] - r, b[1] - r, b[0] + r, b[1] + r], fill=color)

def rough_x(d, cx, cy, L, w, color, seed=21, rot=-4):
    rnd = random.Random(seed); th = math.radians(rot)
    def rot_(px, py):
        x = px - cx; y = py - cy
        return (cx + x * math.cos(th) - y * math.sin(th), cy + x * math.sin(th) + y * math.cos(th))
    over = 1.10
    for a, b in [((-over, -over), (over, over)), ((-over, over), (over, -over))]:
        p1 = rot_(cx + a[0] * L, cy + a[1] * L); p2 = rot_(cx + b[0] * L, cy + b[1] * L)
        hand_stroke(d, p1, p2, w, color, rnd)
        hand_stroke(d, (p1[0] + rnd.uniform(-w*0.3, w*0.3), p1[1] + rnd.uniform(-w*0.3, w*0.3)),
                       (p2[0] + rnd.uniform(-w*0.3, w*0.3), p2[1] + rnd.uniform(-w*0.3, w*0.3)),
                    w * 0.55, color, rnd)

def render():
    img = Image.new("RGB", (S, S), BG)        # RGB = opaque, no alpha (iOS requires)
    d = ImageDraw.Draw(img, "RGBA")
    x0 = int(0.105 * S)

    target_big_w = 0.74 * S
    probe = f(1000); pb = d.textbbox((0, 0), "HERE", font=probe)
    big_px = 1000 * target_big_w / (pb[2] - pb[0])
    fb = f(big_px); fs = f(big_px * 0.56)

    sb = d.textbbox((0, 0), "ARE", font=fs); sh = sb[3] - sb[1]
    bb = d.textbbox((0, 0), "HERE", font=fb); bh = bb[3] - bb[1]
    line_gap = sh * 0.14; big_gap = sh * 0.36
    total = sh + line_gap + sh + big_gap + bh
    y = (S - total) / 2 + 0.012 * S

    def left(text, font, yy, color):
        b = d.textbbox((0, 0), text, font=font)
        d.text((x0 - b[0], yy - b[1]), text, font=font, fill=color)

    left("YOU", fs, y, GREY); y += sh + line_gap
    left("ARE", fs, y, GREY); y += sh + big_gap
    left("HERE", fb, y, WHITE)

    rough_x(d, 0.720 * S, 0.300 * S, 0.140 * S, 0.047 * S, RED, seed=21, rot=-4)

    img.resize((W, W), Image.LANCZOS).save(os.path.normpath(OUT))
    print("wrote", os.path.normpath(OUT))

if __name__ == "__main__":
    render()
