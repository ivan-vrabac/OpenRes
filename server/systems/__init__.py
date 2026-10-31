"""Game systems added after the core game (the 0.2.3 company and production, profiles, market,
quests, rankings, achievements).

Each module exposes `install(api: Api)`. Endpoints are plain functions `fn(conn, hid, form) -> dict`
registered with `api.endpoint(path)`; the framework authenticates the session, opens a DB
connection in a worker thread, converts `econ.GameError` into an error response and compresses
the result like the legacy endpoints (zlib JSON).
"""
from __future__ import annotations

import collections
import threading
import time
import types

from fastapi import Request
from starlette.concurrency import run_in_threadpool

import econ


# Actions that change the game: at most N per player in a window of S seconds (a script can't hammer
# them; a person never gets near). path: (N, S)
LIMITS = {
    "/api/v3/survey": (20, 60), "/api/v3/hex/build": (30, 60), "/api/v3/hex/renew": (30, 60),
    "/api/v3/hex/cancel": (20, 60), "/api/v3/hex/switch": (30, 60), "/api/v3/sell": (30, 60),
    "/api/v1/market/order": (20, 60), "/api/v1/market/edit": (20, 60), "/api/v1/market/take": (30, 60),
    "/api/v1/market/system": (30, 60), "/api/v1/market/cancel": (20, 60),
    "/api/v3/plants/build": (20, 60), "/api/v3/plants/upgrade": (60, 60), "/api/v3/plants/run": (60, 60),
    "/api/v3/plants/recipe": (30, 60), "/api/v3/supervisors/assign": (60, 60),
    "/api/v3/supervisors/unassign": (60, 60), "/api/v3/education/start": (30, 60),
    "/api/v3/campus/upgrade": (20, 60), "/api/v3/storage/upgrade": (20, 60),
    "/api/v1/quests/claim": (20, 60), "/api/v1/account/rename": (5, 3600),
}
_recent: dict = collections.defaultdict(collections.deque)      # (hid, path): times of recent calls
_recent_lock = threading.Lock()


def too_often(hid: str, path: str, now: float | None = None) -> bool:
    """True when `hid` already used `path` its LIMITS[path] times in the window (then not counted)."""
    lim = LIMITS.get(path)
    if not lim or not hid:
        return False
    n, window = lim
    now = time.monotonic() if now is None else now
    with _recent_lock:
        q = _recent[(hid, path)]
        while q and q[0] <= now - window:
            q.popleft()
        if len(q) >= n:
            return True
        q.append(now)
        return False


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

                def work():
                    with h.get_db() as conn:
                        try:
                            out = fn(conn, hid, form)
                            if conn.in_transaction:
                                conn.commit()
                            return out
                        except econ.GameError as e:
                            if conn.in_transaction:
                                conn.rollback()
                            return e.resp()
                return h.zlib_resp(await run_in_threadpool(work))
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
SYSTEMS = ["legal", "identity", "company", "production", "players", "notify", "moderation", "market", "quests", "rankings", "achievements", "account"]


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
