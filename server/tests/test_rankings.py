"""Leaderboards (overall = company value x activity, Campus, countries, Tantalum, output) and the company sheet."""
import json

import econ
import main
from helpers import call, new_player
from systems import rankings


def lux(hid, item, n):
    with main.get_db() as conn:
        conn.execute("INSERT INTO luxury_items(hid, item_id, qty) VALUES(?,?,?) ON CONFLICT(hid, item_id) "
                     "DO UPDATE SET qty=qty+excluded.qty", (hid, item, n))
        conn.commit()


def test_overall_has_no_xp_and_public_ids_only():
    a, sid, _ = new_player("rk1")
    rankings._cache.clear()
    r = call("/api/v1/rank/players", sid)
    assert r["rows"] and all("xp" not in row for row in r["rows"])
    assert a not in json.dumps(r)


def test_resource_ranking_raw_and_products():
    import gamedata as g
    from systems import company as co
    from systems import production
    a, a_sid, _ = new_player("rk2")
    b, _, _ = new_player("rk3")
    with main.get_db() as conn:
        for i in range(3):
            conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, item, quality, built_at) VALUES(?,?,?,?,?,?,?)",
                         (a, 10.0 + i * 0.01, 10.0, "logging_camp", "wood", 100, "2026-01-01"))
        conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, item, quality, built_at) VALUES(?,?,?,?,?,?,?)",
                     (b, 11.0, 10.0, "logging_camp", "wood", 50, "2026-01-01"))
        conn.execute("INSERT INTO co_plants(hid, key, level) VALUES(?,?,?)", (a, "sawmill", 3))
        conn.commit()
    rankings._cache.clear()
    r = call("/api/v1/rank/resource", a_sid, kind="raw", item="wood")
    rows = [x for x in r["rows"] if x["isMe"] or x["name"].startswith("rk3")]
    assert rows[0]["isMe"] and rows[0]["count"] == 3 and rows[0]["perHour"] > rows[1]["perHour"]
    assert rows[0]["perHour"] == round(3 * co.rate_per_hour("logging_camp", "wood", 100), 1)
    f = call("/api/v1/rank/resource", a_sid, kind="product", item="lumber")
    me = next(x for x in f["rows"] if x["isMe"])
    _i, (_o, qty), hours, _k = production.batch("sawmill", 0)
    assert me["perHour"] == round(3 * qty / hours, 1) and me["count"] == 3
    assert r["names"]["wood"] == g.ITEM_NAMES["wood"]
    assert call("/api/v1/rank/resource", a_sid, kind="raw", item="lumber")["code"] == "bad_input"


def test_country_filter_recounts_ranks_and_pages():
    ids = []
    for i in range(3):
        hid, sid, _ = new_player(f"rkc{i}")
        with main.get_db() as conn:
            conn.execute("UPDATE players SET country_code=?, xp=? WHERE hID=?", ("qx" if i != 1 else "yy", 10**9 - i, hid))
            conn.commit()
        ids.append((hid, sid))
    rankings._cache.clear()
    r = call("/api/v1/rank/players", ids[2][1], country=1)
    assert r["countryFilter"] and [x["rank"] for x in r["rows"]] == list(range(1, len(r["rows"]) + 1))
    assert all(x["country"] == "qx" for x in r["rows"]) and r["myRank"] == 2      # #3 overall, #2 in country
    assert len(call("/api/v1/rank/players", ids[2][1])["rows"]) <= rankings.TOP + 1


def test_tantalum_board_ranks_everything_made():
    a, a_sid, _ = new_player("rkt1")
    b, _, _ = new_player("rkt2")
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_luxury(hid, produced, invested) VALUES(?,?,?)", (a, 1500.0, 1000.0))
        conn.execute("INSERT INTO co_luxury(hid, produced, invested) VALUES(?,?,?)", (b, 900.0, 0.0))
        conn.commit()
    rankings._cache.clear()
    r = call("/api/v1/rank/tantalum", a_sid)
    rows = [x for x in r["rows"] if x["isMe"] or x["name"].startswith("rkt2")]
    assert rows[0]["isMe"] and rows[0]["mg"] == 1500.0 and rows[1]["mg"] == 900.0 and r["myMg"] == 1500.0


