"""OpenRes 0.3 Production & Assembly: plants, chains, limits (inputs, electricity, storage),
Tantalum-180m and dark matter."""
import gamedata as g
import main
from helpers import call
from systems import production as pr
from test_company import age, put, setup_hq


def stock(sid):
    return call("/api/v3/state", sid)["stock"]


def set_hq(hid, level):
    with main.get_db() as conn:
        conn.execute("UPDATE co_state SET campus_level=? WHERE hid=?", (level, hid))
        conn.execute("UPDATE players SET credits=? WHERE hID=?", (10**13, hid))
        conn.commit()


def test_build_unlock_and_upgrade():
    hid, sid = setup_hq("pl1", at=(45.30, 16.50))
    assert call("/api/v3/plants/build", sid, key="steel_works")["code"] == "level"
    assert call("/api/v3/plants/build", sid, key="nonsense")["code"] == "bad_input"
    r = call("/api/v3/plants/build", sid, key="sawmill")
    assert r["level"] == 1
    assert call("/api/v3/plants/build", sid, key="sawmill")["code"] == "exists"
    credits = call("/api/v3/state", sid)["credits"]
    assert call("/api/v3/plants/upgrade", sid, key="sawmill")["level"] == 2
    assert call("/api/v3/state", sid)["credits"] == credits - g.factory_upgrade_cost("sawmill", 1)
    p = next(x for x in call("/api/v3/plants", sid)["plants"] if x["key"] == "sawmill")
    assert p["level"] == 2 and p["running"] and p["recipes"][0]["output"] == "lumber"


def test_chain_flows_and_is_limited_by_inputs_power_and_room():
    hid, sid = setup_hq("pl2", at=(45.25, 16.55))
    set_hq(hid, 5)
    for key in ("sawmill", "coal_power", "paper_mill"):
        assert call("/api/v3/plants/build", sid, key=key)["err"] == 0
    inputs, (out, qty), hours, _ = pr.batch("sawmill", 0)
    put(hid, "wood", inputs["wood"] * 3)          # enough for 3 batches
    put(hid, "coal", 10_000)
    age(hid, 10)                                   # time for 10 sawmill batches, but wood for only 3
    st = stock(sid)
    assert abs(st["lumber"] - qty * 3) < 1e-6 and st.get("wood", 0) < 1e-6
    # coal power made electricity, and the paper mill had no wood left to use it on
    assert st["electricity"] > 0
    # no electricity: the paper mill stops even with wood
    call("/api/v3/plants/run", sid, key="coal_power", on=0)
    put(hid, "electricity", 0)
    put(hid, "wood", 10_000)
    call("/api/v3/plants/run", sid, key="sawmill", on=0)
    age(hid, 5)
    assert stock(sid).get("paper", 0) == 0
    # with power it runs at its level's rate
    p_in, (p_out, p_qty), p_h, p_kwh = pr.batch("paper_mill", 0)
    put(hid, "electricity", p_kwh * 1000 * 100)
    age(hid, 2)
    assert abs(stock(sid)["paper"] - p_qty * 2 / p_h) < p_qty * 1e-4     # (plus the milliseconds of the test)


def test_switched_off_plant_does_nothing_and_recipes_switch():
    hid, sid = setup_hq("pl3", at=(45.20, 16.60))
    set_hq(hid, 10)
    call("/api/v3/plants/build", sid, key="textile_mill")
    assert call("/api/v3/plants/recipe", sid, key="textile_mill", recipe=1)["err"] == 0     # wool
    assert call("/api/v3/plants/recipe", sid, key="textile_mill", recipe=5)["code"] == "bad_input"
    put(hid, "wool", 10_000)
    put(hid, "electricity", 10**8)
    call("/api/v3/plants/run", sid, key="textile_mill", on=0)
    age(hid, 3)
    assert stock(sid).get("fabric", 0) == 0
    call("/api/v3/plants/run", sid, key="textile_mill", on=1)
    age(hid, 1)
    assert stock(sid)["fabric"] > 0 and stock(sid)["wool"] < 10_000


def test_tantalum_luxury_and_dark_matter():
    hid, sid = setup_hq("pl4", at=(45.15, 16.65))
    set_hq(hid, 40)
    call("/api/v3/plants/build", sid, key="isotope_lab")
    inputs, (out, qty), hours, kwh = pr.batch("isotope_lab", 0)
    for item, q in inputs.items():
        put(hid, item, q * 2)
    put(hid, "electricity", kwh * 1000 * 2)
    age(hid, hours * 2)
    lux = call("/api/v3/luxury", sid)
    assert abs(lux["producedMg"] - qty * 2) < 1e-3 and abs(lux["heldMg"] - qty * 2) < 1e-3
    assert lux["top"][0]["you"]
    assert call("/api/v3/sell", sid, item="ta180m", qty=1)["code"] == "bad_input"        # untradable
    # dark matter opens only when all 500 supervisors are fully educated
    assert call("/api/v3/darkmatter/invest", sid)["code"] == "closed"
    set_hq(hid, 50)
    call("/api/v3/supervisors", sid)                       # (supervisors are created on level-up)
    with main.get_db() as conn:
        from systems import company as co
        co.ensure_supervisors(conn, hid, 50)
        conn.execute("UPDATE co_supervisors SET edu=4 WHERE hid=?", (hid,))
        conn.commit()
    put(hid, "ta180m", g.dark_matter_cost_mg(1))
    dm = call("/api/v3/darkmatter", sid)
    assert dm["open"] and dm["level"] == 0
    assert call("/api/v3/darkmatter/invest", sid)["level"] == 1
    assert call("/api/v3/darkmatter", sid)["bonus"] == g.DARK_MATTER_BONUS
    assert call("/api/v3/luxury", sid)["investedMg"] == g.dark_matter_cost_mg(1)
