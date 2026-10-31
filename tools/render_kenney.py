#!/usr/bin/env python3
"""Isometric renders of Kenney's CC0 "City Kit (Commercial)" models for the headquarters pictures
(owner 2026-10-25). A small software renderer, no OpenGL: every pixel is depth-tested (z-buffer),
its colour sampled from the model's texture, flat-shaded per face, supersampled 3x.

Luxury stages (hq_thumb_10_1..10_6) are painted in 3D: gold bands at fixed heights on the tower,
gold base and top, gold-tinted glass and a golden spire -- they follow the facades.

  python render_kenney.py <kenney city kit folder> <out folder>
"""
from __future__ import annotations

import math
import os
import sys

import numpy as np
import trimesh
from PIL import Image

SS = 3
LIGHT = np.array([-0.5, 0.85, 0.35])
LIGHT = LIGHT / np.linalg.norm(LIGHT)
GOLD = np.array([240, 190, 60], dtype=float)
YAW, PITCH = math.radians(45), math.radians(30)
_RY = np.array([[math.cos(YAW), 0, math.sin(YAW)], [0, 1, 0], [-math.sin(YAW), 0, math.cos(YAW)]])
_RX = np.array([[1, 0, 0], [0, math.cos(PITCH), -math.sin(PITCH)], [0, math.sin(PITCH), math.cos(PITCH)]])
VIEW = _RX @ _RY

# headquarters level -> model; levels 1-5 share one scale, 6-10 (skyscrapers) another, so a higher
# level is really bigger. 10_1..10_6 are level 10 with more and more gold.
LEVELS = {1: 'building-d', 2: 'building-c', 3: 'building-a', 4: 'building-h', 5: 'building-j',
          6: 'building-skyscraper-a', 7: 'building-skyscraper-e', 8: 'building-skyscraper-c',
          9: 'building-skyscraper-b', 10: 'building-skyscraper-d'}
LUXURY_MODEL = 'building-skyscraper-d'
# per stage: gold bands, gold base, gold top, glass tint (0..1), spire, light on top
LUXURY = {1: (1, False, False, 0.0, False, False), 2: (2, True, False, 0.0, False, False),
          3: (3, True, True, 0.15, False, False), 4: (4, True, True, 0.3, False, False),
          5: (5, True, True, 0.45, True, False), 6: (6, True, True, 0.6, True, False)}   # no light on top (owner 2026-10-25)


def load(path):
    scene = trimesh.load(path)
    meshes = scene.dump() if isinstance(scene, trimesh.Scene) else [scene]
    parts = []
    for m in meshes:
        tex = None
        mat = getattr(m.visual, 'material', None)
        for attr in ('baseColorTexture', 'image'):
            tex = tex or getattr(mat, attr, None)
        uv = getattr(m.visual, 'uv', None)
        parts.append((np.asarray(m.vertices, float), np.asarray(m.faces), None if uv is None else np.asarray(uv, float),
                      None if tex is None else np.asarray(tex.convert('RGB'), float)))
    return parts


def spire(top_y, cx, cz, base, height):
    """A four-sided golden spire standing on the roof."""
    b = base / 2
    v = np.array([[cx - b, top_y, cz - b], [cx + b, top_y, cz - b], [cx + b, top_y, cz + b], [cx - b, top_y, cz + b],
                  [cx, top_y + height, cz]])
    f = np.array([[0, 1, 4], [1, 2, 4], [2, 3, 4], [3, 0, 4]])
    return v, f


