"""Leaderboards (owner 2026-10-31: no XP points any more):

  overall    company value x activity. Value = credits + Central Storage at prices + what was invested, less the
             start credits (a new company starts at 0),
             for good (Campus, plants, storage, hexes, education: the players.xp column counts exactly
             those credits). Activity = share of days played (the last 100 days), so a company that
             stops playing slides down instead of staying on top for ever.
  campus     Campus level; at the same level the more active company first, then the older one.
  hexes      hexes held now (leases run out when a company stops renewing, so it stays current).
  countries  the overall scores of every company of a country added up.
  tantalum   Tantalum-180m put into dark matter research (the endgame).
  output     output per item per hour, or "all": everything a company makes in an hour, valued at
             prices (so an item made in huge quantities doesn't win by numbers alone).
Results are cached for CACHE_S seconds per board so large worlds stay cheap.
"""
from __future__ import annotations

import contextlib
import datetime
import json
import sqlite3
import time

import econ
import gamedata as g
from . import company as co
from . import int_arg
from . import players as social
from . import production

CACHE_S = 300
MAX_ROWS = 100_000      # computed boards are cached in full and paged
TOP = 100               # owner 2026-11-06: every board shows its top 100, no pages, and your own row
ACTIVITY_DAYS = 100


class _Cache:
    """The computed boards: this process's copy, and the shared one every process reads (owner 2026-11-06:
    with many processes, one computes a board every CACHE_S seconds and the others read it)."""

    def __init__(self):
        self.local: dict = {}

    def get(self, key):
        return self.local.get(key)

    def clear(self):
        self.local.clear()
        if _get_db is not None:
            with contextlib.suppress(sqlite3.Error), _get_db() as c:
                c.execute("DELETE FROM rank_cache")
                c.commit()


_cache = _Cache()
_get_db = None           # set by install(): a new connection (the cache is written outside the request's)


def _cached(key, fn):
    """The board `key`: fresh from this process, else from the shared cache, else computed here. While one
    process computes a stale board (it claims it for a minute), the others keep serving the old one."""
    now = time.time()
    hit = _cache.local.get(key)
    if hit and now - hit[0] < CACHE_S:
        return hit[1]
    if _get_db is None:
        val = fn()
        _cache.local[key] = (now, val)
        return val
    row, claimed = None, True
    try:
        with _get_db() as c:
            row = c.execute("SELECT at, data FROM rank_cache WHERE key=?", (key,)).fetchone()
            if row and row[1] != "null" and now - row[0] < CACHE_S:
                val = json.loads(row[1])
                _cache.local[key] = (row[0], val)
                return val
            claimed = c.execute(
                "INSERT INTO rank_cache(key, at, data, claim) VALUES(?, 0, 'null', ?) ON CONFLICT(key) DO UPDATE "
                "SET claim=excluded.claim WHERE rank_cache.claim IS NULL OR rank_cache.claim < ?",
                (key, now, now - 60)).rowcount == 1
            c.commit()
    except sqlite3.Error:                     # the database is busy: compute it here, share it next time
        pass
    if not claimed and row and row[1] != "null":
        val = json.loads(row[1])              # another process is on it: the last one meanwhile
        _cache.local[key] = (now - CACHE_S + 5, val)
        return val
    val = fn()
    done = time.time()
    _cache.local[key] = (done, val)
    with contextlib.suppress(sqlite3.Error), _get_db() as c:
        c.execute("UPDATE rank_cache SET at=?, data=?, claim=NULL WHERE key=?", (done, json.dumps(val), key))
        c.commit()
    return val


def activity_of(conn) -> dict:
    """hid: share of days played (0..1); younger companies count from the day they started."""
    now = datetime.datetime.utcnow()
    today = now.strftime("%Y-%m-%d")
    cutoff = (now - datetime.timedelta(days=ACTIVITY_DAYS)).strftime("%Y-%m-%d")
    act_all = dict(conn.execute("SELECT hid, COUNT(*) FROM player_activity WHERE day<=? GROUP BY hid", (today,)).fetchall())
    act_100 = dict(conn.execute("SELECT hid, COUNT(*) FROM player_activity WHERE day>=? AND day<=? GROUP BY hid",
                                (cutoff, today)).fetchall())
    out = {}
    for hid, created in conn.execute("SELECT hID, created_at FROM players"):
        try:
            age = max(1, (now - datetime.datetime.fromisoformat(created)).days)
        except (TypeError, ValueError):
            age = 1
        out[hid] = min(1.0, act_all.get(hid, 0) / age if age < ACTIVITY_DAYS else act_100.get(hid, 0) / ACTIVITY_DAYS)
    return out


