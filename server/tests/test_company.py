"""OpenRes 0.3 company: Campus compound, survey, building hexes on the new map, production, leases,
selling."""
import base64
import datetime
import math

import gamedata as g
import main
import world
from helpers import call, new_player
from systems import company as co

BASE = (45.8131, 15.9775)


def find(item, near=BASE, step=0.0004, tries=4000):
    """A point near `near` where `item` occurs (searching outwards on a spiral)."""
    for k in range(tries):
        r, a = step * math.sqrt(k), k * 2.4
        lat, lng = near[0] + r * math.cos(a), near[1] + r * math.sin(a)
        if int(world.quality(item, lat, lng)) > 20:
            return lat, lng
    raise AssertionError(f"no {item} found")


def campus_level(hid, lv):
    with main.get_db() as conn:
        conn.execute("UPDATE co_state SET campus_level=? WHERE hid=?", (lv, hid))
        conn.commit()


def setup_hq(prefix, at=BASE):
    hid, sid, _ = new_player(prefix)
    st = call("/api/v3/state", sid)
    assert st["err"] == 0 and st["campus"] is None and st["credits"] == co.START_CREDITS
    assert call("/api/v3/campus/place", sid, lat=at[0], lng=at[1], plat=at[0], plng=at[1])["err"] == 0
    return hid, sid


def age(hid, hours):
    """Move the company's clock back: as if `hours` passed."""
    def back(s):
        return (datetime.datetime.fromisoformat(s) - datetime.timedelta(hours=hours)).isoformat() if s else s
    with main.get_db() as conn:
        r = conn.execute("SELECT last_collect, last_visit FROM co_state WHERE hid=?", (hid,)).fetchone()
        conn.execute("UPDATE co_state SET last_collect=?, last_visit=? WHERE hid=?",
                     (back(r[0]), back(r[1]), hid))
        conn.commit()


def set_lease(hex_id, days_left):
    with main.get_db() as conn:
        conn.execute("UPDATE co_hexes SET lease_until=? WHERE id=?",
                     ((datetime.datetime.utcnow() + datetime.timedelta(days=days_left)).isoformat(), hex_id))
        conn.commit()


def put(hid, item, q):
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) "
                     "DO UPDATE SET qty=excluded.qty", (hid, item, q))
        conn.commit()


def test_campus_takes_seven_hexes_and_blocks_others():
    hid, sid = setup_hq("hq1", at=(45.70, 16.10))
    st = call("/api/v3/state", sid)
    assert st["campus"]["level"] == 1 and st["campus"]["stage"] == "Temporary camp" and st["supervisors"] == 10
    assert call("/api/v3/campus/place", sid, lat=45.70, lng=16.10, plat=45.70, plng=16.10)["code"] == "has_campus"
    sid2 = new_player("hq2")[1]
    assert call("/api/v3/campus/place", sid2, lat=45.70, lng=16.1002, plat=45.70, plng=16.1002)["code"] == "overlap"
    view = call("/api/v3/map", sid, south=45.699, west=16.099, north=45.701, east=16.101)
    assert sum(1 for x in view["hexes"] if x["op"] == "campus" and x["own"]) == 7