class Raster:
    def __init__(self, w, h):
        self.w, self.h = w, h
        self.z = np.full((h, w), -np.inf)
        self.rgb = np.zeros((h, w, 3))
        self.a = np.zeros((h, w), bool)

    def tri(self, p, uvs, tex, flat, shade, wy, paint):
        """p: 3x3 screen coords (x, y, depth). uvs: 3x2 or None. wy: world heights of the corners."""
        x0, x1 = int(max(0, math.floor(p[:, 0].min()))), int(min(self.w - 1, math.ceil(p[:, 0].max())))
        y0, y1 = int(max(0, math.floor(p[:, 1].min()))), int(min(self.h - 1, math.ceil(p[:, 1].max())))
        if x1 < x0 or y1 < y0:
            return
        (ax, ay, _), (bx, by, _), (cx, cy, _) = p
        den = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
        if abs(den) < 1e-9:
            return
        gx, gy = np.meshgrid(np.arange(x0, x1 + 1) + 0.5, np.arange(y0, y1 + 1) + 0.5)
        l1 = ((by - cy) * (gx - cx) + (cx - bx) * (gy - cy)) / den
        l2 = ((cy - ay) * (gx - cx) + (ax - cx) * (gy - cy)) / den
        l3 = 1 - l1 - l2
        inside = (l1 >= -1e-4) & (l2 >= -1e-4) & (l3 >= -1e-4)
        if not inside.any():
            return
        z = l1 * p[0, 2] + l2 * p[1, 2] + l3 * p[2, 2]
        zb = self.z[y0:y1 + 1, x0:x1 + 1]
        win = inside & (z > zb)
        if not win.any():
            return
        if tex is not None and uvs is not None:
            u = (l1 * uvs[0, 0] + l2 * uvs[1, 0] + l3 * uvs[2, 0]) % 1.0
            v = (l1 * uvs[0, 1] + l2 * uvs[1, 1] + l3 * uvs[2, 1]) % 1.0
            th, tw = tex.shape[:2]
            col = tex[np.clip(((1 - v) * (th - 1)).astype(int), 0, th - 1), np.clip((u * (tw - 1)).astype(int), 0, tw - 1)]
        else:
            col = np.broadcast_to(flat, gx.shape + (3,)).copy()
        if paint is not None:
            col = paint(col, l1 * wy[0] + l2 * wy[1] + l3 * wy[2])
        zb[win] = z[win]
        self.rgb[y0:y1 + 1, x0:x1 + 1][win] = np.clip(col * shade, 0, 255)[win]
        self.a[y0:y1 + 1, x0:x1 + 1][win] = True


