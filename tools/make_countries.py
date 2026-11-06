#!/usr/bin/env python3
"""server/data/countries.wkb.gz from Natural Earth (public domain, naturalearthdata.com): the 1:10m
countries, simplified to ~100 m, one geometry per two-letter country code. countries.py uses it to
give a Campus the country it stands in (owner 2026-11-06).

    python tools/make_countries.py <ne_10m_admin_0_countries.geojson>

The file is gzipped: per country 2 bytes of code, 4 bytes of length (little endian), then its WKB.
"""
import gzip
import json
import struct
import sys
from collections import defaultdict
from pathlib import Path

import shapely
from shapely.geometry import shape

OUT = Path(__file__).resolve().parent.parent / "server" / "data" / "countries.wkb.gz"

# Natural Earth areas without an ISO code that clearly belong to one; the rest (disputed reefs,
# glaciers, Bir Tawil) are left out and take the nearest country.
EXTRA = {"Dhekelia": "gb", "Akrotiri": "gb", "Somaliland": "so", "N. Cyprus": "cy",
         "Cyprus U.N. Buffer Zone": "cy", "USNB Guantanamo Bay": "cu"}


def main(path):
    parts = defaultdict(list)
    for f in json.load(open(path, encoding="utf-8"))["features"]:
        p = f["properties"]
        cc = str(p.get("ISO_A2_EH") or "").lower()
        if len(cc) != 2 or not cc.isalpha():
            cc = EXTRA.get(p.get("NAME"), "")
        if cc:
            parts[cc].append(shape(f["geometry"]).buffer(0))
    out = b""
    for cc, geoms in sorted(parts.items()):
        wkb = shapely.to_wkb(shapely.simplify(shapely.union_all(geoms), 0.001, preserve_topology=True))
        out += cc.encode() + struct.pack("<I", len(wkb)) + wkb
    data = gzip.compress(out, 9)
    OUT.write_bytes(data)
    print(len(parts), "countries", f"{len(data) / 1e6:.1f} MB")


if __name__ == "__main__":
    main(sys.argv[1])