def test_build_produce_sell_and_rules():
    spot = find("wood")
    hid, sid = setup_hq("bld", at=(spot[0] + 0.01, spot[1]))
    info = call("/api/v3/hex/info", sid, lat=spot[0], lng=spot[1])
    assert info["options"]["logging_camp"]["wood"]["unlocked"]
    far = call("/api/v3/hex/build", sid, lat=spot[0], lng=spot[1], plat=spot[0] + 0.01, plng=spot[1],
               op="logging_camp", item="wood")
    assert far["code"] == "range"
    r = call("/api/v3/hex/build", sid, lat=spot[0], lng=spot[1], plat=spot[0], plng=spot[1], op="logging_camp", item="wood")
    assert r["err"] == 0 and r["quality"] > 20
    assert call("/api/v3/state", sid)["credits"] == co.START_CREDITS - g.hex_build_cost("wood")
    # no wheat in a forest, iron needs Campus level 5, and you can't stack two of your own hexes
    assert call("/api/v3/hex/build", sid, lat=spot[0], lng=spot[1], plat=spot[0], plng=spot[1],
                op="farm", item="wheat")["code"] in ("no_resource", "overlap")
    iron = find("iron_ore")
    assert call("/api/v3/hex/build", sid, lat=iron[0], lng=iron[1], plat=iron[0], plng=iron[1],
                op="mine", item="iron_ore")["code"] == "level"
    # ten hours later: wood in storage at the hex's rate
    age(hid, 10)
    st = call("/api/v3/state", sid)
    expected = g.raw_items()["wood"][2] * r["quality"] / 100 * 10
    assert abs(st["stock"]["wood"] - expected) < expected * 0.02
    sold = call("/api/v3/sell", sid, item="wood", qty=int(expected))
    from systems import market
    with main.get_db() as conn:
        rate = market.tax_rate(conn, "wood")
    v = int(int(expected) * g.PRICES["wood"])
    assert sold["credits"] == v - round(v * rate)                     # the seller pays the sales tax
    assert call("/api/v3/sell", sid, item="wood", qty=10_000)["code"] == "stock"


def test_lease_renew_switch_and_expiry():
    spot = find("wheat", near=(45.72, 16.02))         # (wheat is everywhere on land: a spot of its own)
    hid, sid = setup_hq("lse", at=(spot[0] + 0.01, spot[1]))
    r = call("/api/v3/hex/build", sid, lat=spot[0], lng=spot[1], plat=spot[0], plng=spot[1], op="farm", item="wheat")
    assert r["err"] == 0
    # not on the same day; then the price grows with the days used, full from day 30
    assert call("/api/v3/hex/renew", sid, ids=str(r["id"]))["code"] == "too_soon"
    for days_left, share in ((80, 10 / 30), (30, 1.0), (2, 1.0)):
        set_lease(r["id"], days_left)
        ren = call("/api/v3/hex/renew", sid, ids=str(r["id"]))
        assert ren["renewed"] == 1 and abs(ren["paid"] - g.lease_cost("wheat") * share) <= 2
        d = call("/api/v3/hex/detail", sid, id=r["id"])["hex"]
        assert abs(d["leaseDays"] - 90) < 0.01 and d["renewInHours"] > 23        # back to 90 days
    # the map shows the lease only when it's critical (last 30 days)
    box = dict(south=spot[0] - 0.0001, west=spot[1] - 0.0001, north=spot[0] + 0.0001, east=spot[1] + 0.0001)
    assert "leaseDays" not in next(x for x in call("/api/v3/map", sid, **box)["hexes"] if x["id"] == r["id"])
    set_lease(r["id"], 12)
    assert round(next(x for x in call("/api/v3/map", sid, **box)["hexes"] if x["id"] == r["id"])["leaseDays"]) == 12
    # switching to another crop that grows here costs a lease renewal
    opts = call("/api/v3/hex/info", sid, lat=spot[0], lng=spot[1])["options"]["farm"]
    other = next((k for k, v in opts.items() if k != "wheat" and v["unlocked"]), None)
    if other:
        assert call("/api/v3/hex/switch", sid, id=r["id"], item=other)["err"] == 0
    # an expired lease: the government takes the hex back
    with main.get_db() as conn:
        conn.execute("UPDATE co_hexes SET lease_until=? WHERE id=?",
                     ((datetime.datetime.utcnow() - datetime.timedelta(hours=1)).isoformat(), r["id"]))
        conn.commit()
    assert call("/api/v3/state", sid)["hexes"] == 0


