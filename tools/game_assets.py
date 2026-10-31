#!/usr/bin/env python3
"""Builds app/assets/game/: every picture OpenRes 0.3 needs, plus INVENTORY.csv listing them.

The list comes from server/gamedata.py and server/world.py, so a new item or plant shows up here by
itself. Pictures without real art yet get a placeholder tile (category colour + name); headquarters
levels are drawn by tools/draw_hq.py (run it after this tool). Licensed photos are not
part of the repository: release builds overlay them from a private folder (see --photos).

    python tools/game_assets.py [--kenney <City Kit folder>] [--photos <private folder>] [--force]

--kenney     render the 50 HQ pictures (needs numpy, trimesh, Pillow)
--photos     a private folder: <folder>/items/<key>.png photos are listed as "photo (release builds)"
--force      redraw placeholders that already exist
"""
from __future__ import annotations

import argparse
import csv
import os
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "server"))
sys.path.insert(0, str(ROOT / "tools"))
import gamedata as g  # noqa: E402

OUT = ROOT / "app" / "assets" / "game"
SIZE = 256
FONT_FILES = ["C:/Windows/Fonts/segoeuib.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]

# category -> tile colour
COLORS = {
    "mineral": (120, 92, 70), "forest": (46, 110, 58), "crop": (176, 150, 50), "ranch": (150, 96, 70),
    "fish": (40, 110, 150), "energy": (200, 160, 30), "material": (95, 105, 120), "food": (170, 80, 60),
    "wood": (120, 84, 50), "electronics": (80, 70, 150), "top": (150, 120, 40), "operation": (60, 80, 100),
    "plant": (70, 90, 110), "land": (70, 100, 70), "ui": (55, 65, 85),
}
UI_ICONS = {
    "survey": "Survey", "supervisor": "Supervisor", "education": "Education", "storage": "Central Storage",
    "luxury": "Tantalum-180m", "darkmatter": "Dark matter", "lease": "Lease", "renew": "Renew lease",
    "cancel": "Cancel lease", "credits": "Credits", "xp": "XP", "electricity": "Electricity",
    "efficiency": "Efficiency", "hide_hexes": "Hide hexes", "build": "Build", "streak": "Login streak",
}


def item_category(item: str) -> str:
    raw = g.raw_items()
    if item in raw:
        op = raw[item][0]
        return {"mine": "mineral", "oil_well": "mineral", "logging_camp": "forest", "farm": "crop",
                "ranch": "ranch", "fish_farm": "fish", "fishing_port": "fish"}.get(op, "mineral")
    if item == g.ENERGY or item == "fuel_rods":
        return "energy"
    if item in ("lumber", "wood_pellets", "paper", "books", "furniture"):
        return "wood"
    if item in ("silicon", "wafers", "microchips", "batteries", "phones", "laptops", "computers", "servers",
                "supercomputers", "medical_devices"):
        return "electronics"
    if item in ("tantalum", "ta180m"):
        return "top"
    if item in ("flour", "sugar", "dairy_products", "meat_products", "fish_products", "grocery_packs", "juice",
                "meals", "fabric", "clothing", "sweets"):
        return "food"
    return "material"


def inventory() -> list[dict]:
    rows = []
    for item, name in g.ITEM_NAMES.items():
        rows.append({"category": "item", "key": item, "name": name, "file": f"items/{item}.png",
                     "colour": item_category(item)})
    for op, (name, *_rest) in g.OPERATIONS.items():
        rows.append({"category": "operation", "key": op, "name": name, "file": f"operations/{op}.png", "colour": "operation"})
    for key, (name, *_rest) in g.FACTORIES.items():
        rows.append({"category": "plant", "key": key, "name": name, "file": f"plants/{key}.png", "colour": "plant"})
    for land, name in [("mineral", "Mineral deposit"), ("forest", "Forest"), ("farmland", "Farmland"),
                       ("pasture", "Pasture"), ("water", "Water")]:
        rows.append({"category": "land", "key": land, "name": name, "file": f"land/{land}.png", "colour": "land"})
    for lv in range(1, g.HQ_MAX + 1):
        b, story = g.hq_building(lv)
        rows.append({"category": "hq", "key": f"hq_{lv:02d}", "name": f"{b}, story {story} (level {lv})",
                     "file": f"hq/hq_{lv:02d}.png", "colour": "plant"})
    for key, name in UI_ICONS.items():
        rows.append({"category": "ui", "key": key, "name": name, "file": f"ui/{key}.png", "colour": "ui"})
    return rows


def font(size: int):
    for f in FONT_FILES:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def placeholder(name: str, colour: str) -> Image.Image:
    """A rounded tile in the category colour with the name, centred and wrapped."""
    ss = 2
    s = SIZE * ss
    im = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    base = COLORS[colour]
    d.rounded_rectangle((8, 8, s - 8, s - 8), radius=48, fill=base + (255,))
    d.rounded_rectangle((8, 8, s - 8, s // 2), radius=48, fill=tuple(min(255, c + 25) for c in base) + (255,))
    d.rectangle((8, s // 2 - 48, s - 8, s // 2), fill=tuple(min(255, c + 25) for c in base) + (255,))
    words, lines = name.split(), []
    fsize = 64
    while True:
        f = font(fsize)
        lines, cur = [], ""
        for w in words:
            t = (cur + " " + w).strip()
            if d.textlength(t, font=f) <= s - 80:
                cur = t
            else:
                lines.append(cur)
                cur = w
        lines.append(cur)
        if len(lines) <= 3 and all(d.textlength(x, font=f) <= s - 80 for x in lines) or fsize <= 30:
            break
        fsize -= 4
    lh = fsize * 1.15
    y = s / 2 - lh * len(lines) / 2
    for line in lines:
        d.text((s / 2, y + lh / 2), line, font=f, fill=(255, 255, 255, 255), anchor="mm")
        y += lh
    return im.resize((SIZE, SIZE), Image.LANCZOS)


def render_hq(kenney: str) -> dict[str, Image.Image]:
    """50 levels: the 10 renderer models (one per building type), each 5 stories taller."""
    import render_kenney as rk
    models = os.path.join(kenney, "Models", "GLB format")
    out = {}
    tallest = max(rk.model_height(models, m) for m in rk.LEVELS.values()) * 1.5
    for lv in range(1, g.HQ_MAX + 1):
        btype, story = (lv - 1) // 5 + 1, (lv - 1) % 5 + 1
        stretch = 1.0 + 0.125 * (story - 1)                      # 5 stories: 1.0 ... 1.5 times as tall
        luxury = story - 2 if btype == 10 and story >= 3 else 0   # gold trim on the top 3 levels
        # frame: the whole ladder grows steadily from level 1 to 50
        fill = 0.40 + (lv - 1) * (0.54 / (g.HQ_MAX - 1))
        h = rk.model_height(models, rk.LEVELS[btype]) * stretch
        out[f"hq_{lv:02d}"] = rk.render(os.path.join(models, rk.LEVELS[btype] + ".glb"), (500, 625),
                                        h / fill, luxury=luxury, stretch=stretch)
    _ = tallest
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kenney")
    ap.add_argument("--photos")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    rows = inventory()
    hq = render_hq(a.kenney) if a.kenney else {}
    made = 0
    for r in rows:
        path = OUT / r["file"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if r["key"] in hq:
            hq[r["key"]].save(path, optimize=True)
            made += 1
        elif not path.exists() or a.force:
            if r["category"] == "hq" and path.exists():
                continue
            placeholder(r["name"], r["colour"]).save(path, optimize=True)
            made += 1
        if r["category"] == "hq":
            r["status"], r["source"], r["license"] = "drawn", "tools/draw_hq.py", "CC BY-NC 4.0"
        elif a.photos and (Path(a.photos) / r["file"]).exists():
            r["status"], r["source"], r["license"] = "photo (release builds)", "see private credits", "see credits"
        else:
            r["status"], r["source"], r["license"] = "placeholder", "drawn by tools/game_assets.py", "CC BY-NC 4.0"
    with (OUT / "INVENTORY.csv").open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["category", "key", "name", "file", "status", "source", "license"],
                           extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    counts: dict[str, int] = {}
    for r in rows:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print(f"{len(rows)} pictures ({made} written): " + ", ".join(f"{k} {v}" for k, v in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
