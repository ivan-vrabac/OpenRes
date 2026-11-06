"""Game systems added after the core game (the 0.2.3 company and production, profiles, market,
quests, rankings, achievements).

Each module exposes `install(api: Api)`. Endpoints are plain functions `fn(conn, hid, form) -> dict`
registered with `api.endpoint(path)`; the framework authenticates the session, opens a DB
connection in a worker thread, converts `econ.GameError` into an error response and compresses
the result like the legacy endpoints (zlib JSON).
"""
from __future__ import annotations

import asyncio
import os
import sqlite3
import threading
import types
import weakref

import anyio
from fastapi import Request

import procs

import econ

from . import integrity


# Actions that change the game: at most N per player in a window of S seconds (a script can't hammer
# them; a person never gets near). path: (N, S)
LIMITS = {
    "/api/v3/survey": (40, 60), "/api/v3/hex/build": (30, 60), "/api/v3/hex/renew": (30, 60),
    "/api/v3/hex/cancel": (20, 60), "/api/v3/hex/switch": (30, 60), "/api/v3/sell": (30, 60),
    "/api/v1/market/order": (20, 60), "/api/v1/market/edit": (20, 60), "/api/v1/market/take": (30, 60),
    "/api/v1/market/system": (30, 60), "/api/v1/market/cancel": (20, 60),
    "/api/v3/plants/build": (20, 60), "/api/v3/plants/upgrade": (60, 60), "/api/v3/plants/run": (60, 60),
    "/api/v3/plants/recipe": (30, 60), "/api/v3/supervisors/assign": (60, 60),
    "/api/v3/supervisors/unassign": (60, 60), "/api/v3/education/start": (30, 60), "/api/v3/education/cancel": (30, 60), "/api/v3/education/order": (30, 60),
    "/api/v3/campus/upgrade": (20, 60), "/api/v3/storage/upgrade": (20, 60),
    "/api/v1/quests/claim": (20, 60), "/api/v1/account/rename": (5, 3600),
    "/api/v3/integrity/report": (6, 3600),
}
_countries: dict = {}                     # hid: the country last saved, so a request only reads it


def see_country(conn, hid: str, header: str | None) -> None:
    """Cloudflare says where a request comes from (CF-IPCountry, from the IP address): that is the company's
    country until it has a Campus (then the Campus's place decides, owner 2026-11-06). XX is unknown, T1 is
    Tor; without the header (dev server, tests) what is saved stays."""
    cc = (header or "").strip().lower()
    if not hid or len(cc) != 2 or not cc.isalpha() or cc in ("xx", "t1") or _countries.get(hid) == cc:
        return
    try:
        conn.execute("UPDATE players SET country_code=? WHERE hID=? AND COALESCE(country_code,'')!=? AND NOT EXISTS("
                     "SELECT 1 FROM co_state WHERE hid=? AND campus_cc IS NOT NULL)", (cc, hid, cc, hid))
        conn.commit()
        _countries[hid] = cc
    except sqlite3.OperationalError:              # busy: the next request tries again
        conn.rollback()


def too_often(hid: str, path: str, now: float | None = None) -> bool:
    """True when `hid` already used `path` its LIMITS[path] times in the window (then not counted). Counted
    across all the server's processes (procs.too_often)."""
    lim = LIMITS.get(path)
    if not lim or not hid:
        return False
    return procs.too_often(hid, path, lim[0], lim[1], now)


# Database work runs in threads, at most DB_THREADS at once per process (owner 2026-11-06): Python runs one
# thread at a time, and many threads reading rows slow each other down badly; the CPUs are used by running
# many processes instead (serve.py).
DB_THREADS = int(os.environ.get("DB_THREADS", "4"))
# one limit per event loop: a limiter belongs to the loop that made it, and a request on another loop (tests
# call from several threads, each with its own loop) would wait on it for ever (CI hung on Linux, 2026-11-07)
_limiters: "weakref.WeakKeyDictionary" = weakref.WeakKeyDictionary()


def _db_limiter():
    loop = asyncio.get_running_loop()
    lim = _limiters.get(loop)
    if lim is None:
        lim = _limiters[loop] = anyio.CapacityLimiter(DB_THREADS)
    return lim


class Api:
    def __init__(self, app, helpers: types.SimpleNamespace):
        self.app = app
        self.h = helpers

    def endpoint(self, path: str, *, feature: str | None = None, auth: bool = True):
        h = self.h

        def deco(fn):
            async def handler(request: Request):
                _, form = await h.read_form(request)
                hid = h.hid_from_sid(form.get("sid", "")) if auth else ""
                if auth and not hid:
                    return h.zlib_resp({"err": 1, "code": "auth", "msg": "Please sign in again."})
                if feature and not econ.feature(feature):
                    return h.zlib_resp({"err": 1, "code": "disabled", "msg": "This feature is not enabled."})
                if too_often(hid, path):
                    return h.zlib_resp({"err": 1, "code": "rate_limited", "msg": "Slow down a little and try again."})

                country = request.headers.get("cf-ipcountry")

                def work():
                    with h.get_db() as conn:
                        see_country(conn, hid, country)
                        try:
                            if path in integrity.GUARDED:
                                integrity.require(conn, hid)
                            out = fn(conn, hid, form)
                            if conn.in_transaction:
                                conn.commit()
                            return out
                        except econ.GameError as e:
                            if conn.in_transaction:
                                conn.rollback()
                            sig = getattr(e, "signal", None)          # a refusal that is also a cheat signal
                            if sig and hid:
                                try:
                                    from . import moderation
                                    with econ.tx(conn):
                                        moderation.signal(conn, hid, *sig)
                                except Exception:
                                    pass
                            return e.resp()
                return h.zlib_resp(await anyio.to_thread.run_sync(work, limiter=_db_limiter()))
            handler.__name__ = fn.__name__
            self.app.add_api_route(path, handler, methods=["POST"])
            return fn
        return deco


def install_all(app, helpers) -> list[str]:
    """Register every system's endpoints. Returns the module names installed."""
    import importlib
    api = Api(app, helpers)
    installed = []
    for name in SYSTEMS:
        mod = importlib.import_module(f"{__name__}.{name}")
        mod.install(api)
        installed.append(name)
    return installed


# Order matters only for documentation; modules are independent.
SYSTEMS = ["legal", "identity", "integrity", "company", "production", "players", "notify", "moderation", "market", "quests", "rankings", "achievements", "account"]


def int_arg(form, name, default=None, lo=None, hi=None) -> int:
    try:
        v = int(float(form.get(name, default)))
    except (TypeError, ValueError):
        raise econ.GameError("bad_input", f"Invalid {name}")
    if lo is not None and v < lo or hi is not None and v > hi:
        raise econ.GameError("bad_input", f"{name} out of range")
    return v


def float_arg(form, name, default=None, lo=None, hi=None) -> float:
    try:
        v = float(form.get(name, default))
    except (TypeError, ValueError):
        raise econ.GameError("bad_input", f"Invalid {name}")
    if v != v or v in (float("inf"), float("-inf")):
        raise econ.GameError("bad_input", f"Invalid {name}")
    if lo is not None and v < lo or hi is not None and v > hi:
        raise econ.GameError("bad_input", f"{name} out of range")
    return v
