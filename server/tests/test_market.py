"""Market on the 0.2.3 items: system trade, buy orders only (one per item, edit/cancel), selling by
filling a buy order, escrow, the sellers' sales tax per item, room in Central Storage, whole units,
concurrency."""
import threading
import uuid

import gamedata as g
import main
from helpers import call, credits, new_player
from systems import market
from systems.market import TAX_MAX, TAX_MIN, TAX_RATE, sys_buy

M = "/api/v1/market/"
CLAY, GOLD, WOOL = "clay", "gold_ore", "wool"


def rate(item):
    """Today's sales tax of an item (fixed for the day)."""
    with main.get_db() as conn:
        r = market.tax_rate(conn, item)
        conn.commit()
    return r


def net(value, item):
    """What a seller keeps of `value` after the sales tax."""
    return value - round(value * rate(item))


def player(prefix, cr=0):
    hid, sid, _ = new_player(prefix)
    call("/api/v3/state", sid)                       # creates the company (and its start credits)
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=? WHERE hID=?", (cr, hid))
        conn.commit()
    return hid, sid


def put(hid, item, q):
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) "
                     "DO UPDATE SET qty=excluded.qty", (hid, item, q))
        conn.commit()


def have(hid, item):
    with main.get_db() as conn:
        r = conn.execute("SELECT qty FROM co_stock WHERE hid=? AND item=?", (hid, item)).fetchone()
    return r[0] if r else 0


def test_system_trade_prices_and_restrictions():
    hid, sid = player("sys", 1_000_000)
    put(hid, CLAY, 1000)
    r = call(M + "system", sid, side="sell", item=CLAY, qty=1000)
    assert r["credits"] == net(round(1000 * g.PRICES[CLAY]), CLAY) and have(hid, CLAY) == 0     # seller pays tax
    r = call(M + "system", sid, side="buy", item=CLAY, qty=100)
    value = round(100 * sys_buy(CLAY))
    assert r["cost"] == value and r["tax"] == 0 and have(hid, CLAY) == 100                  # buying: no tax
    for banned in ("ta180m", "electricity"):
        assert call(M + "system", sid, side="buy", item=banned, qty=1)["code"] == "restricted"
        assert call(M + "order", sid, item=banned, qty=1, price=10)["code"] == "restricted"
    assert call(M + "system", sid, side="sell", item=CLAY, qty=999999)["code"] == "stock"
    assert call(M + "system", sid, side="buy", item=CLAY, qty=-5)["code"] == "bad_input"
    assert call(M + "system", sid, side="buy", item=CLAY, qty=g.storage_capacity(1))["code"] == "storage_full"


def test_a_system_buy_with_fit_takes_what_fits():
    hid, sid = player("fit", cr=10**10)
    free = call(M + "book", sid, item="wood")["freeSpace"]
    put(hid, "clay", free - 100)                                   # goods came in after the page was opened
    assert call(M + "system", sid, side="buy", item="wood", qty=500)["code"] == "storage_full"
    got = call(M + "system", sid, side="buy", item="wood", qty=500, fit=1)
    assert got["err"] == 0 and got["qty"] == 100
    assert got["cost"] == round(100 * call(M + "book", sid, item="wood")["systemBuy"])   # paid for what came
    assert call(M + "system", sid, side="buy", item="wood", qty=500, fit=1)["code"] == "storage_full"   # now full


def test_overview_lists_tradable_items():
    hid, sid = player("ov")
    put(hid, GOLD, 7)
    items = {i["item"]: i for i in call(M + "overview", sid)["items"]}
    assert "ta180m" not in items and "electricity" not in items
    assert items[GOLD]["owned"] == 7 and items[GOLD]["systemBuy"] == sys_buy(GOLD)


def test_sell_orders_cannot_be_placed():
    hid, sid = player("nosell")
    put(hid, GOLD, 10)
    assert call(M + "order", sid, side="sell", item=GOLD, qty=10, price=450)["code"] == "bad_input"
    assert have(hid, GOLD) == 10