def test_survey_tax_wait_and_map():
    hid, sid = setup_hq("srv", at=(45.60, 16.20))
    assert call("/api/v3/survey", sid, lat=45.6, lng=16.2, radius=200)["code"] == "radius"    # Campus 1: 100 m
    campus_level(hid, 10)
    assert call("/api/v3/survey", sid, lat=45.6, lng=16.2, radius=2000)["code"] == "radius"   # Campus 10: 1 km
    r = call("/api/v3/survey", sid, lat=45.6, lng=16.2, radius=1000)
    assert r["err"] == 0 and r["tax"] == g.survey_tax(1000)
    assert call("/api/v3/survey", sid, lat=45.6, lng=16.2, radius=500)["err"] == 0          # no waiting
    m = call("/api/v3/survey/map", sid, what="land")
    vals = base64.b64decode(m["values"])
    assert m["step"] == 4 and m["n"] == 251 and len(vals) == 251 ** 2 and set(vals) <= {0, 1, 2, 3, 4}   # 4 m pixels; 0: outside
    assert call("/api/v3/survey/map", sid, what="nonsense")["code"] == "bad_input"


def test_weekly_visit_restores_efficiency():
    hid, sid = setup_hq("vis", at=(45.55, 16.25))
    age(hid, 24 * 15)                                   # two weeks without a visit
    assert call("/api/v3/state", sid)["campus"]["efficiency"] == 0.8
    assert call("/api/v3/campus/visit", sid, lat=45.56, lng=16.25)["code"] == "range"
    assert call("/api/v3/campus/visit", sid, lat=45.5501, lng=16.25)["err"] == 0
    assert call("/api/v3/state", sid)["campus"]["efficiency"] == 1.0


def test_campus_and_storage_upgrades():
    hid, sid = setup_hq("upg", at=(45.50, 16.30))
    need = g.campus_upgrade(1)
    assert call("/api/v3/campus/upgrade", sid)["code"] == "materials"
    for item, q in need["materials"].items():
        put(hid, item, q)
    r = call("/api/v3/campus/upgrade", sid)
    assert r["level"] == 2 and r["supervisors"] == 20
    st = call("/api/v3/state", sid)
    assert st["credits"] == co.START_CREDITS - need["credits"] and not any(st["stock"].get(i) for i in need["materials"])
    assert call("/api/v3/supervisors", sid)["total"] == 20
    assert call("/api/v3/state", sid)["storage"]["nextCost"] == g.storage_upgrade_cost(1)
    s = call("/api/v3/storage/upgrade", sid)
    assert s["level"] == 2 and s["capacity"] == g.storage_capacity(2)
    assert call("/api/v3/state", sid)["storage"]["nextCapacity"] == g.storage_capacity(3)
    lv = call("/api/v3/campus/levels", sid)
    assert lv["level"] == 2 and len(lv["levels"]) == g.CAMPUS_MAX and lv["levels"][0]["cost"] is None
    assert lv["levels"][1]["cost"] == need and lv["levels"][5]["stage"] == "Small business premises"
    assert "sawmill" in lv["levels"][0]["plants"] and lv["levels"][4]["tiers"] == [2]


def test_supervisors_assign_and_education_queue():
    spot = find("wood", near=(45.45, 16.35))
    hid, sid = setup_hq("sup", at=(spot[0] + 0.01, spot[1]))
    r = call("/api/v3/hex/build", sid, lat=spot[0], lng=spot[1], plat=spot[0], plng=spot[1], op="logging_camp", item="wood")
    assert call("/api/v3/supervisors/assign", sid, hex=r["id"])["err"] == 0
    sups = call("/api/v3/supervisors", sid)
    assert sups["assigned"] == 1 and sups["byStep"] == [10, 0, 0, 0, 0] and sups["slots"] == 1
    on_hex = next(s for s in sups["supervisors"] if s["hex"] == r["id"])
    other = next(s for s in sups["supervisors"] if s["hex"] is None)
    # swapping: the other supervisor takes the hex, the first goes back to the Campus
    assert call("/api/v3/supervisors/assign", sid, sup=other["id"], hex=r["id"])["err"] == 0
    sups = call("/api/v3/supervisors", sid)
    assert next(s for s in sups["supervisors"] if s["id"] == on_hex["id"])["hex"] is None
    # education needs books; one queue slot at Campus level 1
    assert call("/api/v3/education/start", sid, sup=other["id"])["code"] == "stock"
    put(hid, "books", 100)
    e = call("/api/v3/education/start", sid, sup=other["id"])
    assert e["step"] == 1
    assert call("/api/v3/education/start", sid, sup=on_hex["id"])["code"] == "queue"
    # once finished, the supervisor has the course and boosts the hex
    with main.get_db() as conn:
        conn.execute("UPDATE co_education SET finish_at=? WHERE hid=?",
                     ((datetime.datetime.utcnow() - datetime.timedelta(seconds=1)).isoformat(), hid))
        conn.commit()
    age(hid, 10)
    st = call("/api/v3/state", sid)
    base = g.raw_items()["wood"][2] * r["quality"] / 100
    assert abs(st["incomePerHour"]["wood"] - base * (1 + g.EDUCATION[1][1])) < 0.01
    assert call("/api/v3/supervisors", sid)["byStep"][1] == 1
    # releasing the hex sends its supervisor back to the Campus
    call("/api/v3/hex/cancel", sid, ids=str(r["id"]))
    assert call("/api/v3/supervisors", sid)["assigned"] == 0


