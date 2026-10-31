"""Market (0.2.3): system trade and player buy orders on the new items in Central Storage.

Rules (unchanged from 1.2.3 unless noted):
- System trade (every tradable item has a system price, gamedata.PRICES): sell to the system at
  100 % of the system price (less the sales tax), buy from the system at 150 %. Unlimited volume.
- Only BUY orders can be placed (owner's rule 2026-10-19): a player sells by filling an existing
  buy order (or to the system). One open buy order per player and item; it can be edited (price
  change = new time priority) or cancelled. Book order: price high->low, then oldest first.
  Buy orders escrow credits (price x qty + tax) and stay open ORDER_DAYS days, then are refunded.
  Quantities are whole units.
- Sales tax (owner 2026-10-31): paid by the SELLER, on sales into buy orders and to the system;
  buying (orders, from the system) is tax-free. The rate is per item and set once a day from how
  many companies make the item (hexes or plants): TAX_MIN for an item nobody makes up to TAX_MAX for
  the one most companies make, so switching to a rarely made resource pays (TAX_RATE while nothing
  is made yet). Orders placed before this held a buyer tax: they keep it (their tax_rate column).
- A buy order may bid at most 25 % above the current best bid, never above the system's selling
  price (150 %) and never below the system's buying price (100 %).
- Not tradable: Tantalum-180m (gamedata.UNTRADABLE) and electricity (sold to the system from
  Central Storage). A buyer needs room in Central Storage for everything the order buys.
- Selling from Central Storage (/api/v3/sell, owner 2026-10-31): fills the best buy orders first
  (highest price, then oldest), the rest goes to the system at its price; nothing is sold below the
  seller's `minPrice` (the app asks how far below the best price is acceptable), and what fits
  nowhere stays in storage.
No XP from any trade (owner 2026-10-23: XP only from permanent sinks).
Credits move through econ (atomic, non-negative, ledgered); order placement accepts an
idempotency key `rid` so a retried request never places a second order.
"""
from __future__ import annotations

import datetime
import uuid

import econ
import gamedata as g
from . import company as co
from . import float_arg, int_arg

ORDER_DAYS = 2
SYSTEM_BUY_MARKUP = 1.5
MAX_BID_OVER_TOP = 1.25
TAX_RATE = 0.15                # the starting rate (and every item's rate while nothing is made yet)
TAX_MIN, TAX_MAX = 0.05, 0.25
MAX_QTY = 1e12


