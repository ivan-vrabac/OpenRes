#!/usr/bin/env python3
"""server/data/land.wkb.gz and lakes.wkb.gz from Natural Earth (public domain, naturalearthdata.com):
the 1:10m land and lakes, simplified to ~50 m. world.py uses them so nothing is built on water.

    python tools/make_water.py <ne_10m_land.geojson> <ne_10m_lakes.geojson>
"""
import gzip
import json
import sys
from pathlib import Path

import shapely
from shapely.geometry import shape

OUT = Path(__file__).resolve().parent.parent / "server" / "data"


def load(path):
    feats = json.load(open(path, encoding="utf-8"))["features"]
    geoms = [shape(f["geometry"]).buffer(0) for f in feats]
    return shapely.union_all(shapely.simplify(geoms, 0.0005, preserve_topology=True))


def main(land_path, lakes_path):
    OUT.mkdir(parents=True, exist_ok=True)
    for name, path in (("land", land_path), ("lakes", lakes_path)):
        g = load(path)
        data = gzip.compress(shapely.to_wkb(g), 9)
        (OUT / f"{name}.wkb.gz").write_bytes(data)
        print(name, f"{len(data) / 1e6:.1f} MB")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