def test_cancel_refund_bulk_cooldown_and_list():
    spots = []
    p = find("wood", near=(45.40, 16.40))
    hid, sid = setup_hq("cnl", at=(p[0] + 0.01, p[1]))
    for k in range(3):
        q = find("wood", near=(p[0] + 0.003 * k, p[1]))
        r = call("/api/v3/hex/build", sid, lat=q[0], lng=q[1], plat=q[0], plng=q[1], op="logging_camp", item="wood")
        assert r["err"] == 0, r
        spots.append(r["id"])
    lst = call("/api/v3/hex/list", sid, sort="value")
    assert lst["total"] == 3 and len(lst["hexes"]) == 3 and "cancelRefund" in lst["hexes"][0]
    # one hex: 30 % of the remaining lease comes back (full 90 days left right after building)
    before = call("/api/v3/state", sid)["credits"]
    c = call("/api/v3/hex/cancel", sid, ids=str(spots[0]))
    assert c["cancelled"] == 1 and abs(c["refund"] - g.lease_cost("wood") * 0.3) <= 2
    assert call("/api/v3/state", sid)["credits"] == before + c["refund"]
    # several at once, then again within 5 s: refused
    with main.get_db() as conn:
        conn.execute("UPDATE co_state SET bulk_cancel=NULL WHERE hid=?", (hid,))
        conn.commit()
    assert call("/api/v3/hex/cancel", sid, ids=f"{spots[1]},{spots[2]}")["cancelled"] == 2
    assert call("/api/v3/hex/cancel", sid, ids=f"{spots[1]},{spots[2]}")["code"] == "wait"
    assert call("/api/v3/state", sid)["hexes"] == 0


def test_catalog_campuses_and_dots():
    spot = find("wood", near=(45.35, 16.45))
    hid, sid = setup_hq("cat", at=(spot[0] + 0.01, spot[1]))
    c = call("/api/v3/catalog", sid)
    assert c["items"]["iron_ore"]["name"] == "Iron ore" and not c["items"]["ta180m"]["tradable"]
    assert len(c["campusStages"]) == 5 and c["plants"]["sawmill"]["unlock"] == 1
    hqs = call("/api/v3/map", sid, detail=0, south=spot[0] - 0.1, west=spot[1] - 0.1, north=spot[0] + 0.1, east=spot[1] + 0.1)
    assert any(h["own"] and h["level"] == 1 for h in hqs["campuses"])
    call("/api/v3/hex/build", sid, lat=spot[0], lng=spot[1], plat=spot[0], plng=spot[1], op="logging_camp", item="wood")
    box = dict(south=spot[0] - 0.01, west=spot[1] - 0.01, north=spot[0] + 0.01, east=spot[1] + 0.01)
    dots = call("/api/v3/map", sid, detail=0, **box)["dots"]
    assert list(zip(dots[::2], dots[1::2])).count((round(spot[0], 6), round(spot[1], 6))) == 1


