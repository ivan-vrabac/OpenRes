#!/usr/bin/env python3
"""server/data/countries.wkb.gz: country borders from OpenStreetMap (owner 2026-11-06), for countries.py.

Source: geo-maps "countries-coastline-10m" (simonepri/geo-maps v0.6.0): OpenStreetMap country borders
clipped at the coastline, 10 m resolution. Data (c) OpenStreetMap contributors, ODbL 1.0
(https://www.openstreetmap.org/copyright); so is the file made here.

    python tools/make_countries.py <countries-coastline-10m.geo.json>

Two fixes on top: Antarctica reaches the South Pole (the source, like web maps, stops at 85.05 S), and
Crimea is Ukraine as the UN recognises it (the source has it in both Ukraine and Russia: Russia's piece
there, the only one inside CRIMEA_BOX, is dropped). And territories with their own flag that the source also
draws inside the country governing them (Svalbard in Norway, French Guiana in France, Puerto Rico in the US,
Taiwan in China, Aaland in Finland, ...) keep only their own piece: two pieces of about the same size made the
answer depend on rounding, so it differed between machines (2026-11-07).

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


def drop_duplicates(geoms: dict) -> dict:
    """Where a piece of one country lies on a piece of about the same size of another, the country with the
    bigger total area (the one governing a territory) gives its piece up."""
    parts = {cc: list(shapely.get_parts(g)) for cc, g in geoms.items()}
    total = {cc: sum(p.area for p in ps) for cc, ps in parts.items()}
    flat = [(cc, i, p) for cc, ps in parts.items() for i, p in enumerate(ps)]
    tree = shapely.STRtree([p for _, _, p in flat])
    drop = set()
    for cc, i, p in flat:
        if p.area < 1e-7:
            continue
        inside = shapely.point_on_surface(p)
        for k in tree.query(inside, predicate="intersects"):
            oc, oi, op = flat[k]
            if oc != cc and 0.5 < p.area / op.area < 2:
                # same place twice: the bigger country (overall) drops its piece
                drop.add((cc, i) if total[cc] > total[oc] else (oc, oi))
    for cc in parts:
        kept = [p for i, p in enumerate(parts[cc]) if (cc, i) not in drop]
        geoms[cc] = shapely.multipolygons(kept)
    print("duplicates dropped:", len(drop))
    return geoms


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
    geoms = drop_duplicates(geoms)
    out = b""
    for cc, g in sorted(geoms.items()):
        wkb = shapely.to_wkb(g)
        out += cc.encode() + struct.pack("<I", len(wkb)) + wkb
    data = gzip.compress(out, 9)
    OUT.write_bytes(data)
    print(len(parts), "countries", f"{len(data) / 1e6:.1f} MB")


if __name__ == "__main__":
    main(sys.argv[1])
