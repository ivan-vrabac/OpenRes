#!/usr/bin/env python3
"""Draws the 50 Campus pictures for the map (app/assets/game/campus/campus_01..50.png): the
company's 7-hex property seen straight from above (sun from the north-west), exactly the
property's shape (transparent outside) so the map can lay it over the 7 hexes.

One fixed master plan that fills in level by level: the entrance road from the south, the
admin building on the central plaza, the warehouse and loading yard (west), the factories
(east), the workshops and logistics hall (north), the green courtyard (north hex), the
container yard and the offices with parking (south). Roads mature from dirt to gravel to
asphalt to a boulevard. Five stages (gamedata.CAMPUS_STAGES) with something new at every level.
Drawn from code: CC BY-NC 4.0 like the repository. Needs Pillow and numpy.

    python tools/draw_campus.py [--sheet out.png] [--big out.png]
"""
from __future__ import annotations

import math
import random
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))
import gamedata as g  # noqa: E402

R = 15.0                                # hex circumradius (m), flat-top
D = R * math.sqrt(3)                    # centre to centre
HALF_W = 2.5 * R                        # the 7-hex shape: 75 m wide ...
HALF_H = D + D / 2                      # ... 77.9 m tall
PX_PER_M = 8
SS = 2                                  # supersampling
K = PX_PER_M * SS                       # drawing pixels per metre
W, H = round(2 * HALF_W * PX_PER_M), round(2 * HALF_H * PX_PER_M)
WS, HS = W * SS, H * SS
CENTRES = [(0.0, 0.0)] + [(D * math.sin(math.radians(60 * k)), D * math.cos(math.radians(60 * k))) for k in range(6)]
SHADOW = 0.42                           # shadow length per metre of height, towards the south-east

# the master plan (metres east/north of the centre)
CROSS_Y = -13.5                         # the main street, west to east
NORTH_Y = 15.5                          # the service road behind the blocks
RING_X = 26.5                           # the two side roads joining them


def px(x: float, y: float) -> tuple[float, float]:
    return ((x + HALF_W) * K, (HALF_H - y) * K)


def inside(x: float, y: float, margin: float = 0.0) -> bool:
    """Whether (x, y), and everything within `margin` of it, is on the property."""
    h = R * math.sqrt(3) / 2 + 1e-6
    for k in range(9 if margin else 1):
        a = k * math.pi / 4
        qx, qy = (x, y) if k == 8 or not margin else (x + margin * math.cos(a), y + margin * math.sin(a))
        if not any(abs(qy - cy) <= h and math.sqrt(3) * abs(qx - cx) + abs(qy - cy) <= 2 * h for cx, cy in CENTRES):
            return False
    return True


def lerp(a: float, b: float, lv: int, lo: int, hi: int) -> float:
    t = min(1.0, max(0.0, (lv - lo) / max(1, hi - lo)))
    return a + (b - a) * t


def shade(c, k: float):
    return tuple(max(0, min(255, round(v * k))) for v in c[:3]) + (255,)


def hull(pts):
    pts = sorted(set(pts))
    if len(pts) < 3:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def rect_pts(cx, cy, w, h):
    return [(cx - w / 2, cy - h / 2), (cx + w / 2, cy - h / 2), (cx + w / 2, cy + h / 2), (cx - w / 2, cy + h / 2)]


def circle_pts(cx, cy, r, n=20):
    return [(cx + r * math.cos(2 * math.pi * k / n), cy + r * math.sin(2 * math.pi * k / n)) for k in range(n)]


def noise(rnd: np.random.Generator, scale: float) -> np.ndarray:
    """Smooth noise in -1..1 over the whole picture, features about `scale` metres."""
    gw, gh = max(2, int(WS / (scale * K)) + 2), max(2, int(HS / (scale * K)) + 2)
    small = Image.fromarray(((rnd.random((gh, gw)) * 255).astype(np.uint8)), "L")
    return np.asarray(small.resize((WS, HS), Image.BICUBIC), dtype=np.float32) / 127.5 - 1.0


class Scene:
    """Layers in metres: ground surfaces, then the shadows of everything standing, then the
    standing things lowest first."""

    def __init__(self, level: int):
        self.lv = level
        self.rnd = random.Random(level * 7919)
        self.nrnd = np.random.default_rng(1234)          # textures stay the same at every level
        self.img = Image.new("RGBA", (WS, HS), (0, 0, 0, 255))
        self.d = ImageDraw.Draw(self.img)
        self.shadow = Image.new("L", (WS, HS), 0)
        self.sd = ImageDraw.Draw(self.shadow)
        self.things: list[tuple[float, int, callable]] = []
        self._fine = self.nrnd.random((HS, WS)).astype(np.float32) * 2 - 1
        self._n1 = noise(self.nrnd, 1.5)
        self._n6 = noise(self.nrnd, 6.0)
        self.warnings: list[str] = []

    # ── surfaces ─────────────────────────────────────────────────────────────
    def texture(self, base, fine=10.0, mid=8.0, broad=10.0, speckle=0.0, spots=None) -> Image.Image:
        a = np.empty((HS, WS, 3), np.float32)
        a[:] = base[:3]
        v = self._fine[..., None] * fine + self._n1[..., None] * mid + self._n6[..., None] * broad
        a += v
        if speckle:
            m = self._fine > 1 - speckle
            a[m] *= 0.75
            m2 = self._fine < -1 + speckle
            a[m2] = a[m2] * 0.6 + 255 * 0.4
        if spots is not None:
            col, amount = spots
            m = (self._n1 > 1 - amount)
            a[m] = a[m] * 0.4 + np.array(col, np.float32) * 0.6
        out = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
        return out

    def paint(self, tex: Image.Image, mask: Image.Image):
        self.img.paste(tex, (0, 0), mask)

    def mask(self) -> tuple[Image.Image, ImageDraw.ImageDraw]:
        m = Image.new("L", (WS, HS), 0)
        return m, ImageDraw.Draw(m)

    def poly(self, d, pts, fill, outline=None, width=0):
        d.polygon([px(*p) for p in pts], fill=fill, outline=outline, width=round(width * K) if width else 0)

    def rect(self, d, cx, cy, w, h, fill, outline=None, width=0.0):
        x0, y0 = px(cx - w / 2, cy + h / 2)
        x1, y1 = px(cx + w / 2, cy - h / 2)
        d.rectangle((x0, y0, x1, y1), fill=fill, outline=outline, width=max(1, round(width * K)) if outline else 0)

    def ellipse(self, d, cx, cy, rx, ry, fill, outline=None, width=0.0):
        x0, y0 = px(cx - rx, cy + ry)
        x1, y1 = px(cx + rx, cy - ry)
        d.ellipse((x0, y0, x1, y1), fill=fill, outline=outline, width=max(1, round(width * K)) if outline else 0)

    def line(self, d, pts, fill, width):
        d.line([px(*p) for p in pts], fill=fill, width=max(1, round(width * K)))

    def check(self, what, pts, margin=0.3):
        bad = [(round(x, 1), round(y, 1)) for x, y in pts if not inside(x, y, margin)]
        if bad:
            self.warnings.append(f"{what}@{bad[0]}")

    # ── standing things ──────────────────────────────────────────────────────
    def cast(self, footprint, height):
        L = height * SHADOW
        pts = footprint + [(x + L, y - L) for x, y in footprint]
        self.sd.polygon([px(*p) for p in hull(pts)], fill=255)

    def stand(self, height, footprint, draw, check=None):
        self.cast(footprint, height)
        if check:
            self.check(check, footprint)
        self.things.append((height, len(self.things), draw))

    def finish(self) -> Image.Image:
        blur = self.shadow.filter(ImageFilter.GaussianBlur(0.25 * K))
        dark = Image.new("RGBA", (WS, HS), (18, 22, 30, 255))
        self.img = Image.composite(dark, self.img, blur.point(lambda v: v * 0.5))
        self.d = ImageDraw.Draw(self.img)
        for _h, _i, fn in sorted(self.things, key=lambda t: (t[0], t[1])):
            fn(self.d)
        m = Image.new("L", (WS, HS), 0)
        md = ImageDraw.Draw(m)
        for cx, cy in CENTRES:
            md.polygon([px(cx + (R + 0.05) * math.cos(math.radians(60 * k)), cy + (R + 0.05) * math.sin(math.radians(60 * k)))
                        for k in range(6)], fill=255)
        self.img.putalpha(m)
        return self.img.resize((W, H), Image.LANCZOS)


