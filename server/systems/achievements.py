"""Achievements: three tiers each, computed on the server from the player's real data and
recorded once per tier in the `achievements` table (code "<key>_<tier>"). 0.2.3: the list follows
the new game (Campus, hexes, plants, supervisors, Tantalum-180m, dark matter, surveys, trades).
"""
from __future__ import annotations

import datetime

import econ

# key: (title, description, (tier thresholds), unit)
DEFS = {
    "campus":       ("Campus", "Reach Campus level", (10, 25, 50), ""),
    "age":          ("Veteran", "Account age", (100, 180, 365), "days"),
    "balance":      ("Tycoon", "Account balance", (100_000_000, 10_000_000_000, 500_000_000_000), "credits"),
    "value":        ("High score", "Company value", (100_000_000, 10_000_000_000, 1_000_000_000_000), "credits"),
    "hexes":        ("Landowner", "Hexes leased", (25, 250, 2500), "hexes"),
    "plants":       ("Industrialist", "Total plant levels", (10, 100, 500), "levels"),
    "masters":      ("Academy", "Supervisors with a Master's", (10, 100, 500), "supervisors"),
    "tantalum":     ("Isotope hunter", "Tantalum-180m made", (1_000, 100_000, 1_000_000), "mg"),
    "dark_matter":  ("Dark matter", "Dark matter research level", (1, 10, 50), ""),
    "surveys":      ("Surveyor", "Government surveys", (10, 100, 1000), "surveys"),
    "trader":       ("Trader", "Market trades", (10, 100, 1000), "trades"),
    "storage":      ("Storekeeper", "Central Storage level", (10, 20, 30), ""),
    "streak":       ("Quest solver", "Daily quest streak", (7, 30, 90), "days"),
}
TIER_NAMES = ("First star", "Second star", "Third star")
# short score label shown as "<label>: value / target"
LABELS = {
    "campus": "Campus level", "age": "Days", "balance": "Credits", "value": "Value", "hexes": "Hexes",
    "plants": "Plant levels", "masters": "Master's", "tantalum": "mg", "dark_matter": "Research level",
    "surveys": "Surveys", "trader": "Trades", "storage": "Storage level", "streak": "Streak days",
}


def _one(conn, sql, args=()):
    try:
        r = conn.execute(sql, args).fetchone()
    except Exception:          # table of a disabled system may not exist
        return 0
    return (r[0] or 0) if r else 0


def metrics(conn, h, hid) -> dict:
    p = conn.execute("SELECT * FROM players WHERE hID=?", (hid,)).fetchone()
    st = conn.execute("SELECT campus_level, storage_level, dm_level FROM co_state WHERE hid=?", (hid,)).fetchone()
    now = econ.utcnow()
    try:
        age = max(0, (now - datetime.datetime.fromisoformat(p["created_at"])).days)
    except (TypeError, ValueError):
        age = 0
    from . import rankings
    value = rankings.company_values(conn, hid).get(hid, 0)       # the overall board's value (before activity)
    return {
        "campus": st["campus_level"] if st else 0,
        "age": age,
        "balance": int(p["credits"] or 0),
        "value": int(value),
        "hexes": _one(conn, "SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus'", (hid,)),
        "plants": _one(conn, "SELECT SUM(level) FROM co_plants WHERE hid=?", (hid,)),
        "masters": _one(conn, "SELECT COUNT(*) FROM co_supervisors WHERE hid=? AND edu>=4", (hid,)),
        "tantalum": int(_one(conn, "SELECT produced FROM co_luxury WHERE hid=?", (hid,))),
        "dark_matter": st["dm_level"] if st else 0,
        "surveys": _one(conn, "SELECT COUNT(*) FROM game_events WHERE hid=? AND type='survey'", (hid,)),
        "trader": _one(conn, "SELECT COUNT(*) FROM market_trades WHERE buyer_hid=? OR seller_hid=?", (hid, hid)),
        "storage": st["storage_level"] if st else 1,
        "streak": max(_one(conn, "SELECT MAX(length) FROM streak_rewards WHERE hid=? AND every=1", (hid,)), 0),
    }


def check(conn, h, hid) -> list:
    """Record newly reached tiers (inside the caller's tx). Returns the new ones."""
    m = metrics(conn, h, hid)
    new = []
    now = econ.utcnow_iso()
    for key, (title, _, tiers, _) in DEFS.items():
        for i, t in enumerate(tiers):
            if m[key] >= t:
                cur = conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                                   (hid, f"{key}_{i + 1}", f"{title}: {TIER_NAMES[i]}", now))
                if cur.rowcount == 1:
                    new.append({"key": key, "tier": i + 1, "title": title})
    return new


def install(api) -> None:
    h = api.h

    @api.endpoint("/api/v1/achievements")
    def achievements(conn, hid, form):
        """Your achievements, or another player's (pid=..., public) — only your own are updated."""
        new = []
        pid = (form.get("pid") or "").strip()
        if pid:
            from . import players as social
            target = social.hid_of(conn, pid)            # raises no_player
        else:
            target = hid
        if target == hid:
            with econ.tx(conn):
                new = check(conn, h, hid)
        hid = target
        m = metrics(conn, h, hid)
        got = {r[0]: r[1] for r in conn.execute("SELECT code, ts FROM achievements WHERE hid=?", (hid,))}
        out = []
        for key, (title, desc, tiers, unit) in DEFS.items():
            stars = sum(1 for i in range(len(tiers)) if f"{key}_{i + 1}" in got)
            nxt = next((t for t in tiers if m[key] < t), None)
            out.append({"key": key, "title": title, "description": desc, "unit": unit, "label": LABELS[key],
                        "value": m[key],
                        "tiers": list(tiers), "stars": stars, "next": nxt,
                        "unlockedAt": [got.get(f"{key}_{i + 1}") for i in range(len(tiers))]})
        # by name, the same as in Play Games
        earned = [f"{title}: {TIER_NAMES[i]}" for key, (title, _, tiers, _) in DEFS.items()
                  for i in range(len(tiers)) if f"{key}_{i + 1}" in got]
        return {"err": 0, "achievements": out, "new": new, "earned": earned,
                "stars": sum(a["stars"] for a in out), "maxStars": 3 * len(out)}
