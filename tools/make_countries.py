#!/usr/bin/env python3
"""server/data/countries.wkb.gz: country borders from OpenStreetMap (owner 2026-11-06), for countries.py.

Source: geo-maps "countries-coastline-10m" (simonepri/geo-maps v0.6.0): OpenStreetMap country borders
clipped at the coastline, 10 m resolution. Data (c) OpenStreetMap contributors, ODbL 1.0
(https://www.openstreetmap.org/copyright); so is the file made here.

    python tools/make_countries.py <countries-coastline-10m.geo.json>

Two fixes on top: Antarctica reaches the South Pole (the source, like web maps, stops at 85.05 S), and
Crimea is Ukraine as the UN recognises it (the source has it in both Ukraine and Russia: Russia's piece
there, the only one inside CRIMEA_BOX, is dropped).

Codes: the source has ISO 3166 alpha-3 codes, tools/iso3_to_iso2.json turns them into the two-letter codes
of the flag pictures. The file is gzipped: per country 2 bytes of code, 4 bytes of length (little endian),
then its WKB.
"""
import gzip
import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

import shapely
from shapely.geometry import shape

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "server" / "data" / "countries.wkb.gz"


CRIMEA_BOX = (32.3, 44.2, 36.8, 46.3)          # west, south, east, north: the peninsula and Sevastopol


def main(path):
    a3to2 = json.load(open(HERE / "iso3_to_iso2.json", encoding="utf-8"))
    parts = defaultdict(list)
    for f in json.load(open(path, encoding="utf-8"))["features"]:
        parts[a3to2[f["properties"]["A3"]]].append(shape(f["geometry"]))
    geoms = {cc: shapely.make_valid(shapely.union_all(g)) if len(g) > 1 else g[0] for cc, g in parts.items()}
    geoms["aq"] = shapely.union(geoms["aq"], shapely.box(-180, -90, 180, -85.0))
    # the source has Crimea twice, in Ukraine and in Russia: drop Russia's pieces there
    box = shapely.box(*CRIMEA_BOX)
    ru = shapely.get_parts(geoms["ru"])
    drop = [i for i, g in enumerate(ru) if box.contains(g)]
    print("Crimea: dropped", len(drop), "Russian pieces,", round(sum(ru[i].area for i in drop) * 111 * 111 * 0.72), "km2;",
          "Ukraine covers Simferopol:", geoms["ua"].contains(shapely.Point(34.1, 44.95)))
    geoms["ru"] = shapely.multipolygons([g for i, g in enumerate(ru) if i not in set(drop)])
    out = b""
    for cc, g in sorted(geoms.items()):
        wkb = shapely.to_wkb(g)
        out += cc.encode() + struct.pack("<I", len(wkb)) + wkb
    data = gzip.compress(out, 9)
    OUT.write_bytes(data)
    print(len(parts), "countries", f"{len(data) / 1e6:.1f} MB")


if __name__ == "__main__":
    main(sys.argv[1])