# ── objects ──────────────────────────────────────────────────────────────────

def roof_units(s: Scene, d, cx, cy, w, h, n, rnd):
    for _ in range(n):
        ux, uy = cx + rnd.uniform(-w / 2 + 1.2, w / 2 - 1.2), cy + rnd.uniform(-h / 2 + 1.2, h / 2 - 1.2)
        s.rect(d, ux + 0.15, uy - 0.15, 1.6, 1.2, (110, 112, 116, 255))
        s.rect(d, ux, uy, 1.6, 1.2, (196, 198, 200, 255), (140, 142, 146, 255), 0.06)
        s.ellipse(d, ux, uy, 0.42, 0.42, (70, 72, 76, 255))


def building(s: Scene, cx, cy, w, h, height, style="flat", color=None, units=0, solar=0.0, green=False,
             skylights=False, label="building"):
    """A building seen from straight above: its roof, by style."""
    rnd = random.Random(int(cx * 31 + cy * 17 + w * 7))

    def draw(d):
        edge = (90, 92, 96, 255)
        if style == "flat":
            c = color or (186, 184, 178)
            s.rect(d, cx, cy, w, h, c + (255,), edge, 0.08)
            s.rect(d, cx, cy, w - 0.7, h - 0.7, shade(c, 0.93))          # parapet around a gravel roof
            for _ in range(int(w * h / 3)):
                gx, gy = cx + rnd.uniform(-w / 2 + 0.5, w / 2 - 0.5), cy + rnd.uniform(-h / 2 + 0.5, h / 2 - 0.5)
                s.ellipse(d, gx, gy, 0.08, 0.08, shade(c, rnd.choice([0.82, 1.08])))
            s.line(d, [(cx - w / 2 + 0.35, cy + h / 2 - 0.35), (cx + w / 2 - 0.35, cy + h / 2 - 0.35)], shade(c, 1.12), 0.12)
            s.line(d, [(cx - w / 2 + 0.35, cy + h / 2 - 0.35), (cx - w / 2 + 0.35, cy - h / 2 + 0.35)], shade(c, 1.12), 0.12)
        elif style == "metal":                                          # ribbed sheet, ridge along the length
            c = color or (168, 172, 176)
            s.rect(d, cx, cy, w, h, c + (255,), edge, 0.08)
            along_x = w >= h
            if along_x:
                s.rect(d, cx, cy + h / 4, w, h / 2, shade(c, 1.1))       # the north half catches the sun
                s.rect(d, cx, cy - h / 4, w, h / 2, shade(c, 0.88))
                x = cx - w / 2 + 0.45
                while x < cx + w / 2:
                    s.line(d, [(x, cy - h / 2), (x, cy + h / 2)], shade(c, 0.78), 0.06)
                    x += 0.9
                s.line(d, [(cx - w / 2, cy), (cx + w / 2, cy)], shade(c, 1.25), 0.18)
            else:
                s.rect(d, cx - w / 4, cy, w / 2, h, shade(c, 1.1))       # the west half catches the sun
                s.rect(d, cx + w / 4, cy, w / 2, h, shade(c, 0.88))
                y = cy - h / 2 + 0.45
                while y < cy + h / 2:
                    s.line(d, [(cx - w / 2, y), (cx + w / 2, y)], shade(c, 0.78), 0.06)
                    y += 0.9
                s.line(d, [(cx, cy - h / 2), (cx, cy + h / 2)], shade(c, 1.25), 0.18)
            s.rect(d, cx, cy, w, h, None, edge, 0.08)
        elif style == "sawtooth":                                       # north-light roof: glazing strips facing north
            c = color or (176, 170, 160)
            s.rect(d, cx, cy, w, h, c + (255,), edge, 0.08)
            pitch = 3.2
            y = cy - h / 2
            while y < cy + h / 2 - 0.2:
                top = min(y + pitch, cy + h / 2)
                for k in range(8):                                      # the slope darkens towards its foot
                    y0 = y + (top - y) * k / 8
                    s.rect(d, cx, y0 + (top - y) / 16, w - 0.2, (top - y) / 8, shade(c, 0.86 + 0.03 * k))
                s.rect(d, cx, top - 0.45, w - 0.2, 0.9, (70, 96, 120, 255))     # the glazing
                s.line(d, [(cx - w / 2, top - 0.02), (cx + w / 2, top - 0.02)], (220, 224, 226, 255), 0.1)
                x = cx - w / 2 + 1.2
                while x < cx + w / 2 - 0.5:
                    s.line(d, [(x, top - 0.9), (x, top)], (40, 52, 66, 255), 0.05)
                    x += 1.2
                y = top
            s.rect(d, cx, cy, w, h, None, edge, 0.1)
        elif style == "glass":                                          # glazed roof with mullions and a sky reflection
            c = color or (104, 148, 172)
            s.rect(d, cx, cy, w, h, c + (255,), (60, 70, 80, 255), 0.12)
            for k in range(14):                                         # brighter towards the north-west
                f = k / 13
                s.poly(d, [(cx - w / 2, cy + h / 2 - f * h), (cx - w / 2 + f * w, cy + h / 2),
                           (cx - w / 2 + min(w, f * w + 1.4), cy + h / 2), (cx - w / 2, cy + h / 2 - min(h, f * h + 1.4))],
                       shade(c, 1.28 - 0.025 * k))
            gx = cx - w / 2 + 1.5
            while gx < cx + w / 2:
                s.line(d, [(gx, cy - h / 2), (gx, cy + h / 2)], (200, 214, 222, 255), 0.07)
                gx += 1.5
            gy = cy - h / 2 + 1.5
            while gy < cy + h / 2:
                s.line(d, [(cx - w / 2, gy), (cx + w / 2, gy)], (200, 214, 222, 255), 0.07)
                gy += 1.5
            s.rect(d, cx, cy, w, h, None, (220, 226, 230, 255), 0.25)
        if green:                                                       # planted roof inside a gravel edge
            s.rect(d, cx, cy, w - 1.4, h - 1.4, (96, 142, 70, 255))
            for _ in range(int(w * h / 1.5)):
                gx, gy = cx + rnd.uniform(-w / 2 + 0.9, w / 2 - 0.9), cy + rnd.uniform(-h / 2 + 0.9, h / 2 - 0.9)
                s.ellipse(d, gx, gy, 0.3, 0.3, rnd.choice([(80, 128, 60, 255), (116, 158, 82, 255), (140, 150, 76, 255)]))
            s.line(d, [(cx - w / 2 + 0.7, cy), (cx + w / 2 - 0.7, cy)], (200, 196, 186, 255), 0.5)
        if skylights:
            n = max(1, int(w / 4))
            for i in range(n):
                sx = cx - w / 2 + (i + 0.5) * w / n
                s.rect(d, sx, cy, 1.2, h * 0.7, (150, 186, 206, 255), (70, 80, 90, 255), 0.06)
        if solar > 0:                                                   # rows of panels over part of the roof
            rows = int((h - 2) / 2.2)
            cols_w = (w - 2) * solar
            for r_ in range(rows):
                ry = cy - h / 2 + 1.4 + r_ * 2.2
                s.rect(d, cx - w / 2 + 1 + cols_w / 2, ry + 0.7, cols_w, 1.5, (38, 54, 92, 255), (150, 160, 180, 255), 0.05)
                xx = cx - w / 2 + 1
                while xx < cx - w / 2 + 1 + cols_w:
                    s.line(d, [(xx, ry), (xx, ry + 1.5)], (110, 124, 156, 255), 0.04)
                    xx += 1.0
        if units:
            roof_units(s, d, cx, cy, w, h, units, rnd)

    s.stand(height, rect_pts(cx, cy, w, h), draw, label)