def _unit_price(item) -> float:
    return g.PRICES.get(item, 0) / (1000 if item == g.ENERGY else 1)          # electricity is stored in Wh


def company_values(conn, only: str | None = None) -> dict:
    """hid: credits + Central Storage at prices + credits invested for good, less the start credits (`only`: one
    company)."""
    where, args = (" AND hid=?", (only,)) if only else ("", ())
    stock = {}
    for hid, item, qty in conn.execute("SELECT hid, item, qty FROM co_stock WHERE qty > 0" + where, args):
        if item not in g.UNTRADABLE:
            stock[hid] = stock.get(hid, 0.0) + qty * _unit_price(item)
    # owner 2026-11-06: the start credits don't count, so a new company starts at 0 (at the bottom), not mid-table
    return {hid: max(0.0, max(0.0, credits or 0) + stock.get(hid, 0.0) + (invested or 0) - co.START_CREDITS)
            for hid, credits, invested in conn.execute(
                "SELECT hID, credits, xp FROM players" + (" WHERE hID=?" if only else ""), args)}


def overall_rows(conn):
    """Overall board rows (score, activity %, hid, value, country), best first (cached)."""
    return _cached("overall", lambda: _overall(conn))


def _overall(conn):
    act = activity_of(conn)
    vals = company_values(conn)
    rows = [(round(v * act.get(hid, 0)), round(act.get(hid, 0) * 100), hid, round(v), cc or "")
            for hid, cc in conn.execute("SELECT hID, country_code FROM players") for v in (vals.get(hid, 0),)]
    rows.sort(key=lambda x: -x[0])
    return rows


def campus_rows(conn):
    """(score, activity %, hid, campus level), best first. Owner 2026-11-06: the level decides; activity only
    orders companies at the same level, then the older company first. The score is the level."""
    act = activity_of(conn)
    rows = [(lvl, round(act.get(hid, 0) * 100), hid, lvl, created or "")
            for hid, lvl, created in conn.execute("SELECT c.hid, c.campus_level, p.created_at FROM co_state c "
                                                  "JOIN players p ON p.hID=c.hid WHERE c.campus_level > 0")]
    rows.sort(key=lambda x: (-x[3], -act.get(x[2], 0), x[4]))
    return [r[:4] for r in rows]


# The hex boards add up in the database per (company, operation, item) on idx_co_hexes_agg: a hex's output is
# its quality times a rate of its operation and item, so a sum of qualities is enough (owner 2026-11-06: a
# million hexes in Zagreb took 9 s here, now under 1 s).

def hex_rows(conn):
    """(hexes, distinct items, hid), most hexes first."""
    acc = {}
    for hid, _item, n in conn.execute("SELECT hid, item, COUNT(*) FROM co_hexes WHERE op!='campus' GROUP BY hid, item"):
        v = acc.setdefault(hid, [0, 0])
        v[0] += n
        v[1] += 1
    return sorted(((v[0], v[1], hid) for hid, v in acc.items()), reverse=True)


def country_rows(conn):
    """(score, companies, country) of every country, best first."""
    acc = {}
    for score, _a, _hid, _v, cc in overall_rows(conn):
        if cc and cc != "zz" and score > 0:            # zz: international waters, no country
            v = acc.setdefault(cc, [0, 0])
            v[0] += score
            v[1] += 1
    return sorted(((v[0], v[1], cc) for cc, v in acc.items()), reverse=True)


RAW = sorted(g.raw_items())
PRODUCTS = sorted({recipe[1][0] for _n, _u, _m, recipes in g.FACTORIES.values() for recipe in recipes})


def raw_rows(conn, item):
    """(per hour, hexes, hid) of everyone who makes `item` on hexes, best first."""
    acc = {}
    for hid, op, quality, n in conn.execute("SELECT hid, op, SUM(quality), COUNT(*) FROM co_hexes WHERE item=? "
                                            "GROUP BY hid, op", (item,)):
        v = acc.setdefault(hid, [0.0, 0])
        rate = co.rate_per_hour(op, item, quality)
        v[0] += rate / 1000 if item == g.ENERGY else rate
        v[1] += n
    return sorted(((round(v[0], 1), v[1], hid) for hid, v in acc.items()), reverse=True)


