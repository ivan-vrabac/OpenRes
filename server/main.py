from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
import auth
import re
import json, datetime, os, zlib, sqlite3, hashlib, uuid, base64, math, struct, threading

app = FastAPI()
# All deployment settings come from the environment; see deploy/.env.example.
DB_PATH = os.environ.get("DB_PATH", "/data/game.db")
LOG_FILE = os.environ.get("LOG_FILE", "/logs/requests.log")
# Optional legacy pass-through for requests this server does not implement.
# Disabled unless both are set: the incoming host suffix FROM is rewritten to TO.
os.makedirs(os.path.dirname(DB_PATH) or ".", exist_ok=True)
os.makedirs(os.path.dirname(LOG_FILE) or ".", exist_ok=True)

# ── Constants ───────────────────────────────────────────────────────────────────

import names
# Rarity tiers for scanner



# Drone scan range in metres per Drone Research level (levels 1–10)
# Drone scan / remote build range by Drone Research level (owner 2026-10-20: at most 10 km)

# ── Tech Center configuration (single source of truth) ─────────────────────────
# radius = scan area radius metres; accuracy = prediction fidelity %;
# max_quality = hard cap on displayed quality at this level.

# Fixed drone scan range (uses one Scan Drone item from inventory)

# Prospect tokens: one token per scan (single-use). keyed by token UUID.
# One construction consumes the token; the next mine requires a fresh scan.