def tent(s, cx, cy, w, h, color):
    def draw(d):
        s.rect(d, cx - w / 4, cy, w / 2, h, shade(color, 1.12))          # the west slope in the sun
        s.rect(d, cx + w / 4, cy, w / 2, h, shade(color, 0.8))
        s.line(d, [(cx, cy - h / 2), (cx, cy + h / 2)], shade(color, 0.6), 0.1)
        for gy in (cy - h / 2 - 0.4, cy + h / 2 + 0.4):                  # guy ropes and pegs
            s.line(d, [(cx, cy - h / 2 if gy < cy else cy + h / 2), (cx, gy)], (230, 230, 220, 255), 0.04)
    s.stand(2.2, rect_pts(cx, cy, w, h), draw, "tent")


def cabin(s, cx, cy, w=6.0, h=2.5, color=(214, 214, 206)):
    """A site cabin: white box, ribbed roof, small AC unit."""
    def draw(d):
        s.rect(d, cx, cy, w, h, color + (255,), (120, 120, 116, 255), 0.06)
        x = cx - w / 2 + 0.3
        while x < cx + w / 2:
            s.line(d, [(x, cy - h / 2 + 0.1), (x, cy + h / 2 - 0.1)], shade(color, 0.86), 0.05)
            x += 0.6
        s.rect(d, cx + w / 2 - 1.0, cy, 0.8, 0.8, (180, 182, 186, 255), (110, 110, 110, 255), 0.05)
    s.stand(2.7, rect_pts(cx, cy, w, h), draw, "cabin")


CONTAINER_COLOURS = [(170, 62, 48), (44, 92, 150), (64, 122, 82), (206, 146, 44), (124, 124, 130), (160, 104, 60)]


def container(s, cx, cy, vertical=False, color=None, high=1):
    color = color or CONTAINER_COLOURS[int(abs(cx * 3 + cy * 7)) % len(CONTAINER_COLOURS)]
    w, h = (2.44, 6.06) if vertical else (6.06, 2.44)

    def draw(d):
        s.rect(d, cx, cy, w, h, color + (255,), shade(color, 0.6), 0.06)
        if vertical:
            y = cy - h / 2 + 0.25
            while y < cy + h / 2:
                s.line(d, [(cx - w / 2 + 0.1, y), (cx + w / 2 - 0.1, y)], shade(color, 0.8), 0.06)
                y += 0.5
        else:
            x = cx - w / 2 + 0.25
            while x < cx + w / 2:
                s.line(d, [(x, cy - h / 2 + 0.1), (x, cy + h / 2 - 0.1)], shade(color, 0.8), 0.06)
                x += 0.5
        s.rect(d, cx, cy, w, h, None, shade(color, 1.2), 0.04)
    s.stand(2.6 * high, rect_pts(cx, cy, w, h), draw, "container")


def car(s, cx, cy, vertical=False, color=None, rnd=None):
    rnd = rnd or s.rnd
    color = color or rnd.choice([(190, 40, 40), (40, 80, 170), (235, 235, 235), (30, 30, 34), (200, 200, 205),
                                 (120, 124, 130), (220, 180, 40), (20, 60, 50)])
    w, h = (1.8, 4.4) if vertical else (4.4, 1.8)
    up = rnd.random() < 0.5

    def draw(d):
        s.rect(d, cx, cy, w, h, color + (255,), shade(color, 0.55), 0.05)
        if vertical:
            f = 1 if up else -1
            s.rect(d, cx, cy + f * 0.75, 1.5, 0.7, (40, 50, 62, 255))   # windscreen
            s.rect(d, cx, cy - f * 1.35, 1.5, 0.45, (40, 50, 62, 255))  # rear window
            s.rect(d, cx, cy - f * 0.3, 1.4, 1.3, shade(color, 1.12))   # roof
        else:
            f = 1 if up else -1
            s.rect(d, cx + f * 0.75, cy, 0.7, 1.5, (40, 50, 62, 255))
            s.rect(d, cx - f * 1.35, cy, 0.45, 1.5, (40, 50, 62, 255))
            s.rect(d, cx - f * 0.3, cy, 1.3, 1.4, shade(color, 1.12))
    s.stand(1.45, rect_pts(cx, cy, w, h), draw, "car")


def truck(s, cx, cy, vertical=False, trailer=(236, 236, 232), cab=(200, 40, 36), length=12.0, north=True):
    """A lorry: cab plus a box trailer with roof ribs. `north`: which way the cab faces."""
    tw = 2.5
    f = 1 if north else -1

    def draw(d):
        if vertical:
            s.rect(d, cx, cy - f * 1.6, tw, length - 3.2, trailer + (255,), shade(trailer, 0.6), 0.06)
            y = cy - f * 1.6 - (length - 3.2) / 2 + 0.5
            while y < cy - f * 1.6 + (length - 3.2) / 2:
                s.line(d, [(cx - tw / 2 + 0.1, y), (cx + tw / 2 - 0.1, y)], shade(trailer, 0.88), 0.05)
                y += 1.0
            s.rect(d, cx, cy + f * (length / 2 - 1.2), tw - 0.1, 2.3, cab + (255,), shade(cab, 0.55), 0.06)
            s.rect(d, cx, cy + f * (length / 2 - 0.35), tw - 0.4, 0.5, (40, 50, 62, 255))
        else:
            s.rect(d, cx - f * 1.6, cy, length - 3.2, tw, trailer + (255,), shade(trailer, 0.6), 0.06)
            x = cx - f * 1.6 - (length - 3.2) / 2 + 0.5
            while x < cx - f * 1.6 + (length - 3.2) / 2:
                s.line(d, [(x, cy - tw / 2 + 0.1), (x, cy + tw / 2 - 0.1)], shade(trailer, 0.88), 0.05)
                x += 1.0
            s.rect(d, cx + f * (length / 2 - 1.2), cy, 2.3, tw - 0.1, cab + (255,), shade(cab, 0.55), 0.06)
            s.rect(d, cx + f * (length / 2 - 0.35), cy, 0.5, tw - 0.4, (40, 50, 62, 255))
    w, h = (tw, length) if vertical else (length, tw)
    s.stand(3.8, rect_pts(cx, cy, w, h), draw, "truck")


def pickup(s, cx, cy, color=(228, 228, 222)):
    def draw(d):
        s.rect(d, cx, cy, 1.9, 5.2, color + (255,), shade(color, 0.55), 0.05)
        s.rect(d, cx, cy + 1.2, 1.6, 0.6, (40, 50, 62, 255))
        s.rect(d, cx, cy - 1.2, 1.6, 2.2, shade(color, 0.72), shade(color, 0.5), 0.05)   # the bed
        s.rect(d, cx - 0.3, cy - 1.0, 0.7, 0.9, (150, 112, 70, 255))                     # something in it
    s.stand(1.8, rect_pts(cx, cy, 1.9, 5.2), draw, "pickup")


def forklift(s, cx, cy):
    def draw(d):
        s.rect(d, cx, cy, 1.1, 2.2, (232, 180, 30, 255), (120, 90, 10, 255), 0.05)
        s.rect(d, cx, cy - 0.2, 0.9, 0.9, (40, 40, 44, 255))
        for dx in (-0.3, 0.3):
            s.line(d, [(cx + dx, cy + 1.1), (cx + dx, cy + 2.1)], (60, 60, 64, 255), 0.12)
    s.stand(2.2, rect_pts(cx, cy, 1.1, 2.2), draw, "forklift")


def excavator(s, cx, cy):
    def draw(d):
        for dx in (-1.2, 1.2):
            s.rect(d, cx + dx, cy, 0.7, 4.2, (50, 50, 52, 255))
            yy = cy - 2.0
            while yy < cy + 2.1:
                s.line(d, [(cx + dx - 0.35, yy), (cx + dx + 0.35, yy)], (90, 90, 92, 255), 0.05)
                yy += 0.4
        s.rect(d, cx, cy + 0.2, 2.6, 2.9, (236, 178, 26, 255), (120, 88, 10, 255), 0.06)
        s.rect(d, cx - 0.6, cy + 0.9, 0.9, 1.0, (40, 50, 62, 255))
        s.line(d, [(cx + 0.3, cy + 1.4), (cx + 2.2, cy + 4.4)], (236, 178, 26, 255), 0.45)
        s.line(d, [(cx + 2.2, cy + 4.4), (cx + 2.8, cy + 6.0)], (220, 160, 20, 255), 0.35)
        s.rect(d, cx + 2.9, cy + 6.3, 1.0, 0.6, (60, 60, 62, 255))
    s.stand(3.0, rect_pts(cx + 0.8, cy + 1.8, 3.8, 7.6), draw, "excavator")


