#!/usr/bin/env python3
"""CC0 art for the pictures that drawing didn't do well (owner 2026-10-25):

- headquarters (hq_thumb_1..10, hq_thumb_10_1..6): isometric renders of Kenney's "City Kit
  (Commercial)" models (CC0, https://kenney.nl/assets/city-kit-commercial), see render_kenney.py;
  the six level-10 luxury stages get gold bands and a gold top;
  big map versions (assets/images/hq_map/) so a headquarters is sharp when the map is zoomed in;
- diamond button and launcher icons: rubberduck's photographed gems from the "RPG icon base
  pack" (CC0, https://opengameart.org/content/rpg-icon-base-pack).

  python tools/import_art.py <kenney city kit folder> <rpg icon base pack folder>

Writes straight into app/. Needs Pillow, numpy, trimesh.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_kenney                           # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "app"
KENNEY = "Kenney, City Kit (Commercial), CC0 - https://kenney.nl/assets/city-kit-commercial (rendered)"
GEMS = "rubberduck, RPG icon base pack, CC0 - https://opengameart.org/content/rpg-icon-base-pack"
DENSITIES = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
LAUNCHER = {"default": ("ic_launcher", (30, 42, 68), "diamond_01.png")}


def fit(src: Image.Image, size: int, fill: float = 0.86) -> Image.Image:
    """The picture trimmed to its visible part, centred on a transparent square."""
    src = src.crop(src.getbbox())
    s = fill * size / max(src.size)
    src = src.resize((max(1, round(src.width * s)), max(1, round(src.height * s))), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.alpha_composite(src, ((size - src.width) // 2, (size - src.height) // 2))
    return out


def tile(gem: Image.Image, bg, px: int, circle=False) -> Image.Image:
    """Legacy launcher icon: the gem on a coloured rounded square (or circle) with a soft light."""
    big = 512
    im = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    box = (8, 8, big - 8, big - 8) if circle else (16, 16, big - 16, big - 16)
    (d.ellipse if circle else lambda b, **k: d.rounded_rectangle(b, radius=100, **k))(box, fill=bg + (255,))
    glow = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse((96, 96, big - 96, big - 96), fill=(255, 255, 255, 40))
    im.alpha_composite(glow)
    im.alpha_composite(fit(gem, 360, 0.95), (76, 76))
    if circle:
        mask = Image.new("L", (big, big), 0)
        ImageDraw.Draw(mask).ellipse(box, fill=255)
        im.putalpha(Image.composite(im.getchannel("A"), Image.new("L", (big, big), 0), mask))
    return im.resize((px, px), Image.LANCZOS)


def main(kit: str, gems: str) -> int:
    out: dict[str, tuple[Image.Image, str]] = {}
    for sc, pre in ((1, ""), (2, "2x/"), (3, "3x/")):
        for name, im in render_kenney.all_levels(kit, (100 * sc, 125 * sc)).items():
            out[f"assets/images/{pre}{name}.png"] = (im, KENNEY)
    for name, im in render_kenney.all_levels(kit, (500, 625)).items():   # map: up to ~600 px on screen
        out[f"assets/images/hq_map/{name}.png"] = (im, KENNEY)
        diamond = Image.open(os.path.join(gems, "original", "diamond_01.png")).convert("RGBA")
        out[f"assets/images/{pre}diamondbutton.png"] = (fit(diamond, 64 * sc), GEMS)
    for variant, (name, bg, file) in LAUNCHER.items():
        gem = Image.open(os.path.join(gems, "original", file)).convert("RGBA")
        src = GEMS
        for dens, px in DENSITIES.items():
            out[f"android/app/src/main/res/mipmap-{dens}/{name}.png"] = (tile(gem, bg, px), src)
            if variant == "default":
                out[f"android/app/src/main/res/mipmap-{dens}/ic_launcher_round.png"] = (tile(gem, bg, px, circle=True), src)
                fg = Image.new("RGBA", (432, 432), (0, 0, 0, 0))   # adaptive: gem inside the 66 dp safe zone
                fg.alpha_composite(fit(gem, 250, 0.95), (91, 91))
                out[f"android/app/src/main/res/mipmap-{dens}/ic_launcher_foreground.png"] = (
                    fg.resize((round(px * 2.25),) * 2, Image.LANCZOS), src)

    for rel, (im, _source) in out.items():
        dst = APP / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        im.save(dst, optimize=True)
    print(f"{len(out)} files written to app/")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
