"""Leaderboards (owner 2026-10-31: no XP points any more):

  overall    company value x activity. Value = credits + Central Storage at prices + what was invested
             for good (Campus, plants, storage, hexes, education: the players.xp column counts exactly
             those credits). Activity = share of days played (the last 100 days), so a company that
             stops playing slides down instead of staying on top for ever.
  campus     Campus level x activity (the same weighting: no hall of fame of the earliest players).
  hexes      hexes held now (leases run out when a company stops renewing, so it stays current).
  countries  the overall scores of every company of a country added up.
  tantalum   Tantalum-180m made in total (the endgame).
  output     output per item per hour, or "all": everything a company makes in an hour, valued at
             prices (so an item made in huge quantities doesn't win by numbers alone).
Results are cached for CACHE_S seconds per board so large worlds stay cheap.
"""
from __future__ import annotations

import datetime
import time

import econ
import gamedata as g
from . import company as co
from . import int_arg
from . import players as social
from . import production

CACHE_S = 300
MAX_ROWS = 100_000      # computed boards are cached in full and paged
PAGE = 100
ACTIVITY_DAYS = 100
_cache: dict = {}


def _cached(key, fn):
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < CACHE_S:
        return hit[1]
    val = fn()
    _cache[key] = (time.time(), val)
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
    """hid: credits + Central Storage at prices + credits invested for good (`only`: one company)."""
    where, args = (" AND hid=?", (only,)) if only else ("", ())
    stock = {}
    for hid, item, qty in conn.execute("SELECT hid, item, qty FROM co_stock WHERE qty > 0" + where, args):
        if item not in g.UNTRADABLE:
            stock[hid] = stock.get(hid, 0.0) + qty * _unit_price(item)
    return {hid: max(0.0, credits or 0) + stock.get(hid, 0.0) + (invested or 0)
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
    """(score, activity %, hid, campus level), best first: the level weighted by activity."""
    act = activity_of(conn)
    rows = [(round(lvl * act.get(hid, 0), 2), round(act.get(hid, 0) * 100), hid, lvl)
            for hid, lvl in conn.execute("SELECT hid, campus_level FROM co_state WHERE campus_level > 0")]
    rows.sort(key=lambda x: (-x[0], -x[3]))
    return rows


def hex_rows(conn):
    """(hexes, distinct items, hid), most hexes first."""
    return sorted(((n, items, hid) for hid, n, items in conn.execute(
        "SELECT hid, COUNT(*), COUNT(DISTINCT item) FROM co_hexes WHERE op!='campus' GROUP BY hid")), reverse=True)


def country_rows(conn):
    """(score, companies, country) of every country, best first."""
    acc = {}
    for score, _a, _hid, _v, cc in overall_rows(conn):
        if cc and score > 0:
            v = acc.setdefault(cc, [0, 0])
            v[0] += score
            v[1] += 1
    return sorted(((v[0], v[1], cc) for cc, v in acc.items()), reverse=True)


RAW = sorted(g.raw_items())
PRODUCTS = sorted({recipe[1][0] for _n, _u, _m, recipes in g.FACTORIES.values() for recipe in recipes})


def raw_rows(conn, item):
    """(per hour, hexes, hid) of everyone who makes `item` on hexes, best first."""
    acc = {}
    for r in conn.execute("SELECT hid, op, quality FROM co_hexes WHERE item=?", (item,)):
        v = acc.setdefault(r["hid"], [0.0, 0])
        rate = co.rate_per_hour(r["op"], item, r["quality"])
        v[0] += rate / 1000 if item == g.ENERGY else rate
        v[1] += 1
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
    for r in conn.execute("SELECT hid, op, item, quality FROM co_hexes WHERE op!='campus'"):
        v = acc.setdefault(r["hid"], [0.0, 0])
        v[0] += co.rate_per_hour(r["op"], r["item"], r["quality"]) * _unit_price(r["item"])
        v[1] += 1
    for r in conn.execute("SELECT hid, key, level, recipe FROM co_plants"):
        _inputs, (out, qty), hours, _kwh = production.batch(r["key"], r["recipe"])
        if out in g.UNTRADABLE:
            continue
        v = acc.setdefault(r["hid"], [0.0, 0])
        v[0] += r["level"] * qty / hours * g.PRICES.get(out, 0)
        v[1] += r["level"]
    return sorted(((round(v[0]), v[1], hid) for hid, v in acc.items()), reverse=True)


def install(api) -> None:
    def refs(conn, hids, viewer):
        return {x: social.public_ref(conn, x) for x in hids}

    def countries(conn):
        return _cached("countries", lambda: {r[0]: (r[1] or "") for r in
                                             conn.execute("SELECT hID, country_code FROM players")})

    def page_of(conn, hid, form, rows, hid_at):
        """Filter to the viewer's country (country=1), rank 1..n AFTER filtering, cut one page."""
        cc = countries(conn)
        mine_cc = cc.get(hid, "")
        if form.get("country") == "1" and mine_cc:
            rows = [r for r in rows if cc.get(hid_at(r), "") == mine_cc]
        page = int_arg(form, "page", 0, 0, 10**6)
        me = next((i for i, r in enumerate(rows) if hid_at(r) == hid), None)
        part = rows[page * PAGE:(page + 1) * PAGE]
        meta = {"page": page, "pages": max(1, -(-len(rows) // PAGE)), "total": len(rows),
                "myRank": None if me is None else me + 1, "myCountry": mine_cc,
                "countryFilter": form.get("country") == "1" and bool(mine_cc)}
        return [(page * PAGE + i + 1, r) for i, r in enumerate(part)], meta

    @api.endpoint("/api/v1/rank/players")
    def players(conn, hid, form):
        rows = overall_rows(conn)
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        return {"err": 0, **meta, "rows": [{"rank": n, **rf[r[2]], "score": r[0], "activity": r[1], "value": r[3],
                                            "country": r[4] or "", "isMe": r[2] == hid} for n, r in part]}

    @api.endpoint("/api/v1/rank/campus")
    def campus(conn, hid, form):
        rows = _cached("campus", lambda: campus_rows(conn))
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        return {"err": 0, **meta, "rows": [{"rank": n, **rf[r[2]], "score": r[0], "activity": r[1], "level": r[3],
                                            "country": cc.get(r[2], ""), "isMe": r[2] == hid} for n, r in part]}

    @api.endpoint("/api/v1/rank/hexes")
    def hexes(conn, hid, form):
        rows = _cached("hexes", lambda: hex_rows(conn))
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        return {"err": 0, **meta, "rows": [{"rank": n, **rf[r[2]], "hexes": r[0], "items": r[1],
                                            "country": cc.get(r[2], ""), "isMe": r[2] == hid} for n, r in part]}

    @api.endpoint("/api/v1/rank/countries")
    def country_board(conn, hid, form):
        rows = _cached("countries_board", lambda: country_rows(conn))
        mine = countries(conn).get(hid, "")
        me = next((i for i, r in enumerate(rows) if r[2] == mine), None)
        return {"err": 0, "myCountry": mine, "myRank": None if me is None else me + 1, "total": len(rows),
                "rows": [{"rank": i + 1, "country": r[2], "score": r[0], "companies": r[1], "isMe": r[2] == mine}
                         for i, r in enumerate(rows[:300])]}

    @api.endpoint("/api/v1/rank/tantalum")
    def tantalum(conn, hid, form):
        """Tantalum-180m made in total (mg), the luxury of 0.2.3; what went into research still counts."""
        rows = _cached("tantalum", lambda: [(round(r[1], 3), round(r[2], 3), r[0]) for r in conn.execute(
            "SELECT hid, produced, invested FROM co_luxury WHERE produced > 0 ORDER BY produced DESC LIMIT ?",
            (MAX_ROWS,))])
        part, meta = page_of(conn, hid, form, rows, lambda r: r[2])
        rf = refs(conn, [r[2] for _, r in part], hid)
        cc = countries(conn)
        mine = conn.execute("SELECT produced FROM co_luxury WHERE hid=?", (hid,)).fetchone()
        return {"err": 0, **meta, "myMg": round(mine[0], 3) if mine else 0,
                "rows": [{"rank": n, **rf[r[2]], "mg": r[0], "investedMg": r[1], "country": cc.get(r[2], ""),
                          "isMe": r[2] == hid} for n, r in part]}

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
                    "rows": [{"rank": n, **rf[r[2]], "perHour": r[0], "count": r[1], "country": cc.get(r[2], ""),
                              "isMe": r[2] == hid} for n, r in part]}
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
                "rows": [{"rank": n, **rf[r[2]], "perHour": r[0], "count": r[1], "country": cc.get(r[2], ""),
                          "isMe": r[2] == hid} for n, r in part]}