def tree(s, cx, cy, r, col=(52, 104, 46), height=None):
    rnd = random.Random(int(cx * 97 + cy * 53))

    def draw(d):
        s.ellipse(d, cx, cy, r, r, shade(col, 0.82))
        for _ in range(6):                                               # clumps
            a, rr = rnd.uniform(0, 2 * math.pi), rnd.uniform(0, r * 0.5)
            s.ellipse(d, cx + rr * math.cos(a), cy + rr * math.sin(a), r * 0.5, r * 0.5, shade(col, rnd.uniform(0.9, 1.05)))
        s.ellipse(d, cx - r * 0.3, cy + r * 0.3, r * 0.42, r * 0.42, shade(col, 1.28))   # light from the north-west
        s.ellipse(d, cx - r * 0.35, cy + r * 0.38, r * 0.18, r * 0.18, shade(col, 1.45))
    s.stand(height or r * 2.6, circle_pts(cx, cy, r * 0.85, 12), draw, None)


def person(s, cx, cy, rnd=None):
    rnd = rnd or s.rnd
    shirt = rnd.choice([(230, 120, 30), (240, 220, 40), (40, 70, 160), (200, 50, 50), (240, 240, 240), (40, 40, 40)])

    def draw(d):
        s.ellipse(d, cx, cy, 0.3, 0.22, shirt + (255,))
        s.ellipse(d, cx, cy, 0.13, 0.13, rnd.choice([(70, 50, 30, 255), (200, 160, 110, 255), (20, 20, 20, 255)]))
    s.stand(1.7, circle_pts(cx, cy, 0.18, 6), draw, None)


def tank(s, cx, cy, r, height, color=(206, 208, 210), ladder=True):
    def draw(d):
        s.ellipse(d, cx, cy, r, r, color + (255,), shade(color, 0.6), 0.08)
        for k in range(6):
            rr = r * (1 - k / 7)
            s.ellipse(d, cx - (r - rr) * 0.25, cy + (r - rr) * 0.25, rr, rr, shade(color, 0.92 + 0.04 * k))
        s.ellipse(d, cx, cy, r * 0.12, r * 0.12, shade(color, 0.7))
        if ladder:
            s.line(d, [(cx + r * 0.1, cy), (cx + r, cy)], (90, 92, 96, 255), 0.12)
    s.stand(height, circle_pts(cx, cy, r), draw, "tank")


def chimney(s, cx, cy, r, height):
    def draw(d):
        s.ellipse(d, cx, cy, r, r, (150, 70, 56, 255), (90, 40, 30, 255), 0.06)
        s.ellipse(d, cx, cy, r * 0.62, r * 0.62, (32, 30, 30, 255))
        s.ellipse(d, cx, cy, r * 1.0, r * 1.0, None, (236, 236, 236, 255), 0.18)
    s.stand(height, circle_pts(cx, cy, r), draw, "chimney")


def cooling_tower(s, cx, cy, r):
    def draw(d):
        s.ellipse(d, cx, cy, r, r, (196, 196, 190, 255), (120, 120, 116, 255), 0.1)
        s.ellipse(d, cx, cy, r * 0.82, r * 0.82, (90, 96, 100, 255))
        for k in range(8):
            a = k * math.pi / 4
            s.line(d, [(cx, cy), (cx + r * 0.8 * math.cos(a), cy + r * 0.8 * math.sin(a))], (150, 154, 156, 255), 0.06)
        s.ellipse(d, cx, cy, r * 0.32, r * 0.32, (60, 64, 68, 255), (180, 180, 176, 255), 0.06)
    s.stand(4.5, circle_pts(cx, cy, r), draw, "cooling")


def pile(s, cx, cy, rx, ry, color, logs=False):
    rnd = random.Random(int(cx * 11 + cy * 5))

    def draw(d):
        if logs:
            for k in range(int(ry * 2 / 0.5)):
                yy = cy - ry + 0.25 + k * 0.5
                ln = rx * 2 * rnd.uniform(0.85, 1.0)
                s.rect(d, cx, yy, ln, 0.45, (128, 92, 56, 255), (90, 60, 34, 255), 0.03)
                s.ellipse(d, cx - ln / 2, yy, 0.23, 0.23, (196, 160, 110, 255))
        else:
            for k in range(8):
                f = 1 - k / 8
                s.ellipse(d, cx - (1 - f) * rx * 0.3, cy + (1 - f) * ry * 0.3, rx * f, ry * f, shade(color, 0.85 + 0.04 * k))
            for _ in range(int(rx * ry * 4)):
                a, rr = rnd.uniform(0, 2 * math.pi), rnd.uniform(0, 0.9)
                s.ellipse(d, cx + rr * rx * math.cos(a), cy + rr * ry * math.sin(a), 0.07, 0.07, shade(color, rnd.choice([0.7, 1.2])))
    s.stand(1.2 if logs else 1.8, circle_pts(cx, cy, max(rx, ry) * 0.9, 10), draw, None)


def lamp(s, cx, cy):
    def draw(d):
        s.ellipse(d, cx, cy, 0.18, 0.18, (70, 72, 76, 255))
        s.rect(d, cx + 0.45, cy, 0.9, 0.12, (90, 92, 96, 255))
        s.ellipse(d, cx + 0.9, cy, 0.22, 0.16, (250, 236, 180, 255))
    s.stand(6.0, [(cx - 0.1, cy - 0.1), (cx + 0.1, cy - 0.1), (cx + 0.1, cy + 0.1), (cx - 0.1, cy + 0.1)], draw, None)


def flagpole(s, cx, cy, color):
    def draw(d):
        s.ellipse(d, cx, cy, 0.15, 0.15, (220, 220, 220, 255))
        s.poly(d, [(cx + 0.1, cy), (cx + 1.6, cy - 0.3), (cx + 1.6, cy + 0.6), (cx + 0.1, cy + 0.9)], color + (255,))
    s.stand(9.0, [(cx - 0.08, cy - 0.08), (cx + 0.08, cy - 0.08), (cx + 0.08, cy + 0.08), (cx - 0.08, cy + 0.08)], draw, None)


# ── the campus ───────────────────────────────────────────────────────────────

def outline_segments(inset: float):
    """The property's outline (edges no two hexes share), pulled `inset` metres inwards."""
    edges = []
    for cx, cy in CENTRES:
        v = [(cx + R * math.cos(math.radians(60 * k)), cy + R * math.sin(math.radians(60 * k))) for k in range(6)]
        for k in range(6):
            edges.append(((cx, cy), v[k], v[(k + 1) % 6]))
    mid = lambda a, b: ((a[0] + b[0]) / 2, (a[1] + b[1]) / 2)     # noqa: E731
    out = []
    for i, (c, a, b) in enumerate(edges):
        m = mid(a, b)
        if any(j != i and math.dist(m, mid(e[1], e[2])) < 0.3 for j, e in enumerate(edges)):
            continue
        f = (R - inset / (math.sqrt(3) / 2)) / R
        out.append(((c[0] + (a[0] - c[0]) * f, c[1] + (a[1] - c[1]) * f), (c[0] + (b[0] - c[0]) * f, c[1] + (b[1] - c[1]) * f)))
    return out