def tradable(item: str) -> bool:
    return item in g.PRICES and item not in g.UNTRADABLE and item != g.ENERGY


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS market_orders (
            id          TEXT PRIMARY KEY,
            hid         TEXT NOT NULL,
            item        TEXT NOT NULL,
            price       REAL NOT NULL,
            qty_total   REAL NOT NULL,
            qty_open    REAL NOT NULL,
            escrow      REAL NOT NULL DEFAULT 0,   -- credits still held (incl. tax)
            tax_rate    REAL NOT NULL,
            status      TEXT NOT NULL DEFAULT 'open',
            created_at  TEXT NOT NULL,
            expires_at  TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_market_book ON market_orders(item, status, price);
        CREATE INDEX IF NOT EXISTS idx_market_hid ON market_orders(hid, status);
        CREATE TABLE IF NOT EXISTS market_trades (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            ts         TEXT NOT NULL,
            kind       TEXT NOT NULL,          -- player | system_sell | system_buy
            item       TEXT NOT NULL,
            qty        REAL NOT NULL,
            price      REAL NOT NULL,
            buyer_hid  TEXT,
            seller_hid TEXT,
            tax        REAL NOT NULL DEFAULT 0,
            buy_order  TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_market_trades_item ON market_trades(item, ts);
        CREATE INDEX IF NOT EXISTS idx_market_trades_buyer ON market_trades(buyer_hid, ts);
        CREATE INDEX IF NOT EXISTS idx_market_trades_seller ON market_trades(seller_hid, ts);
        CREATE TABLE IF NOT EXISTS market_tax (
            day   TEXT NOT NULL,
            item  TEXT NOT NULL,
            rate  REAL NOT NULL,
            makers INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (day, item)
        );
        CREATE TABLE IF NOT EXISTS market_days (
            day      TEXT NOT NULL,
            item     TEXT NOT NULL,
            sys_sell REAL,
            sys_buy  REAL,
            PRIMARY KEY (day, item)
        );
    """)
    # 1.2.3 orders (old items, table mkt_orders): give back what they still hold, once
    if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='mkt_orders'").fetchone():
        with econ.tx(conn):
            for o in conn.execute("SELECT * FROM mkt_orders WHERE status='open'").fetchall():
                if o["side"] == "buy" and o["escrow"] > 0:
                    econ.credit(conn, o["hid"], o["escrow"], "market_closed_0_2_3", o["id"])
                conn.execute("UPDATE mkt_orders SET status='cancelled', qty_open=0, escrow=0 WHERE id=?", (o["id"],))
    conn.commit()


def makers(conn) -> dict:
    """item: how many companies make it now (hexes or plants)."""
    from . import production
    who: dict = {}
    for item, hid in conn.execute("SELECT DISTINCT item, hid FROM co_hexes WHERE op!='campus'"):
        who.setdefault(item, set()).add(hid)
    for hid, key, recipe in conn.execute("SELECT hid, key, recipe FROM co_plants"):
        out = production.batch(key, recipe)[1][0]
        who.setdefault(out, set()).add(hid)
    return {i: len(h) for i, h in who.items()}


def tax_rates(conn) -> dict:
    """Today's sales tax of every tradable item (worked out once a day, inside the caller's tx or not)."""
    day = econ.utcnow().date().isoformat()
    rows = {r[0]: r[1] for r in conn.execute("SELECT item, rate FROM market_tax WHERE day=?", (day,))}
    if rows:
        return rows
    n = makers(conn)
    top = max((n.get(i, 0) for i in g.PRICES if tradable(i) or i == g.ENERGY), default=0)
    rates = {}
    for i in g.PRICES:
        if i in g.UNTRADABLE:
            continue
        rates[i] = TAX_RATE if top == 0 else round(TAX_MIN + (TAX_MAX - TAX_MIN) * n.get(i, 0) / top, 4)
        conn.execute("INSERT OR IGNORE INTO market_tax(day, item, rate, makers) VALUES(?,?,?,?)",
                     (day, i, rates[i], n.get(i, 0)))
    return rates


def tax_rate(conn, item: str) -> float:
    return tax_rates(conn).get(item, TAX_RATE)


def sys_buy(item: str) -> float:
    """What a player pays the system per unit (150 %)."""
    return round(g.PRICES[item] * SYSTEM_BUY_MARKUP, 2)


def room(conn, hid, item) -> float:
    """Free space for `item` in the company's Central Storage."""
    return co.room(conn, hid, co.state_row(conn, hid)["storage_level"], item)


def put(conn, hid, item, qty) -> None:
    """Into Central Storage regardless of the limit (an order already reserved the room)."""
    conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) "
                 "DO UPDATE SET qty=qty+excluded.qty", (hid, item, qty))


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        co.init_schema(conn)
        init_schema(conn)

    # ── helpers ─────────────────────────────────────────────────────────────

    def item_arg(form) -> str:
        item = (form.get("item") or "").strip()
        if item not in g.ITEM_NAMES:
            raise econ.GameError("bad_input", "Unknown item")
        if not tradable(item):
            raise econ.GameError("restricted", f"{g.ITEM_NAMES[item]} can't be traded on the market")
        return item

    def expire(conn) -> int:
        """Refund orders past their expiry (call inside a tx)."""
        rows = conn.execute("SELECT * FROM market_orders WHERE status='open' AND expires_at <= ?",
                            (econ.utcnow_iso(),)).fetchall()
        for o in rows:
            close_order(conn, o, "expired")
        return len(rows)

    def close_order(conn, o, status: str) -> None:
        econ.credit(conn, o["hid"], o["escrow"], f"market_{status}", o["id"])
        conn.execute("UPDATE market_orders SET status=?, qty_open=0, escrow=0 WHERE id=?", (status, o["id"]))

    def record(conn, kind, item, qty, price, buyer, seller, tax=0.0, buy_order=None, earned=None) -> None:
        conn.execute("INSERT INTO market_trades(ts, kind, item, qty, price, buyer_hid, seller_hid, tax, buy_order) "
                     "VALUES(?,?,?,?,?,?,?,?,?)",
                     (econ.utcnow_iso(), kind, item, qty, price, buyer, seller, tax, buy_order))
        econ.emit(conn, "market_trade", buyer or seller, {"kind": kind, "item": item, "qty": qty, "price": price},
                  public=False)
        # owner 2026-10-24: your trades are in the log (which deletes old entries), not a market history
        value = round(qty * price)
        to = "the system" if kind.startswith("system") else "a player"
        if buyer:
            h.add_proto(conn, buyer, "marketbuy", {"item": item, "name": g.ITEM_NAMES[item], "qty": qty,
                                                   "cost": value, "from": to})
        if seller:
            h.add_proto(conn, seller, "marketsold", {"item": item, "name": g.ITEM_NAMES[item], "qty": qty,
                                                     "earned": value if earned is None else earned, "to": to})

    def fill(conn, o, seller_hid: str, qty: float) -> dict:
        """The seller (taker) sells qty into resting buy order o at its price and pays the sales tax."""
        value = round(qty * o["price"])
        tax = round(value * o["tax_rate"])          # orders from before the sales tax held a buyer tax
        if value + tax > o["escrow"] + 1e-6:      # rounding guard: never pay out more than held
            tax = max(0, round(o["escrow"]) - value)
        sales_tax = round(value * tax_rate(conn, o["item"]))
        co.collect(conn, seller_hid)
        co.take_stock(conn, seller_hid, o["item"], qty)
        econ.credit(conn, seller_hid, value - sales_tax, "market_sell", o["id"])
        put(conn, o["hid"], o["item"], qty)
        new_open = round(o["qty_open"] - qty, 6)
        new_escrow = o["escrow"] - value - tax
        if new_open <= 1e-6:
            econ.credit(conn, o["hid"], max(0, round(new_escrow)), "market_escrow_rest", o["id"])
            conn.execute("UPDATE market_orders SET qty_open=0, escrow=0, status='filled' WHERE id=?", (o["id"],))
            if getattr(h, "notify", None):
                h.notify(o["hid"], "order_filled", "Buy order filled",
                         f"Your buy order for {int(o['qty_total']):,} {g.ITEM_NAMES[o['item']].lower()} was filled.")
        else:
            conn.execute("UPDATE market_orders SET qty_open=?, escrow=? WHERE id=?", (new_open, new_escrow, o["id"]))
        record(conn, "player", o["item"], qty, o["price"], o["hid"], seller_hid, tax + sales_tax, buy_order=o["id"],
               earned=value - sales_tax)
        return {"qty": qty, "price": o["price"], "value": value, "tax": sales_tax, "net": value - sales_tax}

    def bids(conn, hid, item, limit=50):
        rows = conn.execute("SELECT o.id, o.price, o.qty_open, o.hid, o.expires_at, p.company_name "
                            "FROM market_orders o JOIN players p ON p.hID=o.hid WHERE o.item=? AND o.status='open' "
                            "ORDER BY o.price DESC, o.created_at LIMIT ?", (item, limit)).fetchall()
        return [{"id": r[0], "price": r[1], "qty": r[2], "isMine": r[3] == hid, "expiresAt": r[4],
                 "name": r[5]} for r in rows]

    def qty_arg(form) -> int:
        qty = int_arg(form, "qty", None, 0, int(MAX_QTY))     # whole units only
        if qty <= 0:
            raise econ.GameError("bad_input", "Quantity must be positive")
        return qty

    def check_bid(conn, hid, item, price):
        top = conn.execute("SELECT price FROM market_orders WHERE item=? AND status='open' AND hid<>? "
                           "ORDER BY price DESC, created_at LIMIT 1", (item, hid)).fetchone()
        if top and price > top[0] * MAX_BID_OVER_TOP + 1e-9:
            raise econ.GameError("price_too_high", f"Bid at most 25% above the best bid ({top[0] * MAX_BID_OVER_TOP:.2f})")
        if price > sys_buy(item) + 1e-9:
            raise econ.GameError("price_too_high", "Above the system ASK price.")
        if price < g.PRICES[item] - 1e-9:      # the system's buying price is the floor
            raise econ.GameError("price_too_low", "Below the system BID price.")

    # ── read endpoints ──────────────────────────────────────────────────────

    @api.endpoint("/api/v1/market/overview", feature="MARKET_V2")
    def overview(conn, hid, form):
        with econ.tx(conn):
            expire(conn)
            co.collect(conn, hid)
        mine = co.stock(conn, hid)
        rates = tax_rates(conn)
        items = {i: {"item": i, "name": g.ITEM_NAMES[i], "systemSell": g.PRICES[i], "systemBuy": sys_buy(i),
                     "owned": mine.get(i, 0.0), "taxRate": rates.get(i, TAX_RATE)} for i in g.ITEM_NAMES if tradable(i)}
        for r in conn.execute("SELECT item, MAX(price), SUM(qty_open) FROM market_orders WHERE status='open' GROUP BY item"):
            if r[0] in items:
                items[r[0]]["bestBid"], items[r[0]]["bidQty"] = r[1], r[2]
        return {"err": 0, "items": list(items.values()), "taxMin": TAX_MIN, "taxMax": TAX_MAX, "orderDays": ORDER_DAYS}

    @api.endpoint("/api/v1/market/book", feature="MARKET_V2")
    def book(conn, hid, form):
        item = item_arg(form)
        with econ.tx(conn):
            co.collect(conn, hid)
        mine = conn.execute("SELECT * FROM market_orders WHERE hid=? AND item=? AND status='open'", (hid, item)).fetchone()
        return {"err": 0, "item": item, "bids": bids(conn, hid, item),
                "systemSell": g.PRICES[item], "systemBuy": sys_buy(item),
                "owned": co.stock(conn, hid).get(item, 0.0), "taxRate": tax_rate(conn, item),
                "credits": econ.credits_of(conn, hid), "freeSpace": int(room(conn, hid, item)),
                "myOrder": None if not mine else {"id": mine["id"], "price": mine["price"], "qty": int(mine["qty_open"]),
                                                  "escrow": round(mine["escrow"]), "expiresAt": mine["expires_at"]}}

    @api.endpoint("/api/v1/market/mine", feature="MARKET_V2")
    def my_orders(conn, hid, form):
        rows = conn.execute("SELECT * FROM market_orders WHERE hid=? AND status='open' ORDER BY created_at DESC",
                            (hid,)).fetchall()
        return {"err": 0, "orders": [{
            "id": o["id"], "side": "buy", "item": o["item"], "name": g.ITEM_NAMES[o["item"]], "price": o["price"],
            "qtyTotal": o["qty_total"], "qtyOpen": o["qty_open"], "escrow": round(o["escrow"]),
            "taxRate": o["tax_rate"], "expiresAt": o["expires_at"]} for o in rows]}

    @api.endpoint("/api/v1/market/history", feature="MARKET_V2")
    def history(conn, hid, form):
        rows = conn.execute("SELECT * FROM market_trades WHERE buyer_hid=? OR seller_hid=? ORDER BY id DESC LIMIT 100",
                            (hid, hid)).fetchall()
        return {"err": 0, "trades": [{"ts": t["ts"], "kind": t["kind"], "item": t["item"], "qty": t["qty"],
                                      "price": t["price"], "side": "buy" if t["buyer_hid"] == hid else "sell",
                                      "tax": t["tax"] if t["buyer_hid"] == hid else 0} for t in rows]}

    @api.endpoint("/api/v1/market/prices", feature="MARKET_V2")
    def price_history(conn, hid, form):
        """Daily price history of one item for a graph (owner 2026-10-23): the system's buying price
        (bottom), its selling price (top) and the average player trade price of each day (volume
        weighted; days without player trades show the system's buying price). days = 7, 30 or 365."""
        item = item_arg(form)
        days = int_arg(form, "days", 30, 1, 365)
        if days not in (7, 30, 365):
            days = 30
        today = econ.utcnow().date()
        start = today - datetime.timedelta(days=days - 1)
        with econ.tx(conn):
            record_day_prices(conn, today)
        snap = {r[0]: (r[1], r[2]) for r in conn.execute(
            "SELECT day, sys_sell, sys_buy FROM market_days WHERE item=? AND day>=?", (item, start.isoformat()))}
        avg = {r[0]: (r[1] / r[2], r[2]) for r in conn.execute(
            "SELECT substr(ts,1,10), SUM(price*qty), SUM(qty) FROM market_trades WHERE kind='player' AND item=? "
            "AND ts>=? GROUP BY substr(ts,1,10)", (item, start.isoformat()))}
        out = []
        for i in range(days):
            d = (start + datetime.timedelta(days=i)).isoformat()
            ss, sb = snap.get(d, (g.PRICES[item], sys_buy(item)))
            a, q = avg.get(d, (None, 0))
            out.append({"day": d, "systemSell": ss, "systemBuy": sb,
                        "avg": round(a, 2) if a is not None else ss, "traded": int(q)})
        return {"err": 0, "item": item, "days": out}

    @api.endpoint("/api/v1/market/quote", feature="MARKET_V2")
    def quote(conn, hid, form):
        """Preview of costs/proceeds and tax for any market action (nothing is changed)."""
        action = form.get("action", "")
        item, qty = item_arg(form), qty_arg(form)
        if action == "system_sell":                 # the seller pays the sales tax
            v = round(qty * g.PRICES[item])
            rate = tax_rate(conn, item)
            tax = round(v * rate)
            return {"err": 0, "value": v, "tax": tax, "total": v - tax, "taxRate": rate}
        if action == "system_buy":                  # buying is tax-free
            v = round(qty * sys_buy(item))
            return {"err": 0, "value": v, "tax": 0, "total": v, "taxRate": 0}
        if action == "buy_order":                   # the order holds just its value
            value = round(qty * float_arg(form, "price", None, 0))
            return {"err": 0, "value": value, "tax": 0, "total": value, "taxRate": 0}
        raise econ.GameError("bad_input", "Unknown action")

    # ── write endpoints ─────────────────────────────────────────────────────

    def idempotent(conn, hid, form, scope, fn):
        rid = (form.get("rid") or "").strip()[:64]
        with econ.tx(conn):
            if rid:
                prev = econ.once_get(conn, scope, hid, rid)
                if prev is not None:
                    return prev
            expire(conn)
            co.collect(conn, hid)
            out = fn()
            if rid:
                econ.once_put(conn, scope, hid, rid, out)
            return out

    @api.endpoint("/api/v1/market/system", feature="MARKET_V2")
    def system_trade(conn, hid, form):
        """side=sell: sell to the system at 100 %. side=buy: buy from the system at 150 % + tax. With
        fit=1 a buy takes what fits: hexes and plants keep filling Central Storage while you decide."""
        side = form.get("side", "")
        item, qty = item_arg(form), qty_arg(form)

        def run():
            if side == "sell":
                value = round(qty * g.PRICES[item])
                tax = round(value * tax_rate(conn, item))
                co.take_stock(conn, hid, item, qty)
                econ.credit(conn, hid, value - tax, "system_sell")
                record(conn, "system_sell", item, qty, g.PRICES[item], None, hid, tax, earned=value - tax)
                return {"err": 0, "qty": qty, "credits": value - tax, "tax": tax}
            if side == "buy":
                fits = int(room(conn, hid, item))
                buy = min(qty, fits) if form.get("fit") == "1" else qty
                if buy < 1 or fits < buy:
                    raise econ.GameError("storage_full", "Not enough room in Central Storage")
                value = round(buy * sys_buy(item))
                econ.debit(conn, hid, value, "system_buy")
                put(conn, hid, item, buy)
                record(conn, "system_buy", item, buy, sys_buy(item), hid, None)
                return {"err": 0, "qty": buy, "cost": value, "tax": 0}
            raise econ.GameError("bad_input", "side must be buy or sell")
        return idempotent(conn, hid, form, "market_system", run)

    def hold(conn, hid, item, qty, price, order_id, exclude=None):
        """Check the bid and the room, take the escrow; returns (escrow, value)."""
        check_bid(conn, hid, item, price)
        held = conn.execute("SELECT COALESCE(SUM(qty_open), 0) FROM market_orders WHERE hid=? AND item=? AND "
                            "status='open' AND id<>?", (hid, item, exclude or "")).fetchone()[0]
        if room(conn, hid, item) - held < qty:
            raise econ.GameError("storage_full", "Not enough room in Central Storage for this order")
        value = round(qty * price)
        escrow = value                              # buying is tax-free (owner 2026-10-31)
        econ.debit(conn, hid, escrow, "market_order_escrow", order_id)
        return escrow, value

    @api.endpoint("/api/v1/market/order", feature="MARKET_V2")
    def place_order(conn, hid, form):
        """Place a buy order (the only kind of player order). Credits (price x qty + tax) are held
        until it fills, is edited, cancelled or expires. One open order per item."""
        if form.get("side", "buy") != "buy":
            raise econ.GameError("bad_input", "Only buy orders can be placed: sell by filling a buy order")
        item, qty = item_arg(form), qty_arg(form)
        price = round(float_arg(form, "price", None, 0.01, 1e12), 2)

        def run():
            if conn.execute("SELECT 1 FROM market_orders WHERE hid=? AND item=? AND status='open'", (hid, item)).fetchone():
                raise econ.GameError("duplicate", "You already have a buy order for this item. Edit or cancel it")
            order_id = uuid.uuid4().hex
            escrow, value = hold(conn, hid, item, qty, price, order_id)
            now = econ.utcnow()
            conn.execute("INSERT INTO market_orders(id, hid, item, price, qty_total, qty_open, escrow, tax_rate, "
                         "status, created_at, expires_at) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                         (order_id, hid, item, price, qty, qty, escrow, 0.0, "open", now.isoformat(),
                          (now + datetime.timedelta(days=ORDER_DAYS)).isoformat()))
            return {"err": 0, "orderID": order_id, "escrow": escrow, "tax": escrow - value}
        return idempotent(conn, hid, form, "market_order", run)

    @api.endpoint("/api/v1/market/edit", feature="MARKET_V2")
    def edit_order(conn, hid, form):
        """Change price and/or quantity of your buy order. A new price gets a new time priority."""
        order_id = (form.get("orderID") or "").strip()
        qty = int_arg(form, "qty", None, 1, int(MAX_QTY))
        price = round(float_arg(form, "price", None, 0.01, 1e12), 2)

        def run():
            o = conn.execute("SELECT * FROM market_orders WHERE id=? AND hid=? AND status='open'",
                             (order_id, hid)).fetchone()
            if not o:
                raise econ.GameError("gone", "Order not found or already closed")
            econ.credit(conn, hid, o["escrow"], "market_edit_refund", o["id"])
            escrow, value = hold(conn, hid, o["item"], qty, price, o["id"], exclude=o["id"])
            now = econ.utcnow()
            created = o["created_at"] if abs(price - o["price"]) < 1e-9 else now.isoformat()
            conn.execute("UPDATE market_orders SET price=?, qty_total=?, qty_open=?, escrow=?, tax_rate=?, created_at=?, "
                         "expires_at=? WHERE id=?", (price, qty, qty, escrow, TAX_RATE, created,
                                                     (now + datetime.timedelta(days=ORDER_DAYS)).isoformat(), o["id"]))
            return {"err": 0, "orderID": o["id"], "escrow": escrow, "tax": escrow - value}
        return idempotent(conn, hid, form, "market_edit", run)

    @api.endpoint("/api/v1/market/take", feature="MARKET_V2")
    def take_order(conn, hid, form):
        """Sell into a specific buy order."""
        order_id = (form.get("orderID") or "").strip()
        qty = int_arg(form, "qty", None, 0, int(MAX_QTY))

        def run():
            o = conn.execute("SELECT * FROM market_orders WHERE id=? AND status='open'", (order_id,)).fetchone()
            if not o:
                raise econ.GameError("gone", "This order is no longer available")
            if o["hid"] == hid:
                raise econ.GameError("own_order", "You can't fill your own order")
            q = min(qty, o["qty_open"])
            if q <= 0:
                raise econ.GameError("bad_input", "Quantity must be positive")
            return {"err": 0, **fill(conn, o, hid, q)}
        return idempotent(conn, hid, form, "market_take", run)

    @api.endpoint("/api/v3/sell")
    def sell(conn, hid, form):
        item = (form.get("item") or "").strip()
        qty = float_arg(form, "qty", lo=0)
        min_price = float_arg(form, "minPrice", 0, lo=0)
        if item not in g.PRICES or item in g.UNTRADABLE:
            raise econ.GameError("bad_input", "This can't be sold")
        with econ.tx(conn):
            expire(conn)
            co.collect(conn, hid)
            have = conn.execute("SELECT qty FROM co_stock WHERE hid=? AND item=?", (hid, item)).fetchone()
            if not have or have[0] + 1e-9 < qty:
                raise econ.GameError("stock", f"Not enough {g.ITEM_NAMES.get(item, item).lower()}")
            left, got, orders = qty, 0, 0
            if tradable(item):
                for o in conn.execute("SELECT * FROM market_orders WHERE item=? AND status='open' AND hid<>? "
                                      "AND price >= ? ORDER BY price DESC, created_at",
                                      (item, hid, min_price - 1e-9)).fetchall():
                    q = min(int(left), int(o["qty_open"]))          # orders take whole units
                    if q <= 0:
                        break
                    got += fill(conn, o, hid, q)["net"]
                    left -= q
                    orders += 1
            to_system = 0.0
            if left > 1e-9 and g.PRICES[item] >= min_price - 1e-9:
                to_system = left
                co.take_stock(conn, hid, item, left)
                value = int(left * g.PRICES[item] / (1000 if item == g.ENERGY else 1))    # electricity in Wh
                value -= round(value * tax_rate(conn, item))                            # the sales tax
                conn.execute("UPDATE players SET credits=credits+? WHERE hID=?", (value, hid))
                co.log(conn, hid, "sold", name=g.ITEM_NAMES[item], qty=left / 1000 if item == g.ENERGY else left,
                       unit="kWh" if item == g.ENERGY else "", credits=value)
                got += value
                left = 0.0
        return {"err": 0, "credits": got, "sold": qty - left, "unsold": left, "orders": orders, "system": to_system}

    @api.endpoint("/api/v3/sell/quote")
    def sell_quote(conn, hid, form):
        """What the buy orders of other companies take, best first, and the system price under them."""
        item = (form.get("item") or "").strip()
        if item not in g.PRICES or item in g.UNTRADABLE:
            raise econ.GameError("bad_input", "This can't be sold")
        levels = [{"price": b["price"], "qty": int(b["qty"]), "name": b["name"]}
                  for b in (bids(conn, hid, item, 200) if tradable(item) else []) if not b["isMine"]]
        return {"err": 0, "item": item, "levels": levels, "system": g.PRICES[item], "taxRate": tax_rate(conn, item)}

    @api.endpoint("/api/v1/market/cancel", feature="MARKET_V2")
    def cancel(conn, hid, form):
        order_id = (form.get("orderID") or "").strip()
        with econ.tx(conn):
            o = conn.execute("SELECT * FROM market_orders WHERE id=? AND hid=? AND status='open'",
                             (order_id, hid)).fetchone()
            if not o:
                raise econ.GameError("gone", "Order not found or already closed")
            refund = round(o["escrow"])
            close_order(conn, o, "cancelled")
        return {"err": 0, "side": "buy", "refunded": refund}

    def record_day_prices(conn, day) -> None:
        """Snapshot the system prices once per day (so later price changes don't rewrite history)."""
        iso = day.isoformat()
        if conn.execute("SELECT 1 FROM market_days WHERE day=? LIMIT 1", (iso,)).fetchone():
            return
        # once a day: trades older than the longest chart (365 days) are no longer needed
        old = (day - datetime.timedelta(days=366)).isoformat()
        conn.execute("DELETE FROM market_trades WHERE ts < ?", (old,))
        conn.execute("DELETE FROM market_days WHERE day < ?", (old,))
        conn.executemany("INSERT OR IGNORE INTO market_days(day, item, sys_sell, sys_buy) VALUES(?,?,?,?)",
                         [(iso, i, g.PRICES[i], sys_buy(i)) for i in g.ITEM_NAMES if tradable(i)])