def _active(hid, days):
    import datetime
    with main.get_db() as conn:
        conn.execute("UPDATE players SET created_at=? WHERE hID=?",
                     ((econ.utcnow() - datetime.timedelta(days=10)).isoformat(), hid))
        conn.execute("DELETE FROM player_activity WHERE hid=?", (hid,))
        for d in range(days):
            day = (econ.utcnow() - datetime.timedelta(days=d)).strftime("%Y-%m-%d")
            conn.execute("INSERT OR IGNORE INTO player_activity(hid, day) VALUES(?,?)", (hid, day))
        conn.commit()


def test_overall_is_value_times_activity():
    a, a_sid, _ = new_player("rkv1", credits=1_000_000)
    b, _, _ = new_player("rkv2", credits=1_000_000)
    with main.get_db() as conn:
        conn.execute("UPDATE players SET xp=4000000 WHERE hID=?", (b,))          # b invested more ...
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?)", (a, "wood", 1000))
        conn.commit()
    _active(a, 10)
    _active(b, 1)                                                              # ... but stopped playing
    rankings._cache.clear()
    rows = {x["name"][:4]: x for x in call("/api/v1/rank/players", a_sid)["rows"] if x["name"].startswith("rkv")}
    import gamedata as g
    from systems import company as co
    v1, v2 = round(1_000_000 + 1000 * g.PRICES["wood"]) - co.START_CREDITS, 5_000_000 - co.START_CREDITS
    assert rows["rkv1"]["score"] == v1 and rows["rkv2"]["score"] == round(v2 * 0.1)
    assert "activity" not in rows["rkv1"] and "value" not in rows["rkv1"]    # hidden from players (owner 2026-11-06)
    assert rows["rkv1"]["rank"] < rows["rkv2"]["rank"]


def test_campus_and_country_boards():
    a, a_sid, _ = new_player("rkm1")
    b, _, _ = new_player("rkm2")
    call("/api/v3/state", a_sid)
    with main.get_db() as conn:
        for hid, lvl, cc in ((a, 12, "qq"), (b, 30, "qq")):
            conn.execute("INSERT INTO co_state(hid, campus_level) VALUES(?,?) ON CONFLICT(hid) DO UPDATE SET "
                         "campus_level=excluded.campus_level", (hid, lvl))
            conn.execute("UPDATE players SET country_code=?, credits=1000000 WHERE hID=?", (cc, hid))   # above the start
        conn.commit()
    _active(a, 10)
    _active(b, 2)                                       # owner 2026-11-06: the level decides, not activity
    rankings._cache.clear()
    rows = {x["name"][:4]: x for x in call("/api/v1/rank/campus", a_sid)["rows"] if x["name"].startswith("rkm")}
    assert rows["rkm1"]["level"] == 12 and rows["rkm2"]["level"] == 30 and rows["rkm2"]["rank"] < rows["rkm1"]["rank"]
    with main.get_db() as conn:                         # the same level: the more active company first
        conn.execute("UPDATE co_state SET campus_level=30 WHERE hid=?", (a,))
        conn.commit()
    rankings._cache.clear()
    rows = {x["name"][:4]: x for x in call("/api/v1/rank/campus", a_sid)["rows"] if x["name"].startswith("rkm")}
    assert rows["rkm1"]["rank"] < rows["rkm2"]["rank"]
    c = call("/api/v1/rank/countries", a_sid)
    qq = next(x for x in c["rows"] if x["country"] == "qq")
    assert qq["companies"] == 2 and qq["isMe"] and c["myRank"] == qq["rank"]