def fence(s: Scene, style: str, gate: float):
    d = s.d
    for a, b in outline_segments(0.9):
        n = max(2, int(math.dist(a, b) / 0.25))
        pts = [(a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n) for k in range(n + 1)]
        run: list = []
        for p in pts + [None]:
            if p is not None and not (abs(p[0]) < gate and p[1] < -35):
                run.append(p)
                continue
            if len(run) >= 2:
                if style == "tape":                                  # construction fence: posts and red-white tape
                    for k in range(len(run) - 1):
                        s.line(d, [run[k], run[k + 1]], (220, 40, 40, 255) if k % 2 else (245, 245, 245, 255), 0.12)
                    for k in range(0, len(run), 10):
                        s.ellipse(d, run[k][0], run[k][1], 0.12, 0.12, (110, 80, 50, 255))
                elif style == "chain":
                    s.line(d, run, (150, 154, 158, 255), 0.08)
                    for k in range(0, len(run), 12):
                        s.ellipse(d, run[k][0], run[k][1], 0.1, 0.1, (90, 92, 96, 255))
                elif style == "steel":
                    s.line(d, run, (60, 66, 72, 255), 0.14)
                    for k in range(0, len(run), 10):
                        s.rect(d, run[k][0], run[k][1], 0.22, 0.22, (40, 44, 48, 255))
                elif style == "hedge":
                    for p_ in run[::2]:
                        s.ellipse(d, p_[0] - 0.08, p_[1] - 0.08, 0.75, 0.75, (34, 72, 34, 255))
                    for p_ in run[::2]:
                        s.ellipse(d, p_[0], p_[1], 0.62, 0.62, (58, 110, 50, 255))
                    for p_ in run[::3]:
                        s.ellipse(d, p_[0] - 0.2, p_[1] + 0.2, 0.25, 0.25, (86, 140, 66, 255))
            run = []


def surface_for(lv: int) -> str:
    return "dirt" if lv < 6 else "gravel" if lv < 16 else "asphalt"