# ── Multi-scale noise resource fields (server-side only, never sent to client) ──
# Per-resource noise configuration.
# broad_wl/med_wl/fine_wl = noise wavelength in km (larger = smoother, wider blobs).
# w_broad/w_med/w_fine    = blend weights (must sum to 1).
# warp                    = domain-warp strength in km (higher = more organic shapes).
# coverage                = approx fraction of map area that has quality > 0.
# richness                = skew toward high quality (0 = linear, 1 = more highs).
# rich_chance             = probability that a region gets an exceptional core.
# rich_wl                 = spatial wavelength of rich cores in km.
# q_min/q_max             = quality range 0–1 (multiplied by 100 for final value).
# bg                      = background quality present everywhere (common resources only).
_NOISE_RES_CONFIG: dict = {
    # coverage: exact fraction of map with quality > 0 (percentile-based threshold).
    # richness: ease-out exponent (1+R); higher = more pixels pushed to 95-100%.
    # pct_sat: percentile of active pixels that maps to q_max=100% (default 98.0).
    # env_*: optional large-scale envelope that redistributes quality into large contiguous
    #        deposits without changing the total coverage fraction (percentile threshold
    #        ensures coverage stays the same; only the spatial arrangement changes).
    #        alpha=1.0 = gentle modulation (preserves scatter); 2.0 = strongly isolated deposits.

    # Common — large patches; gentle envelopes create broad high-quality regions (11–15 km).
    4:   {"seed":  0, "broad_wl": 4.0, "med_wl": 0.80, "fine_wl": 0.12, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.30, "coverage": 0.65, "richness": 1.0, "rich_chance": 0.30, "rich_wl": 0.10, "q_min": 0.10, "q_max": 1.00, "bg":  8,
          "env_seed": 128,  "env_broad_wl": 15.0, "env_med_wl": 6.0, "env_fine_wl": 1.5, "env_w_broad": 0.70, "env_w_med": 0.25, "env_w_fine": 0.05, "env_alpha": 1.0},   # Clay      unlock 1
    54:  {"seed":  1, "broad_wl": 3.5, "med_wl": 0.70, "fine_wl": 0.10, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.30, "coverage": 0.55, "richness": 1.0, "rich_chance": 0.25, "rich_wl": 0.10, "q_min": 0.10, "q_max": 1.00, "bg":  5,
          "env_seed": 478,  "env_broad_wl": 14.0, "env_med_wl": 5.5, "env_fine_wl": 1.4, "env_w_broad": 0.70, "env_w_med": 0.25, "env_w_fine": 0.05, "env_alpha": 1.0},   # Sand      unlock 7
    5:   {"seed":  2, "broad_wl": 3.0, "med_wl": 0.60, "fine_wl": 0.09, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.30, "coverage": 0.50, "richness": 1.0, "rich_chance": 0.25, "rich_wl": 0.09, "q_min": 0.10, "q_max": 1.00, "bg":  5,
          "env_seed": 135,  "env_broad_wl": 13.0, "env_med_wl": 5.0, "env_fine_wl": 1.3, "env_w_broad": 0.70, "env_w_med": 0.25, "env_w_fine": 0.05, "env_alpha": 1.0},   # Gravel    unlock 3
    21:  {"seed":  3, "broad_wl": 2.5, "med_wl": 0.50, "fine_wl": 0.08, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.40, "coverage": 0.45, "richness": 1.0, "rich_chance": 0.22, "rich_wl": 0.09, "q_min": 0.10, "q_max": 1.00, "bg":  3,
          "env_seed": 247,  "env_broad_wl": 12.0, "env_med_wl": 5.0, "env_fine_wl": 1.2, "env_w_broad": 0.72, "env_w_med": 0.23, "env_w_fine": 0.05, "env_alpha": 1.0},   # Limestone unlock 2
    9:   {"seed":  4, "broad_wl": 2.2, "med_wl": 0.50, "fine_wl": 0.07, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.40, "coverage": 0.40, "richness": 1.0, "rich_chance": 0.22, "rich_wl": 0.08, "q_min": 0.10, "q_max": 1.00, "bg":  2,
          "env_seed": 163,  "env_broad_wl": 11.0, "env_med_wl": 4.5, "env_fine_wl": 1.1, "env_w_broad": 0.72, "env_w_med": 0.23, "env_w_fine": 0.05, "env_alpha": 1.0},   # Coal      unlock 4
    # Uncommon — moderate coverage; envelopes create clear 1–2 km deposit regions.
    17:  {"seed":  5, "broad_wl": 2.0, "med_wl": 0.50, "fine_wl": 0.07, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.33, "richness": 1.0, "rich_chance": 0.20, "rich_wl": 0.08, "q_min": 0.10, "q_max": 1.00, "bg":  0,
          "env_seed": 219,  "env_broad_wl": 10.0, "env_med_wl": 4.0, "env_fine_wl": 1.0, "env_w_broad": 0.78, "env_w_med": 0.18, "env_w_fine": 0.04, "env_alpha": 1.3},   # Iron      unlock 4
    11:  {"seed":  6, "broad_wl": 1.8, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.35, "richness": 1.0, "rich_chance": 0.20, "rich_wl": 0.07, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 177,  "env_broad_wl": 10.0, "env_med_wl": 4.0, "env_fine_wl": 1.0, "env_w_broad": 0.78, "env_w_med": 0.18, "env_w_fine": 0.04, "env_alpha": 1.3},   # Oil       unlock 1
    16:  {"seed":  7, "broad_wl": 1.8, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.24, "richness": 1.0, "rich_chance": 0.18, "rich_wl": 0.07, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 212,  "env_broad_wl":  9.0, "env_med_wl": 3.5, "env_fine_wl": 0.9, "env_w_broad": 0.80, "env_w_med": 0.17, "env_w_fine": 0.03, "env_alpha": 1.3},   # Bauxite   unlock 11
    19:  {"seed":  8, "broad_wl": 1.6, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.50, "coverage": 0.14, "richness": 1.0, "rich_chance": 0.18, "rich_wl": 0.07, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 233,  "env_broad_wl":  9.0, "env_med_wl": 3.5, "env_fine_wl": 0.9, "env_w_broad": 0.80, "env_w_med": 0.17, "env_w_fine": 0.03, "env_alpha": 1.3},   # Silver    unlock 33
    27:  {"seed":  9, "broad_wl": 1.4, "med_wl": 0.30, "fine_wl": 0.05, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.60, "coverage": 0.25, "richness": 1.0, "rich_chance": 0.16, "rich_wl": 0.06, "q_min": 0.15, "q_max": 1.00, "bg":  0,
          "env_seed": 289,  "env_broad_wl":  9.5, "env_med_wl": 3.8, "env_fine_wl": 1.0, "env_w_broad": 0.78, "env_w_med": 0.18, "env_w_fine": 0.04, "env_alpha": 1.3},   # Copper    unlock 9
    # Rare — smaller pockets; envelopes create few, isolated high-quality deposits (750–1500 m).
    18:  {"seed": 10, "broad_wl": 1.2, "med_wl": 0.30, "fine_wl": 0.05, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.60, "coverage": 0.11, "richness": 1.2, "rich_chance": 0.14, "rich_wl": 0.06, "q_min": 0.20, "q_max": 1.00, "bg":  0,
          "env_seed": 226,  "env_broad_wl":  8.0, "env_med_wl": 3.2, "env_fine_wl": 0.8, "env_w_broad": 0.85, "env_w_med": 0.12, "env_w_fine": 0.03, "env_alpha": 1.7},   # Gold      unlock 38
    89:  {"seed": 11, "broad_wl": 1.2, "med_wl": 0.30, "fine_wl": 0.05, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.60, "coverage": 0.20, "richness": 1.2, "rich_chance": 0.14, "rich_wl": 0.06, "q_min": 0.20, "q_max": 1.00, "bg":  0,
          "env_seed": 723,  "env_broad_wl":  8.0, "env_med_wl": 3.2, "env_fine_wl": 0.8, "env_w_broad": 0.85, "env_w_med": 0.12, "env_w_fine": 0.03, "env_alpha": 1.7},   # Lithium   unlock 15
    168: {"seed": 12, "broad_wl": 2.0, "med_wl": 0.40, "fine_wl": 0.06, "w_broad": 0.60, "w_med": 0.30, "w_fine": 0.10, "warp": 0.70, "coverage": 0.03, "richness": 1.0, "rich_chance": 0.12, "rich_wl": 0.06, "q_min": 0.10, "q_max": 1.00, "pct_sat": 99.5, "bg":  0,
          "env_seed": 1276, "env_broad_wl":  8.5, "env_med_wl": 3.5, "env_fine_wl": 0.8, "env_w_broad": 0.87, "env_w_med": 0.11, "env_w_fine": 0.02, "env_alpha": 1.7},   # Wolframite unlock 50
    50:  {"seed": 13, "broad_wl": 1.0, "med_wl": 0.25, "fine_wl": 0.04, "w_broad": 0.50, "w_med": 0.35, "w_fine": 0.15, "warp": 0.70, "coverage": 0.17, "richness": 1.2, "rich_chance": 0.12, "rich_wl": 0.06, "q_min": 0.20, "q_max": 1.00, "bg":  0,
          "env_seed": 450,  "env_broad_wl":  8.0, "env_med_wl": 3.2, "env_fine_wl": 0.8, "env_w_broad": 0.85, "env_w_med": 0.12, "env_w_fine": 0.03, "env_alpha": 1.7},   # Ilmenite  unlock 20
    # Extremely rare — primary×envelope² produces a few large (500-1500m) deposits among small scattered ones.
    # env_seed generates a separate large-scale (8km) envelope; multiplying concentrates deposits.
    82:  {"seed": 14, "broad_wl": 6.0, "med_wl": 1.5, "fine_wl": 0.3, "w_broad": 0.85, "w_med": 0.12, "w_fine": 0.03,
          "warp": 0.80, "coverage": 0.03, "richness": 0.8, "rich_chance": 0.10, "rich_wl": 0.05,
          "q_min": 0.08, "q_max": 1.00, "pct_sat": 99.5, "bg": 0,
          "env_seed": 888, "env_broad_wl": 8.0, "env_med_wl": 4.0, "env_fine_wl": 1.0,
          "env_w_broad": 0.92, "env_w_med": 0.07, "env_w_fine": 0.01, "env_alpha": 2.0},  # Diamond unlock 48
}

# ── Master resource field (server-side, tileable, 4m scan resolution) ────────────
# Coordinate system: equirectangular
#   world_x_m = lng * 111320.0
#   world_y_m = lat * 111320.0
# Wrapping uses a tilted geographic lattice so the resource pattern repeats.
# See _LATTICE_* constants.
MASTER_N = 5000         # samples per dimension (one unit-cell of the lattice)
MASTER_SAMPLE_M = 4.0   # metres per sample (scan resolution; field pixel ≈28 m)