def render(path, size=(300, 375), units_per_frame=None, luxury=0, stretch=1.0):
    """`units_per_frame`: model height (screen units) that fills the frame -- the same value for a
    group of levels keeps their sizes comparable. `stretch` makes the building taller (more stories)."""
    parts = load(path)
    if stretch != 1.0:
        y0 = min(p[0][:, 1].min() for p in parts)
        parts = [(np.column_stack([v[:, 0], y0 + (v[:, 1] - y0) * stretch, v[:, 2]]), f, uv, t)
                 for v, f, uv, t in parts]
    allv = np.vstack([p[0] for p in parts])
    ymin, ymax = allv[:, 1].min(), allv[:, 1].max()
    bands, base, crown, tint, has_spire, glow = LUXURY.get(luxury, (0, False, False, 0.0, False, False))
    spire_part = None
    if has_spire:
        top = allv[allv[:, 1] > ymax - 1e-3]
        sv, sf = spire(ymax, top[:, 0].mean(), top[:, 2].mean(), 0.22, (ymax - ymin) * 0.16)
        spire_part = (sv, sf)
        allv = np.vstack([allv, sv])
    W, H = size[0] * SS, size[1] * SS
    pv = allv @ VIEW.T
    lo, hi = pv.min(axis=0), pv.max(axis=0)
    height = units_per_frame or (hi[1] - lo[1])
    scale = min(H * 0.94 / height, W * 0.9 / (hi[0] - lo[0]))
    ox = W / 2 - (lo[0] + hi[0]) / 2 * scale
    oy = H - 0.03 * H + lo[1] * scale

    def paint(col, wy):
        t = (wy - ymin) / max(ymax - ymin, 1e-6)
        gold = np.zeros(t.shape, bool)
        for i in range(bands):                           # bands at fixed heights, all round the tower
            b = 0.2 + i * 0.12
            gold |= (t > b) & (t < b + 0.025)
        if base:
            gold |= t < 0.045
        if crown:
            gold |= t > 0.955
        out = col
        if tint:                                         # warm the glass (bluish texels) towards gold
            glass = (col[..., 2] > col[..., 0] + 25)[..., None]
            out = np.where(glass, col * (1 - tint) + GOLD * tint, col)
        lum = col.mean(axis=-1, keepdims=True) / 255.0
        return np.where(gold[..., None], GOLD * (0.6 + 0.55 * lum), out)

    ras = Raster(W, H)
    jobs = [(v, f, uv, tex, False) for v, f, uv, tex in parts]
    if spire_part:
        jobs.append((spire_part[0], spire_part[1], None, None, True))
    for v, f, uv, tex, is_spire in jobs:
        for face in f:
            tri = v[face]
            n = np.cross(tri[1] - tri[0], tri[2] - tri[0])
            nl = np.linalg.norm(n)
            if nl == 0:
                continue
            n = n / nl
            if (VIEW @ n)[2] < -1e-6:                    # facing away from the camera
                continue
            shade = 0.58 + 0.42 * max(0.0, float(n @ LIGHT))
            q = tri @ VIEW.T
            p = np.column_stack([ox + q[:, 0] * scale, oy - q[:, 1] * scale, q[:, 2]])
            ras.tri(p, None if uv is None else uv[face], tex, GOLD if is_spire else np.array([200.0, 200.0, 200.0]),
                    shade, tri[:, 1], None if (is_spire or not luxury) else paint)
    im = Image.fromarray(np.dstack([ras.rgb, ras.a * 255.0]).astype(np.uint8), 'RGBA')
    if glow:                                             # a soft light at the tip of the spire
        tip = spire_part[0][-1] @ VIEW.T
        cx, cy = ox + tip[0] * scale, oy - tip[1] * scale
        yy, xx = np.ogrid[:H, :W]
        g = np.clip(1 - np.hypot(xx - cx, yy - cy) / (W * 0.1), 0, 1) ** 2
        halo = np.dstack([np.full((H, W), 255.0), np.full((H, W), 236.0), np.full((H, W), 150.0), g * 230])
        im = Image.alpha_composite(im, Image.fromarray(halo.astype(np.uint8), 'RGBA'))
    return im.resize(size, Image.LANCZOS)


def model_height(models, name):
    return float(np.ptp(np.vstack([p[0] for p in load(os.path.join(models, name + '.glb'))]) @ VIEW.T, axis=0)[1])


def level_fill(level):
    """Share of the frame height a level's building fills: grows steadily, so every level looks
    bigger than the one before (level 1: 40 % ... level 10: 82 %, the spire stages up to 94 %)."""
    return 0.40 + (level - 1) * (0.42 / 9)


def all_levels(kit, size):
    """{name: image} for hq_thumb_1..10 and 10_1..10_6 at `size`."""
    models = os.path.join(kit, 'Models', 'GLB format')
    out = {}
    for lv, name in LEVELS.items():
        out[f'hq_thumb_{lv}'] = render(os.path.join(models, name + '.glb'), size,
                                       model_height(models, name) / level_fill(lv) * 0.94)
    h10 = model_height(models, LUXURY_MODEL) / level_fill(10) * 0.94
    for sub in range(1, 7):
        out[f'hq_thumb_10_{sub}'] = render(os.path.join(models, LUXURY_MODEL + '.glb'), size, h10, luxury=sub)
    return out


def main(kit, out):
    os.makedirs(out, exist_ok=True)
    for name, im in all_levels(kit, (300, 375)).items():
        im.save(os.path.join(out, name + '.png'))
    print('rendered 16')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