def draw_level(level: int) -> tuple[Image.Image, list[str]]:
    lv = level
    s = Scene(lv)
    rnd = s.rnd
    at = lambda n: lv >= n                  # noqa: E731
    stage5 = at(39)

    # ── ground ──
    grass = s.texture((100, 140, 68) if lv < 26 else (92, 142, 64), fine=9, mid=8, broad=12,
                      spots=((128, 124, 70), 0.06) if lv < 16 else None)
    s.img.paste(grass, (0, 0))
    if stage5:                                                      # mown lawn stripes
        m, md = s.mask()
        for k in range(-12, 12):
            s.rect(md, k * 3.2, 0, 1.6, 80, 26)
        s.paint(Image.new("RGBA", (WS, HS), (200, 230, 160, 255)), m)
    if lv < 16:                                                     # bare, trampled earth where work goes on
        m, md = s.mask()
        r0 = lerp(10, 26, lv, 1, 15)
        s.ellipse(md, 0, -2, r0, r0 * 0.85, 255)
        if at(3):
            s.ellipse(md, -22, -20, 9, 5, 255)
        if at(7):
            s.ellipse(md, -16, 1, 9, 12, 255)
        if at(10):
            s.ellipse(md, 16, 1, 9, 12, 255)
        m = m.filter(ImageFilter.GaussianBlur(1.2 * K))
        dirt = s.texture((146, 120, 86), fine=12, mid=10, broad=8, speckle=0.04)
        s.paint(dirt, m.point(lambda v: 255 if v > 150 else int(v * 1.2)))

    # ── roads ──
    surf = surface_for(lv)
    road_w = {"dirt": 3.2, "gravel": 4.6, "asphalt": 6.0}[surf]
    spine_w = 11.0 if stage5 else road_w
    m, md = s.mask()
    segs = []                                                         # (x0, y0, x1, y1) centre lines
    segs.append((0, -45, 0, -10 if at(6) else -3))                   # the entrance road from the south
    if at(3):
        half = 20 if lv < 5 else 34
        segs.append((-half, CROSS_Y, half, CROSS_Y))
    if at(6):
        segs.append((-45, CROSS_Y, 45, CROSS_Y))
        segs.append((-RING_X, CROSS_Y, -RING_X, NORTH_Y))
        segs.append((RING_X, CROSS_Y, RING_X, NORTH_Y))
        segs.append((-RING_X, NORTH_Y, RING_X, NORTH_Y))
    for x0, y0, x1, y1 in segs:
        w_ = spine_w if x0 == x1 == 0 else road_w
        s.rect(md, (x0 + x1) / 2, (y0 + y1) / 2, abs(x1 - x0) + w_, abs(y1 - y0) + w_, 255)
    if at(16):                                                        # rounded junction corners
        for cx_, cy_ in ((-RING_X, CROSS_Y), (RING_X, CROSS_Y), (-RING_X, NORTH_Y), (RING_X, NORTH_Y)):
            s.ellipse(md, cx_, cy_, road_w * 0.75, road_w * 0.75, 255)
    if at(26):                                                        # sidewalks along every road
        sw, sd_ = s.mask()
        for x0, y0, x1, y1 in segs:
            w_ = (spine_w if x0 == x1 == 0 else road_w) + 3.2
            s.rect(sd_, (x0 + x1) / 2, (y0 + y1) / 2, abs(x1 - x0) + w_, abs(y1 - y0) + w_, 255)
        s.paint(s.texture((190, 188, 182), fine=6, mid=4, broad=4), sw)
        # paving joints
        pj = Image.new("RGBA", (WS, HS), (0, 0, 0, 0))
        pd = ImageDraw.Draw(pj)
        for k in range(-40, 41):
            s.line(pd, [(k * 1.0, -40), (k * 1.0, 40)], (160, 158, 152, 255), 0.03)
            s.line(pd, [(-40, k * 1.0), (40, k * 1.0)], (160, 158, 152, 255), 0.03)
        s.img.paste(pj, (0, 0), Image.composite(pj.getchannel("A"), Image.new("L", (WS, HS), 0), sw))
    tex = {"dirt": s.texture((128, 102, 72), fine=14, mid=10, broad=6, speckle=0.03),
           "gravel": s.texture((178, 170, 152), fine=22, mid=6, broad=5, speckle=0.12),
           "asphalt": s.texture((64, 66, 70) if lv < 30 else (56, 58, 62), fine=10, mid=3, broad=4, speckle=0.02)}[surf]
    s.paint(tex, m)
    d = s.d
    if surf == "dirt":                                                # wheel ruts
        for x0, y0, x1, y1 in segs:
            for off in (-0.8, 0.8):
                if x0 == x1:
                    s.line(d, [(x0 + off, y0), (x1 + off, y1)], (104, 82, 56, 255), 0.35)
                else:
                    s.line(d, [(x0, y0 + off), (x1, y1 + off)], (104, 82, 56, 255), 0.35)
    elif surf == "asphalt":                                           # kerbs and lane marks
        for x0, y0, x1, y1 in segs:
            w_ = spine_w if x0 == x1 == 0 else road_w
            vert = x0 == x1
            for off in (-w_ / 2, w_ / 2):
                if vert:
                    s.line(d, [(x0 + off, y0), (x1 + off, y1)], (206, 204, 198, 255), 0.18)
                else:
                    s.line(d, [(x0, y0 + off), (x1, y1 + off)], (206, 204, 198, 255), 0.18)
            if stage5 and x0 == x1 == 0:
                continue
            L = math.dist((x0, y0), (x1, y1))
            k = 0.0
            while k < L:
                a = (x0 + (x1 - x0) * k / L, y0 + (y1 - y0) * k / L)
                b = (x0 + (x1 - x0) * min(L, k + 1.5) / L, y0 + (y1 - y0) * min(L, k + 1.5) / L)
                s.line(d, [a, b], (236, 236, 228, 255), 0.13)
                k += 3.5
        # zebra crossings in front of the plaza and the gate
        for cy_ in (CROSS_Y,):
            for k in range(-3, 4):
                s.rect(d, k * 0.9, cy_ + (road_w / 2 + 1.0 if not stage5 else road_w / 2 + 1.0) - 6.6 - 0.0 + 4.0, 0.45, 2.4,
                       (236, 236, 228, 255))
    elif surf == "gravel":
        for x0, y0, x1, y1 in segs:
            w_ = road_w
            for off in (-w_ / 2, w_ / 2):
                if x0 == x1:
                    s.line(d, [(x0 + off, y0), (x1 + off, y1)], (150, 142, 124, 255), 0.12)
                else:
                    s.line(d, [(x0, y0 + off), (x1, y1 + off)], (150, 142, 124, 255), 0.12)
    if stage5:                                                        # the boulevard: two carriageways, planted median
        s.rect(d, 0, (-45 - 10) / 2, 2.6, 35, (110, 150, 74, 255), (206, 204, 198, 255), 0.18)
        for side in (-1, 1):
            k = -44.0
            while k < -11:
                s.line(d, [(side * 2.6, k), (side * 2.6, k + 1.5)], (236, 236, 228, 255), 0.12)
                k += 3.5

    # ── fence ──
    gate = spine_w / 2 + (2.2 if at(26) else 0.6)
    if at(39):
        fence(s, "hedge", gate)
    elif at(16):
        fence(s, "steel", gate)
    elif at(6):
        fence(s, "chain", gate)
    elif at(5):
        fence(s, "tape", gate)

    # ── central plaza and admin ──
    if at(16):
        m, md = s.mask()
        pw = 17.0 if lv < 26 else 19.0
        s.rect(md, 0, -6.6, pw, 6.6, 255)
        if at(26):
            s.rect(md, 0, 2.5, 21, 21, 255)
        pave = s.texture((206, 200, 188) if lv < 39 else (214, 206, 190), fine=6, mid=5, broad=4)
        s.paint(pave, m)
        step = 1.2 if lv < 26 else 2.0
        k = -12.0
        while k < 12:
            s.line(d, [(k, -9.9), (k, -3.3)], (180, 174, 162, 255), 0.04)
            k += step
        k = -9.9
        while k < -3.3:
            s.line(d, [(-pw / 2, k), (pw / 2, k)], (180, 174, 162, 255), 0.04)
            k += step
        if at(26):                                                     # inlaid ring on the plaza
            s.ellipse(d, 0, -6.6, 2.8, 2.8, None, (150, 140, 124, 255), 0.25)
    if at(39):                                                         # fountain
        s.ellipse(d, 0, -6.6, 2.6, 2.6, (196, 192, 184, 255), (150, 146, 138, 255), 0.2)
        s.ellipse(d, 0, -6.6, 2.2, 2.2, (70, 130, 170, 255))
        for k in range(10):
            s.ellipse(d, -0.5 + 0.05 * k, -6.2 - 0.04 * k, 1.6 - 0.12 * k, 1.6 - 0.12 * k, (90 + 8 * k, 150 + 6 * k, 190 + 5 * k, 255))
        s.ellipse(d, 0, -6.6, 0.35, 0.35, (236, 246, 250, 255))

    if lv < 6:                                                         # the camp: site cabins and tents
        cabin(s, 0, 3)
        if at(4):
            cabin(s, 0, 6.2, color=(206, 214, 222))
        tents = [(-7, 6, (60, 110, 60)), (-9, 0, (200, 120, 40)), (7.5, 9, (60, 90, 150)), (-6, 10.5, (180, 60, 50)),
                 (9.5, 3, (80, 130, 80))]
        for x_, y_, c_ in tents[:1 if lv < 2 else 3 if lv < 4 else 5]:
            tent(s, x_, y_, 2.6, 3.2, c_)
        pickup(s, 4.6, -5.5)
        s.ellipse(d, -4.2, -2.8, 0.9, 0.9, (90, 84, 80, 255), (120, 116, 110, 255), 0.25)  # fire pit
        s.ellipse(d, -4.2, -2.8, 0.45, 0.45, (40, 30, 26, 255))
        for k in range(3 + lv):
            a = k * 2.4
            person(s, -4.2 + 1.8 * math.cos(a) + rnd.uniform(-0.3, 0.3), -2.8 + 1.8 * math.sin(a))
        # surveyor's tripod
        s.line(d, [(3, 13), (3.6, 12.2)], (240, 200, 40, 255), 0.08)
        s.line(d, [(3.6, 12.2), (4.2, 13)], (240, 200, 40, 255), 0.08)
        s.line(d, [(3.6, 12.2), (3.6, 13.3)], (240, 200, 40, 255), 0.08)
        if at(2):
            pile(s, -15, 3, 3.4, 2.0, None, logs=True)
            pile(s, -15, -2.4, 3.0, 1.6, None, logs=True)
        if at(3):
            container(s, -23, -20.5, color=(170, 62, 48))
            container(s, -23, -23.5, color=(44, 92, 150))
            s.stand(2.3, rect_pts(6.5, 6.5, 1.2, 1.2), lambda d: (s.rect(d, 6.5, 6.5, 1.2, 1.2, (40, 120, 70, 255), (20, 70, 40, 255), 0.06),
                                                                  s.ellipse(d, 6.5, 6.5, 0.3, 0.3, (220, 220, 220, 255))), "toilet")
        if at(4):
            s.stand(1.8, rect_pts(8.5, -2, 2.6, 1.3), lambda d: (s.rect(d, 8.5, -2, 2.6, 1.3, (230, 120, 30, 255), (110, 60, 10, 255), 0.06),
                                                                 s.rect(d, 8.0, -2, 0.8, 0.8, (60, 60, 64, 255))), "generator")
            tank(s, 11.5, -2, 1.1, 1.6, (90, 120, 90), ladder=False)
        if at(5):
            pile(s, 15, 5, 3.0, 2.6, (172, 166, 150))
            excavator(s, 15, -5)
    elif lv < 16:                                                      # a first real office
        bw, bh = lerp(10, 14, lv, 6, 15), lerp(8, 10, lv, 6, 15)
        building(s, 0, 3, bw, bh, lerp(6, 9, lv, 6, 15), "flat", (188, 180, 168), units=2 + (lv - 6) // 3, label="office")
        if at(15):                                                     # its new wing
            building(s, -bw / 2 - 2.6, 5.5, 5.2, 5, 5.5, "flat", (182, 176, 166), units=1, label="wing")
            flagpole(s, 3, -6.4, (40, 90, 170))
        car(s, 5.5, -7.2, vertical=True)
        car(s, -5.5, -7.2, vertical=True)
    elif lv < 26:                                                      # the admin building
        bw, bh = lerp(15, 17, lv, 16, 25), lerp(11, 12.5, lv, 16, 25)
        building(s, 0, 3.4, bw, bh, lerp(10, 13, lv, 16, 25), "flat", (196, 194, 188), units=3 + (lv - 16) // 3,
                 skylights=at(20), label="admin")
        for k, c_ in enumerate([(40, 90, 170), (200, 40, 40), (240, 200, 40)][:1 + (lv >= 23) + (lv >= 25)]):
            flagpole(s, -2.4 + 2.4 * k, -9.1, c_)
    elif lv < 39:                                                      # a modern office around a glass atrium
        building(s, 0, 4.0, 19, 14, lerp(14, 18, lv, 26, 38), "flat", (214, 214, 210), units=4, solar=0.0, label="office")
        building(s, 0, 4.0, 6.5, 14, lerp(15, 19, lv, 26, 38), "glass", label="atrium")
        for k, c_ in enumerate([(40, 90, 170), (200, 40, 40), (240, 200, 40)]):
            flagpole(s, -2.4 + 2.4 * k, -9.1, c_)
    else:                                                              # the corporate headquarters
        hw = lerp(19, 20, lv, 39, 50)
        building(s, 0, 4.2, hw, 15, 26, "glass", (88, 132, 160), label="hq")
        building(s, 0, 4.2, hw * 0.55, 8, 30, "glass", (110, 156, 182), label="hq top")
        if at(45):                                                     # helipad on the top
            def helipad(d):
                s.ellipse(d, 0, 4.2, 3.2, 3.2, (62, 64, 70, 255), (236, 200, 60, 255), 0.25)
                for a, b in (((-0.9, -1.4), (-0.9, 1.4)), ((0.9, -1.4), (0.9, 1.4)), ((-0.9, 0), (0.9, 0))):
                    s.line(d, [(a[0], 4.2 + a[1]), (b[0], 4.2 + b[1])], (244, 244, 244, 255), 0.3)
            s.things.append((30.5, len(s.things), helipad))
        if at(50):                                                     # the crown
            def crown(d):
                for k in range(4):
                    s.rect(d, 0, 4.2, hw * 0.55 + 0.2 - k * 0.12, 8.2 - k * 0.12, None, (232, 196, 80, 255), 0.12)
            s.things.append((31, len(s.things), crown))
        for k, c_ in enumerate([(40, 90, 170), (200, 40, 40), (240, 200, 40)] + ([(40, 160, 90), (250, 250, 250)] if at(46) else [])):
            flagpole(s, -2.4 * (1 + at(46)) + 2.4 * k, -9.4, c_)
        if at(46):                                                     # a sculpture on the plaza
            s.stand(4, circle_pts(-6.5, -6.6, 0.7), lambda d: (s.ellipse(d, -6.5, -6.6, 0.9, 0.9, (120, 120, 124, 255)),
                                                               s.ellipse(d, -6.5, -6.6, 0.6, 0.6, (196, 120, 60, 255))), None)
    if at(44):                                                         # glass bridges to the side buildings
        s.things.append((9, len(s.things), lambda d: (s.rect(d, -15, 6, 10, 2.2, (150, 190, 210, 255), (70, 80, 90, 255), 0.08),
                                                      s.rect(d, 15, 6, 10, 2.2, (150, 190, 210, 255), (70, 80, 90, 255), 0.08))))

    # ── west block: warehouse and loading yard ──
    if 7 <= lv:
        if lv < 16:
            ww, wh = lerp(8, 11, lv, 7, 15), lerp(10, 16, lv, 7, 15)
            building(s, -16.5, 2 + (16 - wh) / 4, ww, wh, 6, "metal", (164, 168, 174), label="warehouse")
        elif lv < 31:
            building(s, -16.5, 1.8, 13, lerp(17, 19, lv, 16, 30), 9, "metal", (176, 180, 186), solar=0.6 if at(24) else 0,
                     label="warehouse")
        else:
            building(s, -16.5, 1.8, 13.5, 20, 12, "flat", (210, 212, 214), skylights=True, units=2,
                     solar=0.0 if at(47) else 0.45, green=at(47), label="high-bay")
    if at(12):                                                         # the loading yard: dock doors, a lorry
        for k in range(3 + (lv >= 26)):
            s.rect(d, -21 + k * 3.2, -8.0, 2.4, 0.5, (240, 200, 40, 255))
        truck(s, -16.5, -10.2 + 0.0, vertical=False, cab=(30, 90, 160), length=10 if lv < 20 else 12, north=True)
        forklift(s, -11.2, -6.4)
        pal = (172, 132, 84)
        for k in range(2 + (lv >= 25) * 2):
            s.stand(1.2, rect_pts(-22.5 + k * 1.4, -6.4, 1.2, 1.0),
                    lambda d, k=k: (s.rect(d, -22.5 + k * 1.4, -6.4, 1.2, 1.0, pal + (255,), (110, 80, 50, 255), 0.05),
                                    s.rect(d, -22.5 + k * 1.4, -6.4, 1.0, 0.8, (210, 196, 160, 255))), None)

    # ── east block: factories ──
    if at(10):
        n_halls = 1 + at(18) + at(27)
        fw = lerp(9, 13, lv, 10, 17) if n_halls == 1 else 13
        for k in range(n_halls):
            if n_halls == 1:
                fh, hy = lerp(9, 12, lv, 10, 17), 3.5
            elif n_halls == 2:
                fh, hy = 9.5, [6.0, -3.7][k]
            else:
                fh, hy = 22, 1.2                                      # one long joined hall
                if k > 0:
                    continue
            building(s, 16.5, hy, fw, fh, 8 + 2 * (lv >= 26), "sawtooth", (178, 172, 160) if lv < 36 else (170, 176, 182),
                     solar=0.45 if at(36) else 0, label="factory")
        if at(21):
            chimney(s, 23.0, 10.0, 0.9, 22)
            tank(s, 10.4, 10.2, 1.5, 14, (120, 160, 190))             # water tower
        if at(28):
            for k in range(2):
                tank(s, 31.4 - k * 0.4, 10.4 - k * 3.2, 1.35, 11, (214, 214, 210))
        if at(32):
            cooling_tower(s, 31.0, -8.8, 1.9)

    # ── north: workshops (west), courtyard (middle), logistics (east) ──
    if at(9):
        wsw = lerp(8, 10, lv, 9, 28)
        building(s, -15.5, 22.0, wsw, 6.2, 5, "metal", (150, 120, 96), label="workshop")
        if at(29):
            building(s, -25.0, 21.5, 6.5, 5.2, 5, "metal", (150, 120, 96), label="workshop 2")
        if lv < 26:
            car(s, -10.5, 20.5, vertical=True)
    if at(13):                                                         # the green courtyard
        cy0 = 28.0
        if at(23) and not at(41):                                       # crossing paths and benches
            s.rect(d, 0, cy0, 1.4, 18, (200, 192, 172, 255))
            s.rect(d, 0, cy0 - 1.0, 13, 1.4, (200, 192, 172, 255))
            for bx in (-3, 3):
                s.rect(d, bx, cy0 - 2.3, 1.6, 0.5, (120, 84, 50, 255))
        if at(41):                                                      # landscaped: curved paths
            for k in range(60):
                t = k / 59
                xx = 4.5 * math.sin(t * math.pi * 1.5)
                yy = 19.5 + t * 17
                s.ellipse(d, xx, yy, 0.8, 0.8, (206, 198, 178, 255))
            for bx, by in ((-3.6, 24), (3.8, 31)):
                s.rect(d, bx, by, 0.5, 1.6, (120, 84, 50, 255))
        if at(30):                                                      # a pond
            pr = 2.6 if lv < 48 else 3.4
            s.ellipse(d, -3.6, 32, pr + 0.4, pr * 0.7 + 0.4, (120, 110, 90, 255))
            s.ellipse(d, -3.6, 32, pr, pr * 0.7, (60, 116, 150, 255))
            s.ellipse(d, -4.3, 32.6, pr * 0.5, pr * 0.3, (100, 156, 186, 255))
        if at(48):                                                      # a stream to the plaza side
            s.line(d, [(-3.6, 29.5), (-2.4, 25), (-4, 21)], (60, 116, 150, 255), 0.9)
        spots = [(-5, 22), (5.5, 21.5), (-5.5, 27), (5.2, 27.5), (2.5, 35), (-1.5, 36.5), (6, 33), (-6.2, 35)]
        nt = 4 + min(4, (lv - 13) // 4)
        for x_, y_ in spots[:nt]:
            tree(s, x_, y_, 2.0 + (lv >= 26) * 0.6 + (lv >= 39) * 0.4)
    if at(14):
        if lv < 19:
            building(s, 18, 22.0, 10, 6, 6, "metal", (176, 160, 130), label="logistics shed")
        else:
            lw = 16 if lv < 34 else 19
            building(s, 10.2 + lw / 2, 21.9, lw, 6.4, 10, "metal" if lv < 38 else "flat", (190, 192, 196),
                     solar=0.7 if at(38) else 0, units=2 if lv >= 38 else 0, label="logistics")
            for k in range(int(lw / 3)):                               # dock doors on the south side
                s.rect(d, 11.8 + k * 3.0, 18.75, 2.2, 0.3, (240, 200, 40, 255))
            for k in range(1 + (lv >= 25) + (lv >= 34)):
                truck(s, [14.5, -4.0, -14.5][k], NORTH_Y + 1.4, vertical=False,
                      cab=[(200, 40, 36), (40, 120, 70), (240, 240, 240)][k], length=11, north=k != 2)

    # ── south: parking (both sides of the entrance), container yard (west), offices (east) ──
    if at(8):
        side_w = 8.0 if lv < 39 else 7.4
        for side in (-1, 1) if at(20) else (-1,):
            px0 = side * (spine_w / 2 + (2.2 if at(26) else 0.6) + side_w / 2)
            m, md = s.mask()
            s.rect(md, px0, -21.6, side_w, 10.0, 255)
            s.paint(tex if surf != "gravel" else s.texture((170, 162, 146), fine=22, mid=6, broad=5, speckle=0.12), m)
            bay = 2.5
            rows = [px0 - side_w / 2 + 2.3, px0 + side_w / 2 - 2.3]
            for k in range(5):
                by = -26.6 + k * bay
                if surf == "asphalt" or stage5:
                    for rx in rows:
                        s.line(d, [(rx - 2.3 if rx < px0 else rx + 2.3, by), (rx, by)], (236, 236, 228, 255), 0.1)
            filled = min(10, 2 + (lv - 8) // 2 + (lv >= 20) * 2)
            k = 0
            for c_ in range(2):
                for r_ in range(4):
                    if k >= filled:
                        break
                    cy_ = -26.6 + r_ * bay + bay / 2
                    if rnd.random() < 0.82 and all(inside(x, y, 0.2) for x, y in rect_pts(rows[c_], cy_, 4.4, 1.8)):
                        car(s, rows[c_], cy_, vertical=False)
                    k += 1
            if at(42):
                for rx in rows:
                    def canopy(d, rx=rx):
                        s.rect(d, rx, -21.25, 4.4, 8.7, (40, 56, 96, 255), (170, 176, 190, 255), 0.08)
                        yy = -25.6
                        while yy < -16.9:
                            s.line(d, [(rx - 2.2, yy), (rx + 2.2, yy)], (120, 132, 162, 255), 0.05)
                            yy += 1.05
                        s.line(d, [(rx, -25.6), (rx, -16.9)], (170, 176, 190, 255), 0.08)
                    s.stand(3.2, rect_pts(rx, -21.25, 4.4, 8.7), canopy, "canopy")
    if at(16):                                                          # the gatehouse and barrier
        gx = spine_w / 2 + 1.6
        building(s, gx + 0.4, -33.0, 2.6, 3.0, 3.2, "flat", (214, 210, 200), label="gatehouse")
        s.line(d, [(gx - 1.0, -34.6), (-0.4, -34.6)], (220, 40, 40, 255), 0.22)
        for k in range(5):
            s.line(d, [(gx - 1.0 - k * 1.2, -34.6), (gx - 1.6 - k * 1.2, -34.6)], (245, 245, 245, 255), 0.22)

    if at(3):                                                           # container yard (south-west)
        slots = [(-19.5, -18.6), (-19.5, -21.3), (-26.0, -18.6), (-26.0, -21.3), (-19.5, -24.0), (-26.0, -24.0)]
        n = 0 if lv < 6 else min(len(slots), 2 + (lv >= 11) * 2 + (lv >= 22) * 2)
        for i, (x_, y_) in enumerate(slots[:n]):
            two = (lv >= 22 and i % 2 == 0) or (lv >= 37 and i % 2 == 1)
            container(s, x_, y_, high=2 if two else 1,
                      color=CONTAINER_COLOURS[(i * 5 + 1) % len(CONTAINER_COLOURS)])
            if two:                                # a second one stacked on top
                container(s, x_ + 0.15, y_ - 0.15, color=CONTAINER_COLOURS[(i * 5 + 3) % len(CONTAINER_COLOURS)], high=2)
        if at(11):
            forklift(s, -15.2, -21.9)
        if at(22):                                                      # a gantry crane over the stacks
            def gantry(d):
                for gy in (-17.2, -24.8):
                    s.rect(d, -22.4, gy, 15.9, 0.8, (232, 180, 30, 255), (120, 90, 10, 255), 0.06)
                for gx in (-29.9, -14.9):
                    s.rect(d, gx, -21.0, 0.9, 8.4, (232, 180, 30, 255), (120, 90, 10, 255), 0.06)
                s.rect(d, -22.75, -22.6, 15.0, 1.6, (90, 92, 96, 255))
                s.rect(d, -21.0, -22.6, 2.0, 1.6, (232, 180, 30, 255), (120, 90, 10, 255), 0.06)
            s.stand(9, rect_pts(-22.4, -21.0, 15.9, 8.4), gantry, "gantry")

    if at(23):                                                          # offices with their own parking (south-east)
        if lv < 43:
            ow = lerp(10, 13, lv, 23, 42)
            building(s, 17.0 + ow / 2, -21.6, ow, 7.0, 9, "flat", (196, 186, 170), units=2, green=at(40),
                     label="offices")
        else:
            building(s, 23.6, -21.2, 13.5, 7.4, 14, "glass", (96, 140, 166), label="offices")
            building(s, 23.6, -21.2, 8, 3.8, 16, "flat", (210, 210, 206), green=True, label="offices roof")

    # ── street life and trees ──
    if at(25):
        for x_, y_ in ((-RING_X - 3.7, -4), (RING_X + 3.7 - 7.4, -4), (-12, CROSS_Y - 3.6), (12, CROSS_Y - 3.6),
                       (-12, NORTH_Y + 3.6), (12, NORTH_Y + 3.6), (spine_w / 2 + 1.0, -28), (-spine_w / 2 - 1.0, -20)):
            lamp(s, x_, y_)
    if at(35):                                                          # street trees
        for x_ in (-20, -8, 8, 20):
            tree(s, x_, CROSS_Y + road_w / 2 + 1.4, 1.5, (60, 112, 52))
    if stage5:                                                          # trees down the boulevard's median
        y_ = -36.0
        while y_ < -14:
            tree(s, 0, y_, 1.2, (66, 120, 54))
            y_ += 3.6
    for _ in range(int(lerp(0, 12, lv, 6, 50))):                        # people about
        x_, y_ = rnd.uniform(-9, 9), rnd.uniform(-11, -3)
        if lv >= 6:
            person(s, x_, y_)
    for _ in range(int(lerp(0, 5, lv, 16, 50))):                        # cars on the main street
        car(s, rnd.uniform(-34, 34), CROSS_Y + rnd.choice([-1.4, 1.4]), vertical=False)
    # trees around the edge where nothing is built
    edge_trees = [(-33, 8), (-34.5, -7), (33.5, 9), (33, -10), (-12, 34), (12, 34), (-28, 24), (27, -24.5)]
    for x_, y_ in edge_trees[:int(lerp(2, 8, lv, 1, 30))]:
        tree(s, x_, y_, 2.2 if lv < 39 else 2.6, (50, 100, 44))

    return s.finish(), s.warnings


def main(argv) -> int:
    out = ROOT / "app" / "assets" / "game" / "campus"
    out.mkdir(parents=True, exist_ok=True)
    only = [int(a) for a in argv[1:] if a.isdigit()]
    levels = only or list(range(1, g.CAMPUS_MAX + 1))
    pics = {}
    for lv in levels:
        im, warn = draw_level(lv)
        pics[lv] = im
        if warn:
            print(f"level {lv}: outside the property: {sorted(set(warn))}")
        im.save(out / f"campus_{lv:02d}.png", optimize=True)
    try:
        font = ImageFont.truetype("arial.ttf", 13)
    except OSError:
        font = ImageFont.load_default()
    if "--sheet" in argv:
        cw = 150
        ch = round(cw * H / W)
        cols = 10
        rows = math.ceil(len(pics) / cols)
        sheet = Image.new("RGB", (cw * cols, (ch + 18) * rows), (28, 30, 36))
        sd = ImageDraw.Draw(sheet)
        for i, (lv, im) in enumerate(sorted(pics.items())):
            t = im.resize((cw, ch), Image.LANCZOS)
            x, y = (i % cols) * cw, (i // cols) * (ch + 18)
            sheet.paste(t, (x, y + 18), t)
            sd.text((x + 4, y + 2), f"{lv} {g.campus_stage(lv)}", fill=(220, 220, 220), font=font)
        sheet.save(argv[argv.index("--sheet") + 1])
    if "--big" in argv:
        big = [lv for lv in (1, 5, 6, 15, 16, 25, 26, 38, 39, 50) if lv in pics]
        cw = 420
        ch = round(cw * H / W)
        sheet = Image.new("RGB", (cw * 5, (ch + 20) * math.ceil(len(big) / 5)), (28, 30, 36))
        sd = ImageDraw.Draw(sheet)
        for i, lv in enumerate(big):
            t = pics[lv].resize((cw, ch), Image.LANCZOS)
            x, y = (i % 5) * cw, (i // 5) * (ch + 20)
            sheet.paste(t, (x, y + 20), t)
            sd.text((x + 4, y + 3), f"Level {lv}: {g.campus_stage(lv)}", fill=(230, 230, 230), font=font)
        sheet.save(argv[argv.index("--big") + 1])
    print(f"{len(pics)} Campus pictures -> {out} ({W}x{H} px, {PX_PER_M} px/m)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