def test_buy_order_escrow_tax_fill_and_refund():
    b_hid, b_sid = player("buyer", 1_000_000)
    s_hid, s_sid = player("seller", 0)
    price = g.PRICES[GOLD] * 1.2
    q = call(M + "quote", b_sid, action="buy_order", item=GOLD, qty=100, price=price)
    value = round(100 * price)
    assert q == {"err": 0, "value": value, "tax": 0, "total": value, "taxRate": 0}        # buying is tax-free
    r = call(M + "order", b_sid, item=GOLD, qty=100, price=price)
    assert r["escrow"] == value and credits(b_hid) == 1_000_000 - value
    put(s_hid, GOLD, 60)
    r = call(M + "take", s_sid, orderID=r["orderID"], qty=60)           # the seller pays the sales tax
    assert r["value"] == round(60 * price) and credits(s_hid) == net(round(60 * price), GOLD)
    assert have(b_hid, GOLD) == 60
    mine = call(M + "mine", b_sid)["orders"][0]
    assert mine["qtyOpen"] == 40 and mine["item"] == GOLD
    r = call(M + "cancel", b_sid, orderID=mine["id"])
    assert credits(b_hid) == 1_000_000 - round(60 * price)


def test_one_order_per_item_edit_and_priority():
    a_hid, a_sid = player("onea", 10_000_000)
    b_hid, b_sid = player("oneb", 10_000_000)
    p = g.PRICES[GOLD]
    oa = call(M + "order", a_sid, item=GOLD, qty=10, price=p * 1.05)["orderID"]
    assert call(M + "order", a_sid, item=GOLD, qty=5, price=p * 1.06)["code"] == "duplicate"
    assert call(M + "order", b_sid, item=GOLD, qty=10, price=p - 1)["code"] == "price_too_low"
    call(M + "order", b_sid, item=GOLD, qty=10, price=p * 1.05)
    book = call(M + "book", b_sid, item=GOLD)
    same = [x for x in book["bids"] if abs(x["price"] - round(p * 1.05, 2)) < 1e-9]
    assert same[0]["id"] == oa                                     # same price: older first
    assert book["myOrder"] and book["freeSpace"] > 0
    assert call(M + "edit", a_sid, orderID=oa, qty=20, price=p * 1.1)["err"] == 0
    assert call(M + "book", b_sid, item=GOLD)["bids"][0]["id"] == oa       # higher price on top


def test_bid_cap_room_own_orders_and_idempotency():
    a_hid, a_sid = player("capa", 10_000_000)
    b_hid, b_sid = player("capb", 10_000_000)
    cap = "copper_ore"                                                     # no other test bids on it
    p = g.PRICES[cap]
    call(M + "order", a_sid, item=cap, qty=10, price=p)                    # at the floor
    assert call(M + "order", b_sid, item=cap, qty=10, price=p * 1.26)["code"] == "price_too_high"
    assert call(M + "order", b_sid, item=cap, qty=10, price=p * 1.25)["err"] == 0
    assert call(M + "order", b_sid, item=CLAY, qty=1, price=sys_buy(CLAY) + 1)["code"] == "price_too_high"
    assert call(M + "order", b_sid, item="iron_ore", qty=g.storage_capacity(1) + 1,
                price=g.PRICES["iron_ore"])["code"] == "storage_full"
    own = call(M + "mine", b_sid)["orders"][0]
    assert call(M + "take", b_sid, orderID=own["id"], qty=1)["code"] == "own_order"
    rid = uuid.uuid4().hex
    first = call(M + "order", a_sid, item="sand", qty=5, price=g.PRICES["sand"], rid=rid)
    again = call(M + "order", a_sid, item="sand", qty=5, price=g.PRICES["sand"], rid=rid)
    assert first == again
    assert sum(1 for o in call(M + "mine", a_sid)["orders"] if o["item"] == "sand") == 1


