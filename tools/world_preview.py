#!/usr/bin/env python3
"""Pictures of the OpenRes 0.3 world map (server/world.py) around a point: the land types and a few
resource heatmaps side by side. Needs numpy and Pillow.

    python tools/world_preview.py <lat> <lng> <radius_m> <out.png> [item ...]
"""
from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server"))
import world as w  # noqa: E402

LAND_COLORS = {1: (150, 120, 100), 2: (40, 110, 50), 3: (215, 190, 90), 4: (130, 190, 90)}
N = 256


def heat(v: np.ndarray) -> np.ndarray:
    """0-100 -> colours: dark where there is none, then blue -> green -> yellow -> red."""
    stops = np.array([[40, 70, 200], [40, 180, 90], [240, 220, 40], [230, 60, 30]], np.float64)
    t = np.clip(v / 100.0, 0, 1) * (len(stops) - 1)
    i = np.minimum(t.astype(int), len(stops) - 2)
    f = (t - i)[..., None]
    rgb = stops[i] * (1 - f) + stops[i + 1] * f
    rgb[v == 0] = (30, 32, 38)
    return rgb.astype(np.uint8)


def main(lat: float, lng: float, radius: float, out: str, items: list[str]) -> None:
    box = w.around(lat, lng, radius)
    panels = [("land", None)] + [(it, None) for it in items]
    img = Image.new("RGB", (N * len(panels), N + 22), (16, 18, 22))
    d = ImageDraw.Draw(img)
    for k, (what, _) in enumerate(panels):
        v = w.grid(what, *box, N)
        if what == "land":
            rgb = np.zeros((N, N, 3), np.uint8)
            for code, col in LAND_COLORS.items():
                rgb[v == code] = col
            label = "land: mineral/forest/farm/pasture"
        else:
            rgb = heat(v.astype(np.float64))
            label = f"{what}: {float((v > 0).mean()) * 100:.1f}% area, max {int(v.max())}"
        img.paste(Image.fromarray(rgb), (k * N, 22))
        d.text((k * N + 4, 5), label, fill=(230, 230, 230))
    d.ellipse((N // 2 - 3, 22 + N // 2 - 3, N // 2 + 3, 22 + N // 2 + 3), outline=(255, 255, 255))
    img.save(out)
    print(out)


if __name__ == "__main__":
    a = sys.argv
    main(float(a[1]), float(a[2]), float(a[3]), a[4], a[5:] or ["wood", "iron_ore", "coltan"])
