"""Which country a point on the map is in (owner 2026-11-06): a company's flag and country board come from
where its Campus stands, not from the IP address (that only counts until a Campus is built).

- on land: the country it is in (OpenStreetMap borders, 10 m; Antarctica is "aq"). Every island and enclave
  is its own piece and the smallest piece holding the point wins, so the Vatican, San Marino, Llivia,
  Busingen, Campione and Baarle come out right even where a bigger neighbour's outline covers them.
- at sea within SEA_KM of a coast (about a country's sea zone): the nearest country
- further out: INTERNATIONAL ("zz"), international waters, no country on the country board

Data: data/countries.wkb.gz (tools/make_countries.py), (c) OpenStreetMap contributors, ODbL. Loaded on first use.
"""
from __future__ import annotations

import gzip
import math
import struct
import threading
from pathlib import Path

import numpy as np
import shapely
from shapely import STRtree

INTERNATIONAL = "zz"
SEA_KM = 370                    # 200 nautical miles

_DATA = Path(__file__).resolve().parent / "data" / "countries.wkb.gz"
_lock = threading.Lock()
_codes: np.ndarray | None = None
_pieces: np.ndarray | None = None
_areas: np.ndarray | None = None
_tree: STRtree | None = None


def _load():
    global _codes, _pieces, _areas, _tree
    with _lock:
        if _tree is not None:
            return
        raw = gzip.decompress(_DATA.read_bytes())
        codes, pieces, i = [], [], 0
        while i < len(raw):
            cc = raw[i:i + 2].decode()
            (n,) = struct.unpack_from("<I", raw, i + 2)
            geom = shapely.from_wkb(raw[i + 6:i + 6 + n])
            for part in shapely.get_parts(geom):
                codes.append(cc)
                pieces.append(part)
            i += 6 + n
        _pieces = np.array(pieces, dtype=object)
        _codes = np.array(codes)
        _areas = shapely.area(_pieces)
        shapely.prepare(_pieces)
        _tree = STRtree(_pieces)


def _km(lat1, lng1, lat2, lng2):
    p1, p2 = np.radians(lat1), np.radians(lat2)
    a = np.sin((p2 - p1) / 2) ** 2 + np.cos(p1) * np.cos(p2) * np.sin(np.radians(lng2 - lng1) / 2) ** 2
    return 2 * 6371.0 * np.arcsin(np.minimum(1.0, np.sqrt(a)))


def country_at(lat: float, lng: float) -> str:
    """The two-letter country code (lower case) of a point, or INTERNATIONAL out at sea."""
    _load()
    pt = shapely.Point(lng, lat)
    hits = _tree.query(pt, predicate="intersects")
    if len(hits):
        return str(_codes[hits[np.argmin(_areas[hits])]])
    # at sea: the nearest coast within SEA_KM (pieces in a box around the point, then measured on the globe)
    dlat = SEA_KM / 111.32
    dlng = 180.0 if abs(lat) + dlat >= 89 else min(180.0, dlat / math.cos(math.radians(abs(lat) + dlat)))
    near = _tree.query(shapely.box(lng - dlng, max(-90.0, lat - dlat), lng + dlng, min(90.0, lat + dlat)))
    if not len(near):
        return INTERNATIONAL
    ends = shapely.get_coordinates(shapely.shortest_line(_pieces[near], pt))[0::2]     # the coast end of each line
    km = _km(lat, lng, ends[:, 1], ends[:, 0])
    best = int(np.argmin(km))
    return str(_codes[near[best]]) if km[best] <= SEA_KM else INTERNATIONAL