def test_concurrent_sellers_never_overfill():
    b_hid, b_sid = player("race", 10_000)
    order = call(M + "order", b_sid, item=CLAY, qty=100, price=g.PRICES[CLAY])["orderID"]
    sellers = [player(f"rs{i}", 0) for i in range(8)]
    for s in sellers:
        put(s[0], CLAY, 30)
    results = []
    ts = [threading.Thread(target=lambda sid=s[1]: results.append(call(M + "take", sid, orderID=order, qty=30)))
          for s in sellers]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert have(b_hid, CLAY) == 100                                        # exactly what was asked
    assert sum(1 for r in results if r["err"] == 0) == 4                  # 30+30+30+10
    assert sum(credits(s[0]) for s in sellers) == 3 * net(round(30 * g.PRICES[CLAY]), CLAY) + \
        net(round(10 * g.PRICES[CLAY]), CLAY)


def test_expired_order_refunds():
    hid, sid = player("exp", 10_000)
    call(M + "order", sid, item=CLAY, qty=100, price=g.PRICES[CLAY])
    with main.get_db() as conn:
        conn.execute("UPDATE market_orders SET expires_at='2000-01-01' WHERE hid=?", (hid,))
        conn.commit()
    call(M + "overview", sid)
    assert call(M + "mine", sid)["orders"] == []
    assert credits(hid) == 10_000


def test_price_history_has_every_day():
    _, sid = player("ph")
    r = call(M + "prices", sid, item=GOLD, days=7)
    assert len(r["days"]) == 7 and r["days"][-1]["systemSell"] == g.PRICES[GOLD]


def test_storage_sell_fills_best_orders_then_system_above_the_min_price():
    p = g.PRICES[WOOL]
    b1, b1_sid = player("sb1", 10_000_000)
    b2, b2_sid = player("sb2", 10_000_000)
    s_hid, s_sid = player("ss", 0)
    assert call(M + "order", b1_sid, item=WOOL, qty=30, price=round(p * 1.2, 2))["err"] == 0
    assert call(M + "order", b2_sid, item=WOOL, qty=30, price=round(p * 1.1, 2))["err"] == 0
    put(s_hid, WOOL, 100)
    q = call("/api/v3/sell/quote", s_sid, item=WOOL)
    assert [lv["qty"] for lv in q["levels"]] == [30, 30] and q["levels"][0]["price"] > q["levels"][1]["price"]
    assert q["system"] == p
    r = call("/api/v3/sell", s_sid, item=WOOL, qty=100, minPrice=p * 1.15)      # only the best order is good enough
    assert r["sold"] == 30 and r["unsold"] == 70 and r["orders"] == 1 and r["system"] == 0
    assert have(s_hid, WOOL) == 70 and have(b1, WOOL) == 30
    r = call("/api/v3/sell", s_sid, item=WOOL, qty=70)                         # any price: order, then system
    assert r["sold"] == 70 and r["orders"] == 1 and r["system"] == 40 and have(s_hid, WOOL) == 0
    sysv = int(40 * p)
    assert credits(s_hid) == net(round(30 * round(p * 1.2, 2)), WOOL) + net(round(30 * round(p * 1.1, 2)), WOOL) + \
        sysv - round(sysv * rate(WOOL))


def test_sales_tax_is_low_for_rarely_made_items():
    with main.get_db() as conn:
        rates = market.tax_rates(conn)
        n = market.makers(conn)
        conn.commit()
    top = max((n.get(i, 0) for i in rates), default=0)
    assert all(TAX_MIN - 1e-9 <= r <= TAX_MAX + 1e-9 for r in rates.values())
    if top:                                            # the most made item pays the most, an unmade one the least
        busiest = max(rates, key=lambda i: n.get(i, 0))
        assert abs(rates[busiest] - TAX_MAX) < 1e-6
        unmade = [i for i in rates if n.get(i, 0) == 0]
        assert not unmade or abs(rates[unmade[0]] - TAX_MIN) < 1e-6
    else:
        assert all(abs(r - TAX_RATE) < 1e-9 for r in rates.values())
    q = call(M + "overview", player("taxov")[1])
    assert all("taxRate" in i for i in q["items"])