def product_rows(conn, item):
    """(per hour, plant levels, hid) of everyone whose plants make `item`, best first."""
    acc = {}
    for r in conn.execute("SELECT hid, key, level, recipe FROM co_plants"):
        _inputs, (out, qty), hours, _kwh = production.batch(r["key"], r["recipe"])
        if out != item:
            continue
        v = acc.setdefault(r["hid"], [0.0, 0])
        v[0] += r["level"] * qty / hours
        v[1] += r["level"]
    return sorted(((round(v[0], 1), v[1], hid) for hid, v in acc.items()), reverse=True)


def all_rows(conn):
    """(credits per hour, hexes + plant levels, hid): everything made in an hour, valued at prices."""
    acc = {}
    for hid, op, item, quality, n in conn.execute("SELECT hid, op, item, SUM(quality), COUNT(*) FROM co_hexes "
                                                  "WHERE op!='campus' GROUP BY hid, op, item"):
        v = acc.setdefault(hid, [0.0, 0])
        v[0] += co.rate_per_hour(op, item, quality) * _unit_price(item)
        v[1] += n
    for r in conn.execute("SELECT hid, key, level, recipe FROM co_plants"):
        _inputs, (out, qty), hours, _kwh = production.batch(r["key"], r["recipe"])
        if out in g.UNTRADABLE:
            continue
        v = acc.setdefault(r["hid"], [0.0, 0])
        v[0] += r["level"] * qty / hours * g.PRICES.get(out, 0)
        v[1] += r["level"]
    return sorted(((round(v[0]), v[1], hid) for hid, v in acc.items()), reverse=True)


def _gap(rows, me):
    """How much the row at index `me` is behind the one just above it (None at the top or when absent)."""
    if not me:
        return None
    return rows[me - 1][0] - rows[me][0]