def test_output_all_is_valued_at_prices():
    import gamedata as g
    from systems import company as co
    a, a_sid, _ = new_player("rka1")
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, item, quality, built_at) VALUES(?,?,?,?,?,?,?)",
                     (a, 12.0, 10.0, "logging_camp", "wood", 100, "2026-01-01"))
        conn.commit()
    rankings._cache.clear()
    h = call("/api/v1/rank/hexes", a_sid)
    me = next(x for x in h["rows"] if x["isMe"])
    assert me["hexes"] == 1 and me["items"] == 1
    r = call("/api/v1/rank/resource", a_sid, kind="all")
    me = next(x for x in r["rows"] if x["isMe"])
    assert me["perHour"] == round(co.rate_per_hour("logging_camp", "wood", 100) * g.PRICES["wood"]) and me["count"] == 1


def test_biggest_campus_per_country_for_the_far_map():
    a, a_sid, _ = new_player("tc1")
    b, _, _ = new_player("tc2")
    c, _, _ = new_player("tc3")
    for hid, lvl, cc in ((a, 7, "xa"), (b, 9, "xa"), (c, 3, "xb")):
        with main.get_db() as conn:
            conn.execute("INSERT INTO co_state(hid, campus_level, campus_lat, campus_lng) VALUES(?,?,?,?) "
                         "ON CONFLICT(hid) DO UPDATE SET campus_level=excluded.campus_level, "
                         "campus_lat=excluded.campus_lat, campus_lng=excluded.campus_lng", (hid, lvl, 40.0, 20.0))
            conn.execute("UPDATE players SET country_code=? WHERE hID=?", (cc, hid))
            conn.commit()
    top = {x["country"]: x for x in call("/api/v3/campuses/top", a_sid)["campuses"]}
    assert top["xa"]["level"] == 9 and top["xa"]["name"].startswith("tc2") and not top["xa"]["own"]
    assert top["xb"]["level"] == 3


def test_a_new_company_starts_at_zero():
    """Owner 2026-11-06: the 300 000 start credits don't count, a new company starts at the bottom."""
    from systems import company as co
    hid, sid, _ = new_player("rknew", credits=co.START_CREDITS)
    with main.get_db() as conn:
        assert rankings.company_values(conn, only=hid)[hid] == 0


def test_boards_show_the_top_100_and_your_own_row():
    """Owner 2026-11-06: no pages; the top 100 and, further down, your own row with the gap to the one above."""
    from systems import company as co
    me, sid, _ = new_player("rktop", credits=co.START_CREDITS + 1)
    with main.get_db() as conn:
        for i in range(105):
            h = f"rktop-fill-{i}"
            conn.execute("INSERT OR IGNORE INTO players(hID, company_name, credits, created_at) VALUES(?,?,?,?)",
                         (h, f"rktop fill {i}", co.START_CREDITS + 1_000_000 + i, "2026-01-01"))
            conn.execute("INSERT OR IGNORE INTO player_activity(hid, day) VALUES(?, date('now'))", (h,))
        conn.commit()
    _active(me, 5)
    rankings._cache.clear()
    r = call("/api/v1/rank/players", sid)
    assert "pages" not in r and r["top"] == 100 and r["myRank"] > 100
    ranks = [x["rank"] for x in r["rows"]]
    assert ranks[:100] == list(range(1, 101)) and ranks[-1] == r["myRank"] and r["rows"][-1]["isMe"]
    assert len(r["rows"]) == 101 and r["gap"] is not None and r["gap"] >= 0


def test_your_row_is_there_even_with_nothing_on_the_board():
    """Owner 2026-11-06: Tantalum, hexes, output: your row shows, rank N/A (None) when you have none."""
    hid, sid, name = new_player("rkna")
    rankings._cache.clear()
    for path, extra in [("/api/v1/rank/tantalum", {}), ("/api/v1/rank/hexes", {}),
                        ("/api/v1/rank/resource", {"kind": "all"}), ("/api/v1/rank/resource", {"kind": "raw"}),
                        ("/api/v1/rank/campus", {})]:
        rows = call(path, sid, **extra)["rows"]
        mine = [r for r in rows if r["isMe"]]
        assert len(mine) == 1 and mine[0]["rank"] is None and mine[0]["name"] == name, (path, mine)
