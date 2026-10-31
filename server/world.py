"""OpenRes 0.3 world map: land types and resource qualities for any point on Earth.

Everything is computed from smooth noise sampled on the globe itself (a point's position on a
sphere the size of the Earth), so the map has no seams, no stretching near the poles and never
repeats. Nothing is stored: the same point always gives the same answer.

- land(lat, lng): mineral / forest / farmland / pasture, or water (seas, lakes: Natural Earth 1:10m)
- quality(item, lat, lng): 0-100 (0 = none here); ores and wood only on their land, crops, animals
  and fish farms anywhere on land at 50-100 (a gentle field); nothing on water
- sun(lat, lng), wind(lat, lng): 0-100 for solar and wind farms
- grid(item, south, west, north, east, n): an n x n heatmap (survey pictures)

All functions take numpy arrays as well as single numbers.
"""
from __future__ import annotations

import gzip
import math
from pathlib import Path

import numpy as np
import shapely

import gamedata as g

EARTH_R = 6_371_000.0
WORLD_SEED = 20261026

# ── 3D gradient noise ──────────────────────────────────────────────────────────────────────────

_GRADS = np.array([[1, 1, 0], [-1, 1, 0], [1, -1, 0], [-1, -1, 0], [1, 0, 1], [-1, 0, 1],
                   [1, 0, -1], [-1, 0, -1], [0, 1, 1], [0, -1, 1], [0, 1, -1], [0, -1, -1]], dtype=np.float64)


def _perm(seed: int) -> np.ndarray:
    p = np.random.default_rng(seed).permutation(256)
    return np.concatenate([p, p]).astype(np.int64)


def _fade(t):
    return t * t * t * (t * (t * 6 - 15) + 10)


def _noise3(x, y, z, perm: np.ndarray):
    """Gradient noise in [-1, 1] (roughly) at the points (x, y, z)."""
    xi, yi, zi = np.floor(x).astype(np.int64), np.floor(y).astype(np.int64), np.floor(z).astype(np.int64)
    xf, yf, zf = x - xi, y - yi, z - zi
    xi, yi, zi = xi & 255, yi & 255, zi & 255
    u, v, w = _fade(xf), _fade(yf), _fade(zf)

    def grad(h, dx, dy, dz):
        gv = _GRADS[h % 12]
        return gv[..., 0] * dx + gv[..., 1] * dy + gv[..., 2] * dz

    def h(a, b, c):
        return perm[perm[perm[xi + a] + yi + b] + zi + c]

    n000, n100 = grad(h(0, 0, 0), xf, yf, zf), grad(h(1, 0, 0), xf - 1, yf, zf)
    n010, n110 = grad(h(0, 1, 0), xf, yf - 1, zf), grad(h(1, 1, 0), xf - 1, yf - 1, zf)
    n001, n101 = grad(h(0, 0, 1), xf, yf, zf - 1), grad(h(1, 0, 1), xf - 1, yf, zf - 1)
    n011, n111 = grad(h(0, 1, 1), xf, yf - 1, zf - 1), grad(h(1, 1, 1), xf - 1, yf - 1, zf - 1)
    x00, x10 = n000 + u * (n100 - n000), n010 + u * (n110 - n010)
    x01, x11 = n001 + u * (n101 - n001), n011 + u * (n111 - n011)
    y0, y1 = x00 + v * (x10 - x00), x01 + v * (x11 - x01)
    return y0 + w * (y1 - y0)


class Field:
    """Fractal noise on the globe: a few octaves, features about `size_m` metres across."""

    def __init__(self, name: str, size_m: float, octaves: int = 3):
        seed = (WORLD_SEED * 1_000_003 + sum(ord(c) * 131 ** i for i, c in enumerate(name))) % 2**32
        self.perms = [_perm(seed + o) for o in range(octaves)]
        self.scale = EARTH_R / size_m
        # random offsets so fields don't share lattice points
        rng = np.random.default_rng(seed)
        self.offsets = rng.uniform(0, 1000, size=(octaves, 3))

    def __call__(self, lat, lng):
        la, lo = np.radians(np.asarray(lat, dtype=np.float64)), np.radians(np.asarray(lng, dtype=np.float64))
        cx, cy, cz = np.cos(la) * np.cos(lo), np.cos(la) * np.sin(lo), np.sin(la)
        total, amp, norm, freq = 0.0, 1.0, 0.0, self.scale
        for perm, off in zip(self.perms, self.offsets):
            total = total + amp * _noise3(cx * freq + off[0], cy * freq + off[1], cz * freq + off[2], perm)
            norm += amp
            amp *= 0.5
            freq *= 2.0
        return total / norm / 0.55            # roughly -1..1