def install(api) -> None:
    global _get_db
    _get_db = api.h.get_db
    with _get_db() as c:
        c.execute("CREATE TABLE IF NOT EXISTS rank_cache (key TEXT PRIMARY KEY, at REAL NOT NULL, data TEXT NOT NULL, "
                  "claim REAL)")
        c.commit()
    def refs(conn, hids, viewer):
        return {x: social.public_ref(conn, x) for x in hids}

    def countries(conn):
        return _cached("countries", lambda: {r[0]: (r[1] or "") for r in
                                             conn.execute("SELECT hID, country_code FROM players")})

    def page_of(conn, hid, form, rows, hid_at):
        """Filter to the viewer's country (country=1; ranks count from 1 within it), keep the top TOP, and add the
        viewer's own row when it is further down. `gap`: how far behind the one just above (the board's number)."""
        cc = countries(conn)
        mine_cc = cc.get(hid, "")
        if form.get("country") == "1" and mine_cc:
            rows = [r for r in rows if cc.get(hid_at(r), "") == mine_cc]
        me = next((i for i, r in enumerate(rows) if hid_at(r) == hid), None)
        part = [(i + 1, r) for i, r in enumerate(rows[:TOP])]
        if me is not None and me >= TOP:
            part.append((me + 1, rows[me]))
        meta = {"total": len(rows), "top": TOP, "myRank": None if me is None else me + 1, "myCountry": mine_cc,
                "gap": _gap(rows, me), "countryFilter": form.get("country") == "1" and bool(mine_cc)}
        return part, meta

    def with_me(conn, hid, out, meta, **zero):
        """Your own row is always there (owner 2026-11-06): without a place on this board, rank None (N/A)."""
        if meta.get("myRank") is None and not any(r.get("isMe") for r in out):
            me = refs(conn, [hid], hid).get(hid)
            if me:
                out.append({"rank": None, **me, **zero, "country": countries(conn).get(hid, ""), "isMe": True})
        return out

    @api.endpoint("/api/v1/rank/players")
    def players(conn, hid, form):
        rows = overall_rows(conn)
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        # owner 2026-11-06: activity stays hidden from players (and the value, which would give it away)
        return {"err": 0, **meta, "rows": with_me(conn, hid, [{"rank": n, **rf[r[2]], "score": r[0],
                                            "country": r[4] or "", "isMe": r[2] == hid} for n, r in part], meta, score=0)}

    @api.endpoint("/api/v1/rank/campus")
    def campus(conn, hid, form):
        rows = _cached("campus", lambda: campus_rows(conn))
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        return {"err": 0, **meta, "rows": with_me(conn, hid, [{"rank": n, **rf[r[2]], "score": r[0], "level": r[3],
                                            "country": cc.get(r[2], ""), "isMe": r[2] == hid} for n, r in part],
                                                  meta, score=0, level=0)}

    @api.endpoint("/api/v1/rank/hexes")
    def hexes(conn, hid, form):
        rows = _cached("hexes", lambda: hex_rows(conn))
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        return {"err": 0, **meta, "rows": with_me(conn, hid, [{"rank": n, **rf[r[2]], "hexes": r[0], "items": r[1],
                                            "country": cc.get(r[2], ""), "isMe": r[2] == hid} for n, r in part],
                                                  meta, hexes=0, items=0)}

    @api.endpoint("/api/v1/rank/countries")
    def country_board(conn, hid, form):
        rows = _cached("countries_board", lambda: country_rows(conn))
        mine = countries(conn).get(hid, "")
        me = next((i for i, r in enumerate(rows) if r[2] == mine), None)
        part = list(enumerate(rows[:TOP]))
        if me is not None and me >= TOP:
            part.append((me, rows[me]))
        return {"err": 0, "myCountry": mine, "myRank": None if me is None else me + 1, "total": len(rows), "top": TOP,
                "gap": _gap(rows, me),
                "rows": [{"rank": i + 1, "country": r[2], "score": r[0], "companies": r[1], "isMe": r[2] == mine}
                         for i, r in part] + ([{"rank": None, "country": mine, "score": 0, "companies": 0, "isMe": True}]
                                              if mine and me is None else [])}

    @api.endpoint("/api/v1/rank/tantalum")
    def tantalum(conn, hid, form):
        """Tantalum-180m put into research (mg): owner 2026-11-07, what was invested decides, not what was made
        (the Tantalum tab names the one who made the most). Each row also says how much it made."""
        rows = _cached("tantalum", lambda: [(round(r[2], 3), round(r[1], 3), r[0]) for r in conn.execute(
            "SELECT hid, produced, invested FROM co_luxury WHERE invested > 0 ORDER BY invested DESC LIMIT ?",
            (MAX_ROWS,))])
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        mine = conn.execute("SELECT invested FROM co_luxury WHERE hid=?", (hid,)).fetchone()
        return {"err": 0, **meta, "myMg": round(mine[0], 3) if mine else 0,
                "rows": with_me(conn, hid, [{"rank": n, **rf[r[2]], "mg": r[0], "investedMg": r[0], "producedMg": r[1],
                          "country": cc.get(r[2], ""), "isMe": r[2] == hid} for n, r in part], meta,
                          mg=0, investedMg=0, producedMg=0)}

    @api.endpoint("/api/v1/rank/resource")
    def resource(conn, hid, form):
        kind = (form.get("kind") or "raw").strip()
        options = {"raw": RAW, "product": PRODUCTS}
        if kind == "all":
            rows = _cached("all", lambda: all_rows(conn))
            part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
            rf = refs(conn, [r[2] for _, r in part], hid)
            cc = countries(conn)
            return {"err": 0, **meta, "kind": kind, "item": None, "options": options,
                    "names": {i: g.ITEM_NAMES[i] for i in RAW + PRODUCTS},
                    "rows": with_me(conn, hid, [{"rank": n, **rf[r[2]], "perHour": r[0], "count": r[1],
                              "country": cc.get(r[2], ""), "isMe": r[2] == hid} for n, r in part], meta, perHour=0, count=0)}
        if kind not in options:
            raise econ.GameError("bad_input", "Choose raw materials or products")
        item = (form.get("item") or options[kind][0]).strip()
        if item not in options[kind]:
            raise econ.GameError("bad_input", "Choose an item from the list")
        rows = _cached(f"{kind}:{item}", lambda: (raw_rows if kind == "raw" else product_rows)(conn, item))
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        return {"err": 0, **meta, "kind": kind, "item": item, "options": options,
                "names": {i: g.ITEM_NAMES[i] for i in RAW + PRODUCTS},
                "rows": with_me(conn, hid, [{"rank": n, **rf[r[2]], "perHour": r[0], "count": r[1],
                          "country": cc.get(r[2], ""), "isMe": r[2] == hid} for n, r in part], meta, perHour=0, count=0)}