# ── Geographic repetition lattice ────────────────────────────────────────────────
# Resource clouds repeat at integer combinations of A and B (in degrees).
# Vectors measured from RESOURCES GPS MMO spatial analysis.
_LATTICE_A_LAT =  1.09813   # Δlat° per step along A
_LATTICE_A_LNG =  0.58704   # Δlng° per step along A
_LATTICE_B_LAT = -0.58703   # Δlat° per step along B
_LATTICE_B_LNG =  1.21451   # Δlng° per step along B
# det(M) where M columns are A and B: det = A_lat*B_lng - B_lat*A_lng
_LATTICE_DET = _LATTICE_A_LAT * _LATTICE_B_LNG - _LATTICE_B_LAT * _LATTICE_A_LNG
# Inverse coefficients scaled to world_x_m / world_y_m (÷111320 absorbed here)
# u = IU_Y*world_y_m + IU_X*world_x_m ;  v = IV_Y*world_y_m + IV_X*world_x_m
_LATTICE_IU_Y = ( _LATTICE_B_LNG) / (_LATTICE_DET * 111320.0)
_LATTICE_IU_X = (-_LATTICE_B_LAT) / (_LATTICE_DET * 111320.0)
_LATTICE_IV_Y = (-_LATTICE_A_LNG) / (_LATTICE_DET * 111320.0)
_LATTICE_IV_X = ( _LATTICE_A_LAT) / (_LATTICE_DET * 111320.0)

_master_fields: dict = {}        # mine_id → uint8 ndarray 5000×5000
_master_lock = threading.Lock()  # one field generated at a time

# Heatmap result cache: (cx_snap, cy_snap, tc_level) → (timestamp, result_dict)
# Quality fields are deterministic — cache for 30 min, evict oldest when full.

# Heatmap colour stops: [q_threshold, R, G, B] — default thermal scheme

def _encode_png_rgba(rgba_bytes: bytes, width: int, height: int) -> bytes:
    """Encode raw RGBA bytes as PNG using stdlib only."""
    def _chunk(tag, data):
        c = tag + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    ihdr = struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)
    row_sz = width * 4
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        raw += rgba_bytes[y*row_sz:(y+1)*row_sz]
    return (b'\x89PNG\r\n\x1a\n'
            + _chunk(b'IHDR', ihdr)
            + _chunk(b'IDAT', zlib.compress(bytes(raw), 1))
            + _chunk(b'IEND', b''))

# ── Vectorised gradient noise (numpy, no C extensions required) ─────────────────

try:
    import numpy as np
    _HAS_NP = True
except ImportError:
    _HAS_NP = False

