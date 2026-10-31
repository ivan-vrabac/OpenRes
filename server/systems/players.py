"""Players as other players see them: a random public id (pid, never the internal hID), a short
public reference and the public company profile. (Chat, private messages and contacts were removed
in 0.2.3; this is what other systems such as rankings still need.)"""
from __future__ import annotations

import datetime
import secrets

import econ


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS player_public (
            hid TEXT PRIMARY KEY,
            pid TEXT UNIQUE NOT NULL
        );
        CREATE TABLE IF NOT EXISTS achievements (
            hid   TEXT NOT NULL,
            code  TEXT NOT NULL,
            title TEXT NOT NULL,
            ts    TEXT NOT NULL,
            PRIMARY KEY (hid, code)
        );
    """)
    conn.commit()


# ── public ids ───────────────────────────────────────────────────────────────

def pid_of(conn, hid: str) -> str:
    r = conn.execute("SELECT pid FROM player_public WHERE hid=?", (hid,)).fetchone()
    if r:
        return r[0]
    pid = secrets.token_hex(8)
    conn.execute("INSERT OR IGNORE INTO player_public(hid, pid) VALUES(?,?)", (hid, pid))
    return conn.execute("SELECT pid FROM player_public WHERE hid=?", (hid,)).fetchone()[0]


def hid_of(conn, pid: str) -> str:
    r = conn.execute("SELECT hid FROM player_public WHERE pid=?", ((pid or "").strip(),)).fetchone()
    if not r:
        raise econ.GameError("no_player", "Player not found")
    return r[0]


# ── profile ──────────────────────────────────────────────────────────────────

def _rank(conn, value, sql) -> int:
    return conn.execute(sql, (value,)).fetchone()[0] + 1


def public_profile(conn, h, viewer_hid: str, target_hid: str) -> dict:
    p = conn.execute("SELECT * FROM players WHERE hID=?", (target_hid,)).fetchone()
    if not p:
        raise econ.GameError("no_player", "Player not found")
    import gamedata as g
    from . import company as co
    st = conn.execute("SELECT * FROM co_state WHERE hid=?", (target_hid,)).fetchone()
    campus = st["campus_level"] if st else 0
    hexes = conn.execute("SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus'", (target_hid,)).fetchone()[0]
    value = sum(q * g.PRICES.get(i, 0) / (1000 if i == g.ENERGY else 1)
                for i, q in co.income_per_hour(conn, target_hid, st).items()) if st else 0
    ta = conn.execute("SELECT produced FROM co_luxury WHERE hid=?", (target_hid,)).fetchone() \
        if _has_table(conn, "co_luxury") else None
    ta_mg = ta[0] if ta else 0.0
    # owner 2026-10-23: rank by points (the overall leaderboard), never by XP
    from . import rankings
    board = rankings.overall_rows(conn)
    rank_points = next((i + 1 for i, r in enumerate(board) if r[2] == target_hid), len(board) + 1)
    rank_hexes = _rank(conn, hexes, "SELECT COUNT(*) FROM (SELECT hid, COUNT(*) c FROM co_hexes WHERE op!='campus' "
                                    "GROUP BY hid) WHERE c > ?")
    rank_ta = _rank(conn, ta_mg, "SELECT COUNT(*) FROM co_luxury WHERE produced > ?") if ta_mg > 0 else None
    rel = set()
    ach = [{"code": r[0], "title": r[1], "ts": r[2]} for r in conn.execute(
        "SELECT code, title, ts FROM achievements WHERE hid=? ORDER BY ts DESC LIMIT 50", (target_hid,))]
    out = {
        "pid": pid_of(conn, target_hid),
        "name": p["company_name"],
        "level": p["level"] or 1,
        "campusLevel": campus,
        "campusStage": g.campus_stage(campus) if campus else None,
        "hexes": hexes,
        "valuePerHour": round(value),
        "tantalumMg": round(ta_mg, 3),
        "country": p["country_code"] if "country_code" in p.keys() else None,
        "memberSince": (p["created_at"] or "")[:10],
        "rankPoints": rank_points,
        "rankHexes": rank_hexes,
        "rankTantalum": rank_ta,
        "achievements": ach,
        "isMe": viewer_hid == target_hid,
        "relations": sorted(rel),
    }
    # public company sheet: age, hexes by item, plants
    try:
        created = datetime.datetime.fromisoformat(p["created_at"])
        out["ageDays"] = max(0, (econ.utcnow() - created).days)
    except (TypeError, ValueError):
        out["ageDays"] = None
    out["hexesByItem"] = [{"item": r[0], "name": g.ITEM_NAMES.get(r[0], r[0]), "count": r[1]} for r in conn.execute(
        "SELECT item, COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus' GROUP BY item ORDER BY COUNT(*) DESC",
        (target_hid,))]
    out["plants"] = [{"key": r[0], "name": g.FACTORIES[r[0]][0], "level": r[1]} for r in conn.execute(
        "SELECT key, level FROM co_plants WHERE hid=? ORDER BY level DESC, key", (target_hid,)) if r[0] in g.FACTORIES]
    try:                              # achievement stars (systems/achievements.py: "<key>_<tier>")
        from . import achievements as _ach
        codes = {f"{k}_{i}" for k in _ach.DEFS for i in (1, 2, 3)}
        out["stars"] = sum(1 for r in conn.execute("SELECT code FROM achievements WHERE hid=?", (target_hid,))
                           if r[0] in codes)
        out["maxStars"] = 3 * len(_ach.DEFS)
    except Exception:
        pass
    if viewer_hid == target_hid:  # private extras only for yourself
        out["credits"] = p["credits"]
    return out


def _has_table(conn, name) -> bool:
    return conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)).fetchone() is not None


def _summary(conn, hid) -> dict:
    p = conn.execute("SELECT company_name, level FROM players WHERE hID=?", (hid,)).fetchone()
    st = conn.execute("SELECT campus_level FROM co_state WHERE hid=?", (hid,)).fetchone() \
        if _has_table(conn, "co_state") else None
    return {"pid": pid_of(conn, hid), "name": p[0] if p else "?", "level": (p[1] if p else 1) or 1,
            "campusLevel": st[0] if st else 0}


def public_ref(conn, hid) -> dict:
    """Public reference to a player for other systems (no internal id)."""
    return _summary(conn, hid)


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    @api.endpoint("/api/v1/social/profile")
    def profile(conn, hid, form):
        """A company's public profile (yours with private extras)."""
        pid = (form.get("pid") or "").strip()
        target = hid_of(conn, pid) if pid else hid
        return {"err": 0, "profile": public_profile(conn, h, hid, target)}
