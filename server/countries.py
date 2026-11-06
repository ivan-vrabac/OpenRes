"""Which country a point on the map is in (owner 2026-11-06): a company's flag and country board come from
where its Campus stands, not from the IP address (that only counts until a Campus is built).

- on land: the country it is in (Natural Earth 1:10m, ~100 m; Antarctica is "aq")
- at sea within SEA_KM of a coast (about a country's sea zone): the nearest country
- further out: INTERNATIONAL ("zz"), international waters, no country on the country board

Data: data/countries.wkb.gz (tools/make_countries.py). Loaded on first use.
"""
from __future__ import annotations

import gzip
import math
import struct
import threading
from pathlib import Path

import shapely
from shapely import STRtree
from shapely.ops import nearest_points

INTERNATIONAL = "zz"
SEA_KM = 370                    # 200 nautical miles

_DATA = Path(__file__).resolve().parent / "data" / "countries.wkb.gz"
_lock = threading.Lock()
_codes: list[str] = []
_geoms: list = []
_tree: STRtree | None = None


def _load():
    global _tree
    with _lock:
        if _tree is not None:
            return
        raw = gzip.decompress(_DATA.read_bytes())
        i = 0
        while i < len(raw):
            cc = raw[i:i + 2].decode()
            (n,) = struct.unpack_from("<I", raw, i + 2)
            geom = shapely.from_wkb(raw[i + 6:i + 6 + n])
            shapely.prepare(geom)
            _codes.append(cc)
            _geoms.append(geom)
            i += 6 + n
        _tree = STRtree(_geoms)


def _km(lat1, lng1, lat2, lng2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lng2 - lng1) / 2) ** 2
    return 2 * 6371.0 * math.asin(min(1.0, math.sqrt(a)))


def country_at(lat: float, lng: float) -> str:
    """The two-letter country code (lower case) of a point, or INTERNATIONAL out at sea."""
    _load()
    pt = shapely.Point(lng, lat)
    for i in _tree.query(pt, predicate="intersects"):
        return _codes[i]
    # at sea: the nearest coast within SEA_KM (searched in a box, then measured on the globe)
    dlat = SEA_KM / 111.32
    dlng = 180.0 if abs(lat) + dlat >= 89 else min(180.0, dlat / math.cos(math.radians(abs(lat) + dlat)))
    box = shapely.box(lng - dlng, max(-90.0, lat - dlat), lng + dlng, min(90.0, lat + dlat))
    best, best_km = INTERNATIONAL, SEA_KM
    for i in _tree.query(box):
        near = nearest_points(_geoms[i], pt)[0]
        km = _km(lat, lng, near.y, near.x)
        if km <= best_km:
            best, best_km = _codes[i], km
    return best