# ── Water (Natural Earth 1:10m land and lakes, public domain; tools/make_water.py) ─────────────

_DATA = Path(__file__).resolve().parent / "data"
_water = {}


def _geoms():
    if not _water:
        for name in ("land", "lakes"):
            geom = shapely.from_wkb(gzip.decompress((_DATA / f"{name}.wkb.gz").read_bytes()))
            shapely.prepare(geom)
            _water[name] = geom
    return _water["land"], _water["lakes"]


def is_land(lat, lng):
    """True on land (not sea, not a big lake). Arrays in, arrays out."""
    land, lakes = _geoms()
    x, y = np.asarray(lng, dtype=np.float64), np.asarray(lat, dtype=np.float64)
    return shapely.contains_xy(land, x, y) & ~shapely.contains_xy(lakes, x, y)


# ── Land ───────────────────────────────────────────────────────────────────────────────────────

LAND_CODES = {"mineral": 1, "forest": 2, "farmland": 3, "pasture": 4}       # 0: water
LAND_NAMES = {v: k for k, v in LAND_CODES.items()}
_mineral = Field("land-mineral", 1_200)
_forest = Field("land-forest", 2_500)
_agri = Field("land-agri", 1_800)
MINERAL_CUT = 0.30       # ~20 % of the world is mineral land
FOREST_CUT = 0.10        # ~30 % forest


def land_code(lat, lng):
    m, f, a = _mineral(lat, lng), _forest(lat, lng), _agri(lat, lng)
    code = np.where(m > MINERAL_CUT, 1, np.where(f > FOREST_CUT, 2, np.where(a > -0.1, 3, 4)))
    return np.where(is_land(lat, lng), code, 0).astype(np.int8)


def land(lat: float, lng: float) -> str:
    return LAND_NAMES.get(int(land_code(lat, lng)), "water")


# ── Resource qualities ─────────────────────────────────────────────────────────────────────────
# How much of its land an item covers depends on its tier: common items almost everywhere, the
# rarest in small patches. A cut c means: quality > 0 only where the noise is above c.
TIER_CUT = {1: -0.15, 2: 0.20, 3: 0.45, 4: 0.60, 5: 0.70}
TIER_SIZE_M = {1: 900, 2: 700, 3: 500, 4: 400, 5: 300}

_ITEMS = {}                                   # item -> (land code or 0 for any land, Field, cut or None)
# crops, animals and fish farms: anywhere on land, in a gentle field of 50-100 (owner 2026-10-30:
# a heatmap just for fun -- worth looking around, but nowhere is bad)
GENTLE_OPS = {"farm", "ranch", "fish_farm"}
GENTLE_MIN = 50
GENTLE_SIZE_M = 1_200
for _op, (_name, _land, _items, _unlock) in g.OPERATIONS.items():
    if _land in ("water",):
        continue                              # sea fishing: later
    for _item, (_tier, _rate) in _items.items():
        if _item == g.ENERGY or _item in _ITEMS:
            continue
        gentle = _op in GENTLE_OPS
        _ITEMS[_item] = (LAND_CODES.get(_land, 0),
                         Field("item-" + _item, GENTLE_SIZE_M if gentle else TIER_SIZE_M[_tier]),
                         None if gentle else TIER_CUT[_tier])


def items() -> list[str]:
    return list(_ITEMS)


def quality(item: str, lat, lng):
    """0-100: how rich `item` is here (0: not here). Arrays in, arrays out."""
    land_req, field, cut = _ITEMS[item]
    if cut is None:                           # crops, animals, fish farms: 50-100 anywhere on land
        g01 = np.clip((field(lat, lng) + 0.5) / 1.0, 0.0, 1.0)
        return np.where(is_land(lat, lng), np.round(GENTLE_MIN + (100 - GENTLE_MIN) * g01), 0).astype(np.int16)
    # a smooth field like 1.2.3's scans: quality rises and falls gradually (no hard land-type edges);
    # rarer resources (higher cut) appear in fewer, smaller hotspots; nothing on water
    n = field(lat, lng)
    q = np.clip((n - cut) / (1.0 - cut), 0.0, 1.0)
    q = np.where(is_land(lat, lng), q, 0.0)
    return np.round(q * 100).astype(np.int16)