if _HAS_NP:
    def _smooth_noise_arr(xs, ys, seed: int):
        ix = np.floor(xs).astype(np.int64)
        iy = np.floor(ys).astype(np.int64)
        fx, fy = xs - ix, ys - iy
        def _h(bx, by):
            h = ((bx * 73856093) ^ (by * 19349663) ^ int(seed) * 83492791) & 0x7FFFFFFF
            h = ((h ^ (h >> 16)) * 0x45d9f3b) & 0x7FFFFFFF
            return ((h ^ (h >> 16)) * 0x45d9f3b) & 0x7FFFFFFF
        def _g(h, dx, dy):
            gx = np.where((h & 4) == 0, 1.0, -1.0)  # matches scalar: h8 in {0,1,2,3}
            gy = np.where((h & 2) == 0, 1.0, -1.0)  # matches scalar: h8 in {0,1,4,5}
            return gx * dx + gy * dy
        def _f(t): return t*t*t*(t*(t*6-15)+10)
        u, v = _f(fx), _f(fy)
        n00 = _g(_h(ix,   iy  ), fx,   fy  )
        n10 = _g(_h(ix+1, iy  ), fx-1, fy  )
        n01 = _g(_h(ix,   iy+1), fx,   fy-1)
        n11 = _g(_h(ix+1, iy+1), fx-1, fy-1)
        return (n00*(1-u)+n10*u)*(1-v)+(n01*(1-u)+n11*u)*v

    def _fbm_arr(xs, ys, seed: int, octaves: int = 4,
                 persistence: float = 0.5, lacunarity: float = 2.0):
        val = np.zeros_like(xs, dtype=float)
        amp, freq, mx = 1.0, 1.0, 0.0
        for i in range(octaves):
            val += _smooth_noise_arr(xs*freq, ys*freq, seed + i*31337) * amp
            mx += amp; amp *= persistence; freq *= lacunarity
        return val / mx

    def _generate_master_field(mine_id: int) -> np.ndarray:
        """Generate 5000×5000 seamlessly-tileable master quality field (uint8 0-100).
        Uses FFT spectral synthesis — inherently periodic, so left/right and top/bottom
        edges connect without seams.  One deterministic field per resource."""
        cfg = _NOISE_RES_CONFIG[mine_id]
        N   = MASTER_N
        rng = np.random.default_rng(int(cfg["seed"]) * 104729 + mine_id * 31337 + 99991)

        # Frequency arrays for rfft2 output shape (N, N//2+1)
        fy  = np.fft.fftfreq(N)[:, None].astype(np.float32)
        fx  = np.fft.rfftfreq(N)[None, :].astype(np.float32)
        fr  = np.sqrt(fx*fx + fy*fy).astype(np.float32)   # cycles/sample

        # Gaussian band-pass peaks at each wavelength scale (log-frequency space)
        def _band(wl_km: float, w: float = 0.7) -> np.ndarray:
            f_pk = float(MASTER_SAMPLE_M) / (wl_km * 1000.0)
            safe = np.where(fr > 0.0, fr, f_pk)
            return np.exp(-0.5 * ((np.log(safe / f_pk)) / w) ** 2).astype(np.float32)

        power = (float(cfg["w_broad"]) * _band(cfg["broad_wl"]) +
                 float(cfg["w_med"])   * _band(cfg["med_wl"])   +
                 float(cfg["w_fine"])  * _band(cfg["fine_wl"]))
        power[0, 0] = 0.0  # zero mean

        # Random phase → complex spectrum → inverse FFT
        phase    = rng.uniform(-math.pi, math.pi, (N, N//2+1)).astype(np.float32)
        spectrum = (np.sqrt(power) * (np.cos(phase) + 1j*np.sin(phase))).astype(np.complex64)
        del phase, power, fr, fx, fy  # free before large IFFT output

        field = np.fft.irfft2(spectrum, s=(N, N)).astype(np.float32)
        del spectrum

        # Normalise to [0, 1]
        mn, mx = float(field.min()), float(field.max())
        if mx > mn:
            field -= mn
            field /= (mx - mn)

        # Optional large-scale envelope: multiplied with primary field to create large
        # deposits that are globally very sparse. Activated by "env_seed" in config.
        # Without this, low-coverage spectral fields only produce tiny isolated tips.
        if "env_seed" in cfg:
            env_seed  = int(cfg["env_seed"]) * 104729 + mine_id * 31337 + 99991
            env_rng   = np.random.default_rng(env_seed)
            env_fy    = np.fft.fftfreq(N)[:, None].astype(np.float32)
            env_fx    = np.fft.rfftfreq(N)[None, :].astype(np.float32)
            env_fr    = np.sqrt(env_fx*env_fx + env_fy*env_fy).astype(np.float32)
            def _env_band(wl_km: float, w: float = 0.5) -> np.ndarray:
                f_pk = float(MASTER_SAMPLE_M) / (wl_km * 1000.0)
                safe = np.where(env_fr > 0.0, env_fr, f_pk)
                return np.exp(-0.5 * ((np.log(safe / f_pk)) / w) ** 2).astype(np.float32)
            env_power = (float(cfg["env_w_broad"]) * _env_band(cfg["env_broad_wl"]) +
                         float(cfg["env_w_med"])   * _env_band(cfg["env_med_wl"])   +
                         float(cfg["env_w_fine"])  * _env_band(cfg["env_fine_wl"]))
            env_power[0, 0] = 0.0
            env_ph   = env_rng.uniform(-math.pi, math.pi, (N, N//2+1)).astype(np.float32)
            env_spec = (np.sqrt(env_power) * (np.cos(env_ph) + 1j*np.sin(env_ph))).astype(np.complex64)
            del env_ph, env_power, env_fy, env_fx, env_fr
            env_f    = np.fft.irfft2(env_spec, s=(N, N)).astype(np.float32)
            del env_spec
            e_mn, e_mx = float(env_f.min()), float(env_f.max())
            if e_mx > e_mn:
                env_f -= e_mn; env_f /= (e_mx - e_mn)
            field = field * np.power(env_f, float(cfg.get("env_alpha", 2.0)))
            del env_f, env_rng
            mn, mx = float(field.min()), float(field.max())
            if mx > mn:
                field -= mn; field /= (mx - mn)

        # Percentile-based threshold: guarantees exactly `coverage` fraction of pixels
        # are in the active (quality > 0) zone, regardless of the noise distribution.
        coverage  = float(cfg["coverage"])
        threshold = float(np.percentile(field.ravel(), (1.0 - coverage) * 100.0))

        # Smoothstep transition zone (anti-aliased deposit edges)
        active_span = float(field.max()) - threshold
        zone      = max(0.005, active_span * 0.08)
        bg        = float(cfg.get("bg", 0))
        blend_raw = np.clip((field - (threshold - zone)) / (2.0 * zone), 0.0, 1.0)
        blend     = blend_raw * blend_raw * (3.0 - 2.0 * blend_raw)

        # Quality scale: bottom of active range → q_min; pct_sat-th percentile → q_max.
        # pct_sat=98 (default) means top 2% reach 100%; higher values keep more pixels below max.
        flat     = field.ravel()
        active_v = flat[flat > threshold]
        pct_sat  = float(cfg.get("pct_sat", 98.0))
        p_high   = float(np.percentile(active_v, pct_sat)) if len(active_v) > 100 else float(field.max())
        scale    = max(p_high - threshold, 1e-6)
        t2       = np.clip((field - threshold) / scale, 0.0, 1.0)

        # Ease-out richness: 1-(1-t2)^(1+richness)
        # richness=0 → identity; richness=1 → quadratic; richness=2 → cubic push to 100.
        richness = float(cfg.get("richness", 0.0))
        if richness > 0.0:
            t2 = 1.0 - np.power(np.clip(1.0 - t2, 1e-9, 1.0), 1.0 + richness)

        active_q = float(cfg["q_min"])*100.0 + t2*(float(cfg["q_max"]) - float(cfg["q_min"]))*100.0
        q        = bg + blend * (active_q - bg)
        q        = np.clip(q, 0.0, 100.0)
        result   = np.clip(np.round(q), 0, 100).astype(np.uint8)
        del field, blend_raw, blend, t2, active_q, q, flat, active_v
        return result

    def get_master_field(mine_id: int) -> np.ndarray:
        """Return cached master field, generating it if needed (thread-safe)."""
        if mine_id in _master_fields:
            return _master_fields[mine_id]
        with _master_lock:
            if mine_id not in _master_fields:
                _master_fields[mine_id] = _generate_master_field(mine_id)
        return _master_fields[mine_id]

    def _sample_master_bilinear(field: np.ndarray,
                                world_x_m: np.ndarray,
                                world_y_m: np.ndarray) -> np.ndarray:
        """Bilinear sample of master field at arrays of world coordinates (metres).
        Wraps via the geographic lattice so resources repeat with the lattice period."""
        u = _LATTICE_IU_Y * world_y_m + _LATTICE_IU_X * world_x_m
        v = _LATTICE_IV_Y * world_y_m + _LATTICE_IV_X * world_x_m
        u_frac = u - np.floor(u)
        v_frac = v - np.floor(v)

        fi = u_frac * MASTER_N      # float column index in [0, MASTER_N)
        fj = v_frac * MASTER_N      # float row index
        i0 = np.floor(fi).astype(np.int32) % MASTER_N
        j0 = np.floor(fj).astype(np.int32) % MASTER_N
        i1 = (i0 + 1) % MASTER_N
        j1 = (j0 + 1) % MASTER_N
        tx = (fi - np.floor(fi)).astype(np.float32)
        ty = (fj - np.floor(fj)).astype(np.float32)

        v00 = field[j0, i0].astype(np.float32)
        v10 = field[j0, i1].astype(np.float32)
        v01 = field[j1, i0].astype(np.float32)
        v11 = field[j1, i1].astype(np.float32)
        return (v00*(1-tx)*(1-ty) + v10*tx*(1-ty)
              + v01*(1-tx)*ty    + v11*tx*ty)

    def _grid_to_png_b64(q_flat: np.ndarray, grid_n: int) -> str:
        """Render flat float32 quality array (0-100) as GRAYSCALE RGBA PNG.
        R=G=B=A=quality_byte (0-255). Client applies colour palette from this source.
        Grid row 0 = southernmost; image row 0 = northernmost (flipped)."""
        q_2d   = np.clip(np.round(q_flat.reshape(grid_n, grid_n)).astype(np.int32), 0, 100)
        q_2d   = q_2d[::-1, :]                           # flip: south→north
        q_byte = (q_2d * 255 // 100).astype(np.uint8)    # 0-100 → 0-255
        # q=0 pixels must be fully transparent
        alpha  = np.where(q_2d > 0, q_byte, np.uint8(0))
        rgba   = np.stack([q_byte, q_byte, q_byte, alpha], axis=2)
        png    = _encode_png_rgba(rgba.tobytes(), grid_n, grid_n)
        return base64.b64encode(png).decode()

# Backward-compat alias used by mine_new
# Working atmosphere booster items
# boost = production multiplier when active, wa_delta = WA change on use, hours = duration

# HQ production boost: level → (boost_multiplier, radius_m)
# Multiplier: level 1=1.9x, each subsequent level +0.9; Radius: 115m at level 1, +15m per level
HQ_BOOST_FACTORS = {lvl: round(0.9 * lvl + 1.0, 1) for lvl in range(1, 11)}
HQ_BOOST_FACTORS[1] = 1.9
# HQ upgrade resource requirements: target_level → {item_id: qty}. Owner 2026-10-24: the old quantities
# ignored prices (level 10 needed 50 M Jewellery ≈ 150 trillion); now valued at the system price:
# ×2.6 per level up to level 5 (35 M), then ×12 per level up to about 10 trillion for level 10.
# Keep in sync with kHqUpgradeReqs in app/lib/screens/headquarters_screen.dart.

# ── DB ─────────────────────────────────────────────────────────────────────────

def get_db() -> sqlite3.Connection:
    # Requests run concurrently in threads; wait for a busy writer instead of failing fast.
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn

# ── Travel check (GPS spoofing) ─────────────────────────────────────────────────
# Positions come from the phone. Teleporting is refused: between two positioned actions the player
# can't have travelled faster than TRAVEL_MAX_KMH (allowing GPS jitter). Long gaps are always fine.
TRAVEL_MAX_KMH = 300
TRAVEL_FREE_M = 5000          # jumps up to this distance are always accepted (GPS fixes switching)

def check_travel(conn, hid: str, lat: float, lng: float) -> None:
    """Raise GameError('teleport') when the position implies impossible travel; else remember it."""
    r = conn.execute("SELECT pos_lat, pos_lng, pos_at FROM players WHERE hID=?", (hid,)).fetchone()
    now = datetime.datetime.utcnow()
    if r and r["pos_lat"] is not None and r["pos_at"]:
        try:
            dt_h = max(1e-6, (now - datetime.datetime.fromisoformat(r["pos_at"])).total_seconds() / 3600)
        except ValueError:
            dt_h = 1e9
        d = haversine_m(r["pos_lat"], r["pos_lng"], lat, lng)
        if d > TRAVEL_FREE_M and d / 1000 / dt_h > TRAVEL_MAX_KMH:
            raise econ.GameError("teleport", "Your position jumped too far too fast. Wait a moment and try again.")
    conn.execute("UPDATE players SET pos_lat=?, pos_lng=?, pos_at=? WHERE hID=?", (lat, lng, now.isoformat(), hid))

# Owner 2026-10-23: start with enough for about six clay pits; scans are free below level 5
STARTING_CREDITS = 250000

def record_daily_activity(conn, hid: str):
    today = datetime.datetime.utcnow().strftime("%Y-%m-%d")
    conn.execute(
        "INSERT OR IGNORE INTO player_activity (hid, day) VALUES (?,?)", (hid, today))

def init_db():
    with get_db() as conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS players (
                hID           TEXT PRIMARY KEY,
                company_name  TEXT UNIQUE NOT NULL,
                credits       INTEGER DEFAULT 50000,
                xp            INTEGER DEFAULT 0,
                level         INTEGER DEFAULT 1,
                team_id       INTEGER DEFAULT 0,
                wh_level      INTEGER DEFAULT 1,
                created_at    TEXT DEFAULT (datetime('now'))
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS proto_log (
                log_id     TEXT PRIMARY KEY,
                hid        TEXT NOT NULL,
                log_type   TEXT NOT NULL,
                data_json  TEXT,
                created_at TEXT DEFAULT (datetime('now'))
            )""")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS player_activity (
                hid  TEXT NOT NULL,
                day  TEXT NOT NULL,
                PRIMARY KEY (hid, day)
            )""")
        # FCM push tokens
        conn.execute("""
            CREATE TABLE IF NOT EXISTS fcm_tokens (
                hid         TEXT NOT NULL,
                token       TEXT NOT NULL,
                platform    TEXT DEFAULT 'android',
                updated_at  TEXT DEFAULT (datetime('now')),
                PRIMARY KEY (hid, token)
            )""")
        # Server-side notification preferences and cooldowns
        conn.execute("""
            CREATE TABLE IF NOT EXISTS notif_prefs (
                hid                TEXT PRIMARY KEY,
                enabled             INTEGER DEFAULT 1,
                mine_warning        INTEGER DEFAULT 1,
                mine_destroyed      INTEGER DEFAULT 1,
                wh_almost_full      INTEGER DEFAULT 1,
                wh_full             INTEGER DEFAULT 1,
                last_warn_at        TEXT,
                last_destr_at       TEXT,
                last_wh_almost_at   TEXT,
                last_wh_full_at     TEXT
            )""")
        conn.commit()
        # Migrations: add columns if not present
        for col_def in [
            ("players",   "wa", "INTEGER DEFAULT 80"),
            ("players",   "last_event_check", "TEXT"),
            ("players",   "country_code", "TEXT"),
            # economy revamp 2026-10-23
            ("players",   "pos_lat", "REAL"),               # last reported position (travel check)
            ("players",   "pos_lng", "REAL"),
            ("players",   "pos_at", "TEXT"),
            ("players",   "hq_moved_at", "TEXT"),
            ("players",   "name_changes", "INTEGER DEFAULT 0"),
            ("players",   "delete_at", "TEXT"),             # GDPR deletion scheduled for
        ]:
            try:
                conn.execute(f"ALTER TABLE {col_def[0]} ADD COLUMN {col_def[1]} {col_def[2]}")
                conn.commit()
            except Exception:
                pass

        # names keep their capitals but are unique without regard to case (owner 2026-10-24)
        try:
            conn.execute("CREATE UNIQUE INDEX IF NOT EXISTS idx_players_name_ci ON players(lower(company_name))")
        except sqlite3.IntegrityError:
            conn.execute("CREATE INDEX IF NOT EXISTS idx_players_name_ci2 ON players(lower(company_name))")
        conn.commit()

init_db()
with get_db() as _conn:
    auth.init(_conn, db_connect=get_db)

# ── Helpers ────────────────────────────────────────────────────────────────────

def zlib_bytes(data) -> bytes:
    return zlib.compress(json.dumps(data, ensure_ascii=False).encode("utf-8"), 9)

def zlib_resp(data) -> Response:
    return Response(content=zlib_bytes(data),
                    headers={"content-type": "application/octet-stream"})

def plain_resp(text: str) -> Response:
    return Response(content=text.encode(), media_type="text/plain")

def json_resp(data) -> Response:
    return Response(content=json.dumps(data, ensure_ascii=False).encode(),
                    media_type="application/json")

def new_hid() -> str:
    return hashlib.md5(uuid.uuid4().bytes).hexdigest()

def new_id() -> str:
    return uuid.uuid4().hex

def norm_name(name: str) -> str:
    """Lookup key of a company name: names are case-insensitive (owner 2026-10-24) but stored and
    shown exactly as the player typed them; compare with lower(company_name) = norm_name(...)."""
    return name.strip().lower()

async def read_form(request: Request) -> tuple[bytes, dict]:
    body = await request.body()
    form = await request.form()
    return body, {k: v for k, v in form.items()}

def hid_from_sid(sid: str) -> str:
    return auth.hid_from_sid(sid)

def make_sid(hid: str) -> str:
    return auth.make_session(hid)

def log_entry(data: dict):
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(json.dumps(data, ensure_ascii=False) + "\n")
    except Exception:
        pass

def add_proto(conn, hid: str, log_type: str, data: dict):
    conn.execute(
        "INSERT INTO proto_log(log_id,hid,log_type,data_json,created_at) VALUES(?,?,?,?,?)",
        (new_id(), hid, log_type, json.dumps(data, ensure_ascii=False),
         datetime.datetime.utcnow().isoformat()))

def utcnow_iso() -> str:
    return datetime.datetime.utcnow().isoformat()

def haversine_m(lat1, lng1, lat2, lng2) -> float:
    R = 6371000
    p = math.pi / 180
    a = (math.sin((lat2-lat1)*p/2)**2 +
         math.cos(lat1*p)*math.cos(lat2*p)*math.sin((lng2-lng1)*p/2)**2)
    return 2 * R * math.asin(math.sqrt(a))

def hex_min_dist(lat1, lng1, lat2, lng2) -> float:
    """Direction-aware minimum center distance for flat-top hex tiles (circumradius 15m).
    At edge-normal directions = sqrt(3)*15 ≈ 25.98m; at vertex directions = 2*15 = 30m."""
    dlat = (lat2 - lat1) * 111320.0
    dlng = (lng2 - lng1) * 111320.0 * math.cos(math.radians((lat1 + lat2) / 2))
    bearing = math.atan2(dlng, dlat) % (2 * math.pi)
    nearest = round(bearing / (math.pi / 3)) * (math.pi / 3)
    phi = abs(bearing - nearest)
    phi = min(phi, math.pi / 6 - 0.001)
    return 15.0 * math.sqrt(3) / math.cos(phi)

# ── Set-based mine maths (scales to very large mine counts) ────────────────────
# The per-mine formulas of collect_mine() / rateHr, expressed in SQL so the database
# does the work in a few statements instead of Python touching every row.

# ── Scanner ────────────────────────────────────────────────────────────────────


# ── Auth ────────────────────────────────────────────────────────────────────────

_VALID_NAME = re.compile(r"^[a-zA-Z0-9 .,\[\]()\-]{1,20}$")

def _client_ip(request: Request) -> str:
    return request.client.host if request.client else "?"

@app.post("/api/v1/auth/session")
async def auth_session(request: Request):
    """mode=login: sign in to an existing account. mode=register: create a new account
    (fails if the name is taken). No mode: sign in, or register if the name is free.
    Returns {hID, sid, created}."""
    _, form = await read_form(request)
    name = (form.get("name") or "").strip()
    password = form.get("password") or ""
    mode = form.get("mode", "")
    if not _VALID_NAME.match(name):
        return json_resp({"error": "invalid_name",
                          "message": "Name: 1-20 letters, digits, spaces and . , [ ] ( ) -"})
    canon = norm_name(name)
    ip_key, name_key = f"ip:{_client_ip(request)}", f"name:{canon}"
    if auth.limiter.blocked(ip_key, name_key):
        return Response(content=json.dumps({"error": "rate_limited",
                                            "message": "Too many attempts. Try again later."}).encode(),
                        status_code=429, media_type="application/json")
    problem = auth.password_problem(password)
    from systems import identity
    with get_db() as conn:
        row = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (canon,)).fetchone()
        created = False
        if row and conn.execute("SELECT 1 FROM auth_identities WHERE hid=?", (row["hID"],)).fetchone():
            return json_resp({"error": "use_google", "message": "This company signs in with Google."})
        if not row and identity.google_only():
            return json_resp({"error": "use_google", "message": "New companies are created with Google sign-in."})
        if row and mode == "register":
            return json_resp({"error": "name_taken",
                              "message": "That company name is taken. Choose another, or log in."})
        if not row and mode == "login":
            return json_resp({"error": "not_found",
                              "message": "No company with that name. Check the name or register."})
        if not row:
            bad_name = names.name_problem(name)        # owner 2026-10-23: no rude or misleading names
            if bad_name:
                return json_resp({"error": "invalid_name", "message": bad_name})
            if problem:
                return json_resp({"error": "weak_password", "message": problem})
            hid = new_hid()
            conn.execute("INSERT INTO players(hID,company_name,credits,wa) VALUES(?,?,?,100)", (hid, name, STARTING_CREDITS))
            auth.set_password(conn, hid, password)
            created = True
        else:
            hid = row["hID"]
            stored = auth.get_hash(conn, hid)
            if stored is None:
                if not auth.LEGACY_CLAIM:
                    return json_resp({"error": "no_password",
                                      "message": "This account has no password yet. Ask the server admin."})
                if problem:
                    return json_resp({"error": "weak_password", "message": problem})
                auth.set_password(conn, hid, password)
            elif not auth.verify_password(password, stored):
                auth.limiter.fail(ip_key, name_key)
                return Response(content=json.dumps({"error": "wrong_password",
                                                    "message": "Wrong company name or password."}).encode(),
                                status_code=401, media_type="application/json")
        ban = SYSTEM_HELPERS.is_banned(hid) if hasattr(SYSTEM_HELPERS, "is_banned") else None
        if ban:
            from systems import moderation
            return json_resp({"error": "banned", "message": moderation.ban_text(ban)})
        # signing in cancels a scheduled account deletion (GDPR delay, systems/account.py)
        deletion_cancelled = conn.execute("UPDATE players SET delete_at=NULL WHERE hID=? AND delete_at IS NOT NULL",
                                          (hid,)).rowcount == 1
        conn.commit()
        sweep = getattr(SYSTEM_HELPERS, "ACCOUNT_SWEEP", None)
        if sweep:
            with econ.tx(conn):
                sweep(conn)
    auth.limiter.reset(name_key)
    if created:
        log_entry({"ts": utcnow_iso(), "endpoint": "authSession", "created": True, "hID": hid})
    return json_resp({"hID": hid, "sid": make_sid(hid), "created": created, "deletionCancelled": deletion_cancelled})

def create_company(conn, name: str) -> str:
    """A new company called `name` (Google sign-in). GameError when the name isn't allowed or taken."""
    if not _VALID_NAME.match(name):
        raise econ.GameError("invalid_name", "Name: 1-20 letters, digits, spaces and . , [ ] ( ) -")
    bad = names.name_problem(name)
    if bad:
        raise econ.GameError("invalid_name", bad)
    if conn.execute("SELECT 1 FROM players WHERE lower(company_name)=?", (norm_name(name),)).fetchone():
        raise econ.GameError("name_taken", "That company name is taken. Choose another.")
    hid = new_hid()
    conn.execute("INSERT INTO players(hID,company_name,credits,wa) VALUES(?,?,?,100)", (hid, name, STARTING_CREDITS))
    log_entry({"ts": utcnow_iso(), "endpoint": "createCompany", "created": True, "hID": hid})
    return hid


def check_password_login(conn, name: str, password: str) -> str:
    """The company `name` if `password` is right (linking it to Google once), else GameError."""
    key = f"name:{norm_name(name)}"
    if auth.limiter.blocked(key):
        raise econ.GameError("rate_limited", "Too many attempts. Try again later.")
    row = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (norm_name(name),)).fetchone()
    stored = auth.get_hash(conn, row["hID"]) if row else None
    if not row or stored is None or not auth.verify_password(password, stored):
        auth.limiter.fail(key)
        raise econ.GameError("wrong_password", "Wrong company name or password.")
    auth.limiter.reset(key)
    return row["hID"]


def remove_password(conn, hid: str) -> None:
    conn.execute("DELETE FROM player_auth WHERE hid=?", (hid,))


@app.post("/api/v1/auth/password")
async def auth_change_password(request: Request):
    """Change the signed-in player's password. Requires the current password."""
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    if not hid:
        return Response(content=b'{"error": "unauthorized", "message": "Please sign in again."}',
                        status_code=401, media_type="application/json")
    ip_key, hid_key = f"ip:{_client_ip(request)}", f"pw:{hid}"
    if auth.limiter.blocked(ip_key, hid_key):
        return Response(content=json.dumps({"error": "rate_limited",
                                            "message": "Too many attempts. Try again later."}).encode(),
                        status_code=429, media_type="application/json")
    new = form.get("new_password") or ""
    problem = auth.password_problem(new)
    if problem:
        return json_resp({"error": "weak_password", "message": problem})
    with get_db() as conn:
        stored = auth.get_hash(conn, hid)
        if stored is not None and not auth.verify_password(form.get("old_password") or "", stored):
            auth.limiter.fail(ip_key, hid_key)
            return Response(content=b'{"error": "wrong_password", "message": "Current password is wrong."}',
                            status_code=401, media_type="application/json")
        auth.set_password(conn, hid, new)
        conn.commit()
    auth.limiter.reset(hid_key)
    return json_resp({"ok": True})

@app.post("/api/game/push/register")
async def fcm_register(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    token = form.get("token", "").strip()
    platform = form.get("platform", "android")
    if hid and token:
        with get_db() as conn:
            conn.execute(
                "INSERT INTO fcm_tokens(hid, token, platform, updated_at) VALUES(?,?,?,?) "
                "ON CONFLICT(hid, token) DO UPDATE SET updated_at=excluded.updated_at, platform=excluded.platform",
                (hid, token, platform, utcnow_iso()))
            conn.commit()
    return plain_resp("OK")

# ── Player data ─────────────────────────────────────────────────────────────────

# ── Scanner ─────────────────────────────────────────────────────────────────────

# owner 2026-10-24: players building together may put their mines on exactly the same hex for this
# long after the first mine there was built (anyone, not only friends); after that, and always when
# one of the mines on the hex is your own, overlap is refused
SHARED_HEX_S = 30
SHARED_HEX_M = 1.0             # "the same hex": centres closer than this


GPS_TOLERANCE_M = 15               # allowance for GPS jitter between the app's check and the request

# ── Mine management ─────────────────────────────────────────────────────────────


# ── Map markers ─────────────────────────────────────────────────────────────────


# ── Warehouse ───────────────────────────────────────────────────────────────────

# ── Factories ───────────────────────────────────────────────────────────────────

# ── Special Buildings ────────────────────────────────────────────────────────────

# ── Market ───────────────────────────────────────────────────────────────────────

# ── Activity log ─────────────────────────────────────────────────────────────────

LOG_DAYS = 7


@app.post("/api/game/log")
async def log_get_data(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    try:
        offset = int(form.get("offset", 0))
    except Exception:
        offset = 0
    log_type = form.get("type", "")
    cutoff = (datetime.datetime.utcnow() - datetime.timedelta(days=LOG_DAYS)).isoformat()
    with get_db() as conn:
        # the activity log keeps LOG_DAYS days (owner 2026-10-30: 7)
        conn.execute("DELETE FROM proto_log WHERE created_at<?", (cutoff,))
        if log_type:
            rows = conn.execute(
                "SELECT * FROM proto_log WHERE hid=? AND log_type=? AND created_at>=? ORDER BY created_at DESC LIMIT 100 OFFSET ?",
                (hid, log_type, cutoff, offset)).fetchall()
            total = conn.execute(
                "SELECT COUNT(*) FROM proto_log WHERE hid=? AND log_type=? AND created_at>=?",
                (hid, log_type, cutoff)).fetchone()[0]
        else:
            rows = conn.execute(
                "SELECT * FROM proto_log WHERE hid=? AND created_at>=? ORDER BY created_at DESC LIMIT 100 OFFSET ?",
                (hid, cutoff, offset)).fetchall()
            total = conn.execute(
                "SELECT COUNT(*) FROM proto_log WHERE hid=? AND created_at>=?",
                (hid, cutoff)).fetchone()[0]
        entries = []
        for r in rows:
            data = json.loads(r["data_json"] or "{}")
            for key in ("buyerHID", "sellerHID", "attackerHID", "defenderHID"):
                if isinstance(data.get(key), str):  # never show other players' internal ids
                    data[key] = public_refs(conn, {data[key]}, hid)[data[key]]
            entries.append({"logID": r["log_id"], "type": r["log_type"], "data": data,
                            "ts": r["created_at"]})
    return zlib_resp({
        "entries": entries,
        "total": total,
        "offset": offset,
    })

# ── Items catalog ─────────────────────────────────────────────────────────────────

# ── Leaderboard & Profile ─────────────────────────────────────────────────────────

@app.post("/api/game/player/country")
async def set_country_code(request: Request):
    _, form = await read_form(request)
    hid = hid_from_sid(form.get("sid", ""))
    code = form.get("code", "")[:5]
    if not hid or not code:
        return zlib_resp({"err": 1})
    with get_db() as conn:
        conn.execute("UPDATE players SET country_code=? WHERE hID=?", (code, hid))
        conn.commit()
    return zlib_resp({"err": 0})

# ── News ──────────────────────────────────────────────────────────────────────────

@app.get("/api/v1/health")
async def health():
    """Public liveness check (used by the download page, so any origin may read it)."""
    return JSONResponse({"ok": True, "time": utcnow_iso()},
                        headers={"Access-Control-Allow-Origin": "*", "Cache-Control": "no-store"})

# ── Master field pre-generation (background thread at startup) ────────────────────


# ── Background mine destruction sweeper ──────────────────────────────────────────


# ── FCM push helper (HTTP v1) ─────────────────────────────────────────────────────
# Requires two environment variables (see deploy/.env.example and docs/FIREBASE.md):
#   GOOGLE_APPLICATION_CREDENTIALS=/run/secrets/firebase_sa
#   FIREBASE_PROJECT_ID=your-firebase-project-id
#
# Pushes are silently skipped until a Firebase service account JSON is provided.

_FIREBASE_PROJECT_ID = os.environ.get("FIREBASE_PROJECT_ID", "")
_GOOGLE_CREDS_PATH   = os.environ.get("GOOGLE_APPLICATION_CREDENTIALS", "")
_fcm_credentials = None  # cached google.oauth2 Credentials object

def _get_fcm_token() -> str:
    """Return a valid OAuth2 bearer token for FCM HTTP v1, refreshing if needed."""
    global _fcm_credentials
    if not _FIREBASE_PROJECT_ID or not _GOOGLE_CREDS_PATH:
        return ""
    try:
        from google.oauth2 import service_account
        import google.auth.transport.requests as google_requests
        if _fcm_credentials is None or not _fcm_credentials.valid:
            scopes = ["https://www.googleapis.com/auth/firebase.messaging"]
            _fcm_credentials = service_account.Credentials.from_service_account_file(
                _GOOGLE_CREDS_PATH, scopes=scopes)
        if not _fcm_credentials.valid:
            _fcm_credentials.refresh(google_requests.Request())
        return _fcm_credentials.token or ""
    except Exception:
        return ""

def _send_fcm(token: str, title: str, body: str) -> bool:
    """Send a push notification via FCM HTTP v1 API. Returns True on success."""
    bearer = _get_fcm_token()
    if not bearer:
        return False
    try:
        import urllib.request
        url = f"https://fcm.googleapis.com/v1/projects/{_FIREBASE_PROJECT_ID}/messages:send"
        payload = json.dumps({
            "message": {
                "token": token,
                "notification": {"title": title, "body": body},
                "android": {"priority": "HIGH"},
            }
        }).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "Authorization": f"Bearer {bearer}",
                "Content-Type": "application/json",
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except Exception:
        return False

def _push_to_player(conn, hid: str, title: str, body: str):
    """Send FCM push to all registered tokens for a player."""
    rows = conn.execute("SELECT token FROM fcm_tokens WHERE hid=?", (hid,)).fetchall()
    for row in rows:
        _send_fcm(row["token"], title, body)

# ── Server-side notification sweeper (runs every 30 min) ─────────────────────────


# (chat, private messages and the casino were removed in 0.2.3)

# ── Game systems (server/systems/*) ───────────────────────────────────────────────

import types as _types
import econ
import systems

def public_refs(conn, hids, viewer_hid: str) -> dict:
    """Map internal player ids to what other players may see: the viewer's own id stays as is
    (old clients compare it), everyone else gets their public id. Internal ids must never leak:
    in AUTH_MODE=mixed an id still opens accounts that have no password yet."""
    from systems.players import pid_of
    out = {h: (h if h == viewer_hid else pid_of(conn, h)) for h in hids}
    if conn.in_transaction:
        conn.commit()
    return out

with get_db() as _conn:
    econ.init(_conn)

def _owner_balance_x10_once() -> None:
    """One-time owner decision (2026-10-19): existing companies get 10× their credits, like the new
    starting balance. Runs once per database (scheduler flag), ledgered as owner_balance_x10."""
    with get_db() as c:
        with econ.tx(c):
            if c.execute("SELECT 1 FROM scheduler WHERE name='owner_balance_x10'").fetchone():
                return
            for r in c.execute("SELECT hID, credits FROM players WHERE credits > 0").fetchall():
                econ.credit(c, r[0], int(r[1]) * 9, "owner_balance_x10")
            c.execute("INSERT INTO scheduler(name, last_run) VALUES('owner_balance_x10', ?)", (utcnow_iso(),))

_owner_balance_x10_once()


SYSTEM_HELPERS = _types.SimpleNamespace(
    # what the game systems (server/systems/*) use from here; they add their own (notify, is_banned, ...)
    get_db=get_db, hid_from_sid=hid_from_sid, read_form=read_form, zlib_resp=zlib_resp,
    make_sid=make_sid, create_company=create_company, check_password_login=check_password_login,
    remove_password=remove_password, norm_name=norm_name, add_proto=add_proto, check_travel=check_travel,
    push=_push_to_player, new_id=new_id, record_daily_activity=record_daily_activity,
)
INSTALLED_SYSTEMS = systems.install_all(app, SYSTEM_HELPERS)

# ── Unknown paths ─────────────────────────────────────────────────────────────────
# (owner 2026-10-25: nothing is forwarded to any other server any more)

@app.api_route("/{path:path}", methods=["GET","POST","PUT","DELETE","PATCH","OPTIONS","HEAD"])
async def not_found(request: Request, path: str = ""):
    return Response(content=b'{"error": "not found"}', status_code=404, media_type="application/json")