def test_campus_hexes_touch_edge_to_edge_and_survey_is_round():
    from systems import company as c
    cells = c.compound_cells(45.0, 16.0)
    for i in range(7):
        for j in range(i + 1, 7):
            d = c.dist_m(*cells[i], *cells[j])
            assert d >= c.hex_min_dist(*cells[i], *cells[j]) - 0.2        # no two overlap
    hid, sid = setup_hq("rnd", at=(45.05, 16.05))
    campus_level(hid, 5)
    call("/api/v3/survey", sid, lat=45.05, lng=16.05, radius=500)
    m = call("/api/v3/survey/map", sid, what="land")
    v = base64.b64decode(m["values"])
    n = m["n"]
    assert v[0] == 0 and v[n - 1] == 0 and v[n * n - 1] == 0 and v[(n // 2) * n + n // 2] != 0   # corners cut off


def test_heatmap_and_build_check_agree():
    """The survey picture's centre pixel and the build check give the same quality (1.2.3 rule)."""
    hid, sid = setup_hq("agr", at=(45.62, 16.12))
    campus_level(hid, 2)
    for item in ("iron_ore", "stone", "wood", "coal"):
        spot = find(item, near=(45.6, 16.1))
        call("/api/v3/survey", sid, lat=spot[0], lng=spot[1], radius=200)
        m = call("/api/v3/survey/map", sid, what=item)
        n = m["n"]
        centre = base64.b64decode(m["values"])[(n // 2) * n + n // 2]
        clat, clng = (m["south"] + m["north"]) / 2, (m["west"] + m["east"]) / 2
        info = call("/api/v3/hex/info", sid, lat=clat, lng=clng)["options"]
        op = g.raw_items()[item][0]
        assert abs(info[op][item]["quality"] - centre) <= 1, (item, info[op][item]["quality"], centre)


def test_login_streak_grows_and_resets():
    hid, sid = setup_hq("streak", at=(45.80, 16.20))
    s = call("/api/v3/streak", sid)
    assert s["day"] == 1 and not s["claimed"] and s["credits"] == g.streak_reward(1)
    before = call("/api/v3/state", sid)["credits"]
    r = call("/api/v3/streak/claim", sid)
    assert r["day"] == 1 and r["materials"] == {"books": 10}
    st = call("/api/v3/state", sid)
    assert st["credits"] == before + g.streak_reward(1) and st["stock"]["books"] == 10
    assert call("/api/v3/streak/claim", sid)["code"] == "claimed"
    yesterday = (co.utcnow() - datetime.timedelta(days=1)).date().isoformat()
    with main.get_db() as conn:                      # claimed yesterday as day 6: today is day 7
        conn.execute("UPDATE co_state SET streak_day=6, streak_last=? WHERE hid=?", (yesterday, hid))
        conn.commit()
    s = call("/api/v3/streak", sid)
    assert s["day"] == 7 and s["credits"] == g.streak_reward(7) and s["materials"] == {"books": 50}
    long_ago = (co.utcnow() - datetime.timedelta(days=2)).date().isoformat()
    with main.get_db() as conn:                      # a missed day: back to day 1
        conn.execute("UPDATE co_state SET streak_day=20, streak_last=? WHERE hid=?", (long_ago, hid))
        conn.commit()
    assert call("/api/v3/streak", sid)["day"] == 1


def test_campus_move_takes_a_day_can_be_cancelled_and_once_a_month():
    hid, sid = setup_hq("mover", at=(45.90, 16.30))
    other = new_player("blocker")[1]
    to = (45.905, 16.30)
    r = call("/api/v3/campus/move", sid, lat=to[0], lng=to[1], plat=to[0], plng=to[1])
    assert r["err"] == 0 and r["moving"]["lat"] == to[0]
    assert call("/api/v3/campus/move", sid, lat=to[0] + 0.01, lng=to[1], plat=to[0] + 0.01, plng=to[1])["code"] == "moving"
    # the new place is taken while the Campus moves
    assert call("/api/v3/campus/place", other, lat=to[0], lng=to[1] + 0.0002, plat=to[0], plng=to[1] + 0.0002)["code"] == "overlap"
    # a cancelled move doesn't count: another place right away
    assert call("/api/v3/campus/move/cancel", sid)["err"] == 0
    assert call("/api/v3/state", sid)["campus"]["moving"] is None
    assert call("/api/v3/campus/move", sid, lat=to[0], lng=to[1], plat=to[0], plng=to[1])["err"] == 0
    with main.get_db() as conn:                      # a day later it has moved
        conn.execute("UPDATE co_moves SET started_at=? WHERE hid=?",
                     ((co.utcnow() - datetime.timedelta(hours=25)).isoformat(), hid))
        conn.commit()
    c = call("/api/v3/state", sid)["campus"]
    assert c["lat"] == to[0] and c["moving"] is None and c["nextMove"]
    assert call("/api/v3/map", sid, south=to[0] - 0.01, west=to[1] - 0.01, north=to[0] + 0.01, east=to[1] + 0.01)["moves"] == []
    with main.get_db() as conn:
        cells = conn.execute("SELECT lat FROM co_hexes WHERE hid=? AND op='campus'", (hid,)).fetchall()
    assert len(cells) == 7 and all(abs(x[0] - to[0]) < 0.001 for x in cells)
    assert call("/api/v3/campus/move", sid, lat=45.90, lng=16.30, plat=45.90, plng=16.30)["code"] == "too_soon"


def test_supervisors_manual_assign_and_unassign():
    spot = find("wood", near=(45.42, 16.38))
    hid, sid = setup_hq("sup2", at=(spot[0] + 0.01, spot[1]))
    a = call("/api/v3/hex/build", sid, lat=spot[0], lng=spot[1], plat=spot[0], plng=spot[1], op="logging_camp", item="wood")
    assert a["err"] == 0
    sups = call("/api/v3/supervisors", sid)["supervisors"]
    with main.get_db() as conn:                       # one supervisor has a Master's
        conn.execute("UPDATE co_supervisors SET edu=4 WHERE id=?", (sups[-1]["id"],))
        conn.commit()
    assert call("/api/v3/supervisors/assign", sid, sup=sups[0]["id"], hex=a["id"])["err"] == 0
    assert call("/api/v3/supervisors/unassign", sid, hex=a["id"])["err"] == 0
    assert call("/api/v3/hex/detail", sid, id=a["id"])["hex"]["edu"] is None
    assert call("/api/v3/supervisors/assign", sid, hex=a["id"])["err"] == 0          # the best free one
    assert call("/api/v3/hex/detail", sid, id=a["id"])["hex"]["edu"] == 4
    assert call("/api/v3/catalog", sid)["education"][0]["name"] == "Untrained"


def test_storage_is_one_total_for_all_items():
    hid, sid = setup_hq("stot", at=(45.33, 16.33))
    cap = g.storage_capacity(1)
    with main.get_db() as conn:
        assert co.add_stock(conn, hid, "wood", cap - 1000, 1) == cap - 1000
        assert co.add_stock(conn, hid, "clay", 5000, 1) == 1000                  # only what is left fits
        assert co.room(conn, hid, 1, g.ENERGY) == 0
        assert co.add_stock(conn, hid, "ta180m", 50, 1) == 50                    # kept apart, never counts
        conn.commit()
    st = call("/api/v3/state", sid)["storage"]
    assert st["capacity"] == cap and abs(st["used"] - cap) < 1e-6


def test_me_says_who_is_signed_in_and_counts_the_day():
    hid, sid, name = new_player("meq", credits=12345)
    with main.get_db() as conn:
        conn.execute("DELETE FROM player_activity WHERE hid=?", (hid,))
        conn.commit()
    r = call("/api/v3/me", sid)
    assert r["err"] == 0 and r["hID"] == hid and r["name"] == name and r["credits"] == 12345
    with main.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM player_activity WHERE hid=?", (hid,)).fetchone()[0] == 1


def test_map_gives_hexes_and_campuses_in_one_answer():
    hid, sid, _ = new_player("mapone")
    call("/api/v3/state", sid)
    assert call("/api/v3/campus/place", sid, lat=11.0, lng=11.0, plat=11.0, plng=11.0)["err"] == 0
    box = dict(south=10.999, west=10.999, north=11.001, east=11.001)
    close = call("/api/v3/map", sid, **box)
    assert [c["own"] for c in close["campuses"]] == [True] and close["more"] is False
    assert sum(h["op"] == "campus" for h in close["hexes"]) == 7 and "dots" not in close
    far = call("/api/v3/map", sid, detail=0, south=-80, west=-170, north=80, east=170)
    assert any(c["own"] for c in far["campuses"]) and "hexes" not in far   # a wide area is fine for dots
    assert len(far["dots"]) // 2 >= 7                                      # a Campus is clouds too: 7 hexes
    assert call("/api/v3/map", sid, south=-80, west=-170, north=80, east=170)["code"] == "too_big"


def test_map_always_includes_your_own_campus(monkeypatch):
    import systems.company as co
    hid, sid, _ = new_player("mapown")
    other, osid, _ = new_player("mapbig")
    for s_ in (sid, osid):
        call("/api/v3/state", s_)
    assert call("/api/v3/campus/place", sid, lat=12.0, lng=12.0, plat=12.0, plng=12.0)["err"] == 0
    assert call("/api/v3/campus/place", osid, lat=12.01, lng=12.0, plat=12.01, plng=12.0)["err"] == 0
    with main.get_db() as conn:
        conn.execute("UPDATE co_state SET campus_level=30 WHERE hid=?", (other,))
        conn.commit()
    monkeypatch.setattr(co, "MAP_CAMPUSES", 1)
    got = call("/api/v3/map", sid, detail=0, south=11.9, west=11.9, north=12.1, east=12.1)
    assert [c["own"] for c in got["campuses"]] == [True] and got["more"] is True


def test_a_campus_goes_anywhere_in_reach_like_a_hex():
    hid, sid, _ = new_player("reach")
    call("/api/v3/state", sid)
    # 0.0012 degrees north is 134 m: too far. 0.0008 is 89 m: fine, and the Campus goes there
    assert call("/api/v3/campus/place", sid, lat=13.0012, lng=13.0, plat=13.0, plng=13.0)["code"] == "range"
    assert call("/api/v3/campus/place", sid, lat=13.0008, lng=13.0, plat=13.0, plng=13.0)["err"] == 0
    assert call("/api/v3/state", sid)["campus"]["lat"] == 13.0008


def test_a_campus_moves_only_within_reach_like_a_hex():
    hid, sid = setup_hq("reachmove", at=(14.0, 14.0))
    assert call("/api/v3/campus/move", sid, lat=14.0012, lng=14.0, plat=14.0, plng=14.0)["code"] == "range"
    r = call("/api/v3/campus/move", sid, lat=14.0008, lng=14.0, plat=14.0, plng=14.0)
    assert r["err"] == 0 and r["moving"]["lat"] == 14.0008                 # may overlap where it stands now


def test_a_moving_campus_holds_both_places_and_shows_its_site():
    hid, sid = setup_hq("site", at=(15.0, 15.0))
    other = new_player("siteother")[1]
    to = (15.0008, 15.0)
    assert call("/api/v3/campus/move", sid, lat=to[0], lng=to[1], plat=15.0, plng=15.0)["err"] == 0
    box = dict(south=14.99, west=14.99, north=15.01, east=15.01)
    seen = call("/api/v3/map", other, **box)
    assert [(m["lat"], m["own"]) for m in seen["moves"]] == [(to[0], False)] and seen["moves"][0]["name"]
    assert sum(h["op"] == "campus" for h in seen["hexes"]) == 14                 # 7 old + 7 new, both taken
    assert len(call("/api/v3/map", other, detail=0, **box)["dots"]) // 2 == 14   # both are clouds too
    for spot in ((15.0, 15.0), to):                                              # the old place and the new
        assert call("/api/v3/campus/place", other, lat=spot[0], lng=spot[1],
                    plat=spot[0], plng=spot[1])["code"] == "overlap"
    assert call("/api/v3/campus/move/cancel", sid)["err"] == 0
    assert call("/api/v3/map", other, **box)["moves"] == []                      # the site is gone again