# ── Sun and wind ───────────────────────────────────────────────────────────────────────────────
_sun_noise = Field("sun", 40_000, octaves=2)
_wind_noise = Field("wind", 15_000, octaves=3)


def sun(lat, lng):
    """Sunniest near the tropics, little near the poles, with regional weather on top."""
    base = np.cos(np.radians(np.clip(np.abs(np.asarray(lat, dtype=np.float64)) - 15, 0, 90))) ** 1.5
    v = np.round(np.clip(base * 85 + _sun_noise(lat, lng) * 15, 5, 100))
    return np.where(is_land(lat, lng), v, 0).astype(np.int16)


def wind(lat, lng):
    v = np.round(np.clip(50 + _wind_noise(lat, lng) * 50, 5, 100))
    return np.where(is_land(lat, lng), v, 0).astype(np.int16)


# ── Heatmaps ───────────────────────────────────────────────────────────────────────────────────

def grid(what: str, south: float, west: float, north: float, east: float, n: int = 128) -> np.ndarray:
    """n x n values (rows north to south) of `what`: an item, "land", "sun" or "wind"."""
    lats = np.linspace(north, south, n)
    lngs = np.linspace(west, east, n)
    la, lo = np.meshgrid(lats, lngs, indexing="ij")
    if what == "land":
        return land_code(la, lo)
    if what == "sun":
        return sun(la, lo)
    if what == "wind":
        return wind(la, lo)
    return quality(what, la, lo)


def survey_grid(what: str, lat: float, lng: float, radius_m: float, max_n: int = 511):
    """A survey picture like 1.2.3's scans: square pixels of `step` metres (4 m, coarser only for big
    radii so it stays under max_n), the centre snapped to a fixed global grid (overlapping surveys
    sample the same points), pixel centres symmetric around it, only the circle. Rows north to south.
    Returns (values n x n, centre_lat, centre_lng, step_m, n)."""
    step = max(4.0, radius_m / ((max_n - 1) // 2))       # at most max_n pixels across
    half = math.ceil(radius_m / step)
    n = 2 * half + 1
    c = max(abs(math.cos(math.radians(lat))), 0.001)
    cy = round(lat * 111320.0 / step) * step                 # snapped centre, physical metres
    cx = round(lng * 111320.0 * c / step) * step
    off = (np.arange(n) - half) * step
    ys, xs = cy - off, cx + off                              # rows north to south, columns west to east
    la, lo = np.meshgrid(ys / 111320.0, xs / (111320.0 * c), indexing="ij")
    if what == "land":
        v = land_code(la, lo)
    elif what == "sun":
        v = sun(la, lo)
    elif what == "wind":
        v = wind(la, lo)
    else:
        v = quality(what, la, lo)
    v = np.asarray(v).astype(np.uint8)
    d2 = off[:, None] ** 2 + off[None, :] ** 2
    v[d2 > radius_m * radius_m] = 0
    return v, cy / 111320.0, cx / (111320.0 * c), step, n


def around(lat: float, lng: float, radius_m: float) -> tuple[float, float, float, float]:
    """(south, west, north, east) of the square around a point."""
    dlat = radius_m / 111_320.0
    dlng = radius_m / (111_320.0 * max(0.01, math.cos(math.radians(lat))))
    return lat - dlat, lng - dlng, lat + dlat, lng + dlng


def at(lat: float, lng: float) -> dict:
    """Everything about one point: its land and the quality of every item found there."""
    code = int(land_code(lat, lng))
    if code == 0:
        return {"land": "water", "items": {}, "sun": 0, "wind": 0}
    found = {}
    for item in _ITEMS:                        # the same values the survey pictures show
        q = int(quality(item, lat, lng))
        if q > 0:
            found[item] = q
    return {"land": LAND_NAMES[code], "items": found, "sun": int(sun(lat, lng)), "wind": int(wind(lat, lng))}
