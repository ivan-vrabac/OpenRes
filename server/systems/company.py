"""OpenRes 0.3: the company on the map (the Campus compound, surveys, hexes, storage, selling).

Numbers come from gamedata.py, the map from world.py. Production is collected on the fly: every
call that reads or changes the company first adds what its hexes made since the last collection
(each hex until its lease ends), then removes hexes whose lease ran out (the government takes them
back and anyone may build there).

Endpoints (all /api/v3/..., signed-in):
  state                        everything the app shows about the company
  campus/place     lat lng         the first Campus (free): needs 7 free hexes around you
  campus/visit     lat lng         the weekly inspection (within 200 m of the Campus)
  survey       lat lng radius  order a survey anywhere; pays the tax, starts the wait
  survey/map   what            heatmap of the last survey: an item, "land", "sun" or "wind"
  hex/info     lat lng         what could be built here (land, items and their quality)
  hex/build    lat lng plat plng op item   build here (you stand at plat/plng)
  hex/renew    ids             renew leases (comma separated hex ids)
  hex/switch   id item         another product on the same hex (costs a lease renewal)
  hex/cancel   ids             cancel leases: the hexes are destroyed, 30 % of the remaining lease
                               comes back (several at once: once every 5 s)
  hex/detail   id              one hex with its lease (days left, renewal price, when renewable)
  hex/list     sort offset     your hexes, 100 at a time (sort: lease, value, item)
  map          south west north east detail     all that is drawn in an area: Campuses + hexes (or dots)
  sell         item qty        sell to the government at the system price
  catalog                      names and numbers the app shows (items, operations, plants, steps)
  campus/upgrade                   next Campus level: credits + materials from storage (+10 supervisors)
  storage/upgrade              next Central Storage level
  supervisors                  all supervisors, the education queue
  supervisors/assign sup hex   put a supervisor on one of your hexes (swaps with the one there)
  education/start  sup         educate a supervisor one step (books + credits; joins the queue)
"""
from __future__ import annotations

import base64
import datetime
import math


import econ
import gamedata as g
import world
from . import int_arg, float_arg, integrity

START_CREDITS = 300_000
BUILD_RANGE_M = 100           # build within this distance of where you stand
GPS_TOLERANCE_M = 15
SHARED_HEX_S = 30             # players building together may share a hex this long after the first
SHARED_HEX_M = 1.0
HEX_R = 15.0                  # hex circumradius (flat-top), metres
MAP_CAMPUSES = 500            # the most /api/v3/map sends of each
MAP_HEXES = 5000
MAP_DOTS = 50000

# what each operation needs to be built: its land code (0 = any land) and quality source
PRODUCTION_HOOKS: list = []   # fn(conn, hid, state row, hours, efficiency): the plants (production.py)
OP_LAND = {op: world.LAND_CODES.get(land, 0) for op, (_n, land, _i, _u) in g.OPERATIONS.items()}


def utcnow() -> datetime.datetime:
    return datetime.datetime.utcnow()


def iso(t: datetime.datetime) -> str:
    return t.isoformat()


def parse(s) -> datetime.datetime | None:
    return datetime.datetime.fromisoformat(s) if s else None


# ── geometry ───────────────────────────────────────────────────────────────────────────────────

def dist_m(lat1, lng1, lat2, lng2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * 6_371_000 * math.asin(min(1.0, math.sqrt(a)))


def hex_min_dist(lat1, lng1, lat2, lng2) -> float:
    """Closest two flat-top hexes may be in this direction (26 m edge to edge ... 30 m corner)."""
    dlat = (lat2 - lat1) * 111_320.0
    dlng = (lng2 - lng1) * 111_320.0 * math.cos(math.radians((lat1 + lat2) / 2))
    bearing = math.atan2(dlng, dlat) % (2 * math.pi)
    phi = abs(bearing - round(bearing / (math.pi / 3)) * (math.pi / 3))
    return HEX_R * math.sqrt(3) / math.cos(min(phi, math.pi / 6 - 0.001))


def compound_cells(lat: float, lng: float) -> list[tuple[float, float]]:
    """The Campus's 7 hexes: the centre and the 6 flat-top neighbours around it, edge to edge."""
    cells = [(lat, lng)]
    d = HEX_R * math.sqrt(3)
    for k in range(6):
        a = math.radians(60 * k)                    # flat-top: neighbours across the edges (N, 60°, ...)
        cells.append((lat + d * math.cos(a) / 111_320.0,
                      lng + d * math.sin(a) / (111_320.0 * max(0.01, math.cos(math.radians(lat))))))
    return cells


def nearby(conn, lat, lng, metres=60):
    dlat = metres / 111_320.0
    dlng = dlat / max(0.01, math.cos(math.radians(lat)))
    rows = [dict(r) for r in conn.execute("SELECT id, hid, lat, lng, op, built_at FROM co_hexes WHERE lat BETWEEN ? AND ? "
                                          "AND lng BETWEEN ? AND ?", (lat - dlat, lat + dlat, lng - dlng, lng + dlng))]
    # the 7 hexes a Campus is moving to are taken while it moves (centre within reach of a cell)
    mlat, mlng = dlat + 60 / 111_320.0, dlng + 60 / 111_320.0 / max(0.01, math.cos(math.radians(lat)))
    for m in conn.execute("SELECT hid, lat, lng, started_at FROM co_moves WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?",
                          (lat - mlat, lat + mlat, lng - mlng, lng + mlng)):
        rows += [{"id": None, "hid": m["hid"], "lat": a, "lng": b, "op": "campus", "built_at": m["started_at"]}
                 for a, b in compound_cells(m["lat"], m["lng"])]
    return rows


def place_check(conn, hid, lat, lng, allow_shared=True, ignore_own_campus=False):
    """GameError if a hex at (lat, lng) would overlap another; sharing a hex is allowed briefly.
    ignore_own_campus: a moving Campus may overlap where it stands now."""
    now = utcnow()
    stack = []
    for r in nearby(conn, lat, lng):
        if ignore_own_campus and r["hid"] == hid and r["op"] == "campus":
            continue
        d = dist_m(lat, lng, r["lat"], r["lng"])
        if d < SHARED_HEX_M:
            stack.append(r)
        elif d < hex_min_dist(lat, lng, r["lat"], r["lng"]) - 0.1:
            raise econ.GameError("overlap", "This spot overlaps another hex. Move to a free hex.")
    if stack:
        if not allow_shared or any(r["op"] == "campus" for r in stack):
            raise econ.GameError("overlap", "This hex is taken.")
        if any(r["hid"] == hid for r in stack):
            raise econ.GameError("overlap", "You already have a hex here.")
        first = min(parse(r["built_at"]) for r in stack)
        if (now - first).total_seconds() > SHARED_HEX_S:
            raise econ.GameError("overlap", f"A hex can be shared only within {SHARED_HEX_S} s of the first one on it.")


# ── schema ─────────────────────────────────────────────────────────────────────────────────────

def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS co_state (
            hid           TEXT PRIMARY KEY,
            campus_level      INTEGER NOT NULL DEFAULT 0,      -- 0: no Campus placed yet
            campus_lat        REAL, campus_lng REAL,
            storage_level INTEGER NOT NULL DEFAULT 1,
            last_visit    TEXT,
            last_collect  TEXT,
            survey_lat    REAL, survey_lng REAL, survey_r REAL, survey_at TEXT, survey_next TEXT,
            ta_mg         REAL NOT NULL DEFAULT 0,
            bulk_cancel   TEXT,
            dm_level      INTEGER NOT NULL DEFAULT 0,
            streak_day    INTEGER NOT NULL DEFAULT 0,      -- login streak: days in a row claimed
            streak_last   TEXT,                             -- UTC date of the last claim
            last_move     TEXT                              -- when the Campus last finished moving
        );
        CREATE TABLE IF NOT EXISTS co_moves (                  -- a Campus being moved to a new place
            hid        TEXT PRIMARY KEY,
            lat        REAL NOT NULL, lng REAL NOT NULL,
            started_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS co_hexes (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            hid        TEXT NOT NULL,
            lat        REAL NOT NULL, lng REAL NOT NULL,
            op         TEXT NOT NULL,                       -- an operation, or "campus" for the compound
            item       TEXT,
            quality    INTEGER NOT NULL DEFAULT 0,
            built_at   TEXT NOT NULL,
            lease_until TEXT                                -- (older databases also have an unused "edu"
        );                                                  --  column: always name the columns, never h.*)
        CREATE INDEX IF NOT EXISTS idx_co_hexes_pos ON co_hexes(lat, lng);
        CREATE INDEX IF NOT EXISTS idx_co_hexes_hid ON co_hexes(hid);
        CREATE TABLE IF NOT EXISTS co_supervisors (
            id     INTEGER PRIMARY KEY AUTOINCREMENT,
            hid    TEXT NOT NULL,
            edu    INTEGER NOT NULL DEFAULT 0,          -- education step 0-4
            hex_id INTEGER                              -- the hex they run, NULL: idle at the Campus
        );
        CREATE INDEX IF NOT EXISTS idx_co_sup_hid ON co_supervisors(hid);
        CREATE INDEX IF NOT EXISTS idx_co_sup_hex ON co_supervisors(hex_id);
        CREATE TABLE IF NOT EXISTS co_education (
            id        INTEGER PRIMARY KEY AUTOINCREMENT,
            hid       TEXT NOT NULL,
            sup_id    INTEGER NOT NULL,
            to_step   INTEGER NOT NULL,
            finish_at TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS co_stock (
            hid  TEXT NOT NULL,
            item TEXT NOT NULL,
            qty  REAL NOT NULL DEFAULT 0,                   -- units; electricity in Wh; ta180m in mg
            PRIMARY KEY (hid, item)
        );
    """)


def migrate(conn) -> None:
    cols = {r[1] for r in conn.execute("PRAGMA table_info(co_state)")}
    # HQ was renamed to Campus (owner 2026-10-26)
    for old, new in (("hq_level", "campus_level"), ("hq_lat", "campus_lat"), ("hq_lng", "campus_lng")):
        if old in cols:
            conn.execute(f"ALTER TABLE co_state RENAME COLUMN {old} TO {new}")
    conn.execute("UPDATE co_hexes SET op='campus' WHERE op='hq'")
    cols = {r[1] for r in conn.execute("PRAGMA table_info(co_state)")}
    if "bulk_cancel" not in cols:
        conn.execute("ALTER TABLE co_state ADD COLUMN bulk_cancel TEXT")
    if "last_move" not in cols:
        conn.execute("ALTER TABLE co_state ADD COLUMN last_move TEXT")
    if "streak_day" not in cols:
        conn.execute("ALTER TABLE co_state ADD COLUMN streak_day INTEGER NOT NULL DEFAULT 0")
        conn.execute("ALTER TABLE co_state ADD COLUMN streak_last TEXT")
    # Campus compounds placed with the neighbours at the corners (overlapping): put them edge to edge
    for r in conn.execute("SELECT hid, campus_lat, campus_lng FROM co_state WHERE campus_level>0").fetchall():
        cells = conn.execute("SELECT lat, lng FROM co_hexes WHERE hid=? AND op='campus'", (r["hid"],)).fetchall()
        want = compound_cells(r["campus_lat"], r["campus_lng"])
        if len(cells) == 7 and all(min(dist_m(c["lat"], c["lng"], a, b) for a, b in want) < 0.5 for c in cells):
            continue
        built = conn.execute("SELECT MIN(built_at) FROM co_hexes WHERE hid=? AND op='campus'", (r["hid"],)).fetchone()[0]
        conn.execute("DELETE FROM co_hexes WHERE hid=? AND op='campus'", (r["hid"],))
        for a, b in want:
            conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, built_at) VALUES(?,?,?,?,?)",
                         (r["hid"], a, b, "campus", built or iso(utcnow())))


def state_row(conn, hid):
    row = conn.execute("SELECT * FROM co_state WHERE hid=?", (hid,)).fetchone()
    if row is None:
        now = iso(utcnow())
        conn.execute("INSERT INTO co_state(hid, last_collect, last_visit) VALUES(?,?,?)", (hid, now, now))
        conn.execute("UPDATE players SET credits=? WHERE hID=?", (START_CREDITS, hid))
        row = conn.execute("SELECT * FROM co_state WHERE hid=?", (hid,)).fetchone()
    return row


# ── credits, stock, XP ─────────────────────────────────────────────────────────────────────────

def credits(conn, hid) -> float:
    return conn.execute("SELECT credits FROM players WHERE hID=?", (hid,)).fetchone()[0] or 0


def pay(conn, hid, amount, what: str) -> None:
    """Take credits for a permanent sink (and give its XP)."""
    amount = int(round(amount))
    if credits(conn, hid) < amount:
        raise econ.GameError("credits", f"Not enough credits (needs {amount:,})")
    xp = amount * g.XP_PER_CREDIT.get(what, 0)
    conn.execute("UPDATE players SET credits=credits-?, xp=COALESCE(xp,0)+? WHERE hID=?", (amount, xp, hid))


def stock(conn, hid) -> dict:
    return {r["item"]: r["qty"] for r in conn.execute("SELECT item, qty FROM co_stock WHERE hid=?", (hid,))}


def stock_units(item: str, qty: float) -> float:
    """How much of the storage total `qty` of an item takes (electricity is stored in Wh, counts per
    kWh; Tantalum-180m is kept apart)."""
    if item == "ta180m":
        return 0.0
    return qty / 1000.0 if item == g.ENERGY else qty


def used(conn, hid) -> float:
    return sum(stock_units(i, q) for i, q in conn.execute("SELECT item, qty FROM co_stock WHERE hid=?", (hid,)))


def free_units(conn, hid, level: int) -> float:
    return max(0.0, g.storage_capacity(level) - used(conn, hid))


def room(conn, hid, level: int, item: str) -> float:
    """How much more of `item` fits (in its stored unit): the storage is one total for all items."""
    if item == "ta180m":
        return float("inf")
    free = free_units(conn, hid, level)
    return free * 1000.0 if item == g.ENERGY else free


def add_stock(conn, hid, item, qty, level) -> float:
    """Add up to the storage limit; returns what fit."""
    fit = max(0.0, min(qty, room(conn, hid, level, item)))
    if fit > 0:
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) "
                     "DO UPDATE SET qty=qty+excluded.qty", (hid, item, fit))
    return fit


def take_stock(conn, hid, item, qty) -> None:
    have = conn.execute("SELECT qty FROM co_stock WHERE hid=? AND item=?", (hid, item)).fetchone()
    if not have or have[0] + 1e-9 < qty:
        raise econ.GameError("stock", f"Not enough {g.ITEM_NAMES.get(item, item).lower()}")
    conn.execute("UPDATE co_stock SET qty=qty-? WHERE hid=? AND item=?", (qty, hid, item))


# ── production ─────────────────────────────────────────────────────────────────────────────────

def rate_per_hour(op: str, item: str, quality: int) -> float:
    """Units (electricity: Wh) a hex makes per hour without a supervisor."""
    if item == g.ENERGY:
        kwh = g.SOLAR_KWH_PER_HOUR if op == "solar_farm" else g.WIND_KWH_PER_HOUR
        return kwh * 1000 * quality / 100
    return g.raw_items()[item][2] * quality / 100


def efficiency(row, now) -> float:
    last = parse(row["last_visit"]) or now
    return g.efficiency((now - last).total_seconds() / 86400)


def collect(conn, hid):
    """Add what the hexes made since the last collection; hand expired hexes back."""
    row = state_row(conn, hid)
    now = utcnow()
    last = parse(row["last_collect"]) or now
    move = conn.execute("SELECT * FROM co_moves WHERE hid=?", (hid,)).fetchone()
    moved_at = None
    if move:
        done = parse(move["started_at"]) + datetime.timedelta(hours=g.MOVE_HOURS)
        if done <= now:
            finish_move(conn, hid, move, done)
            moved_at = done
        row = conn.execute("SELECT * FROM co_state WHERE hid=?", (hid,)).fetchone()
    if (now - last).total_seconds() >= 1:
        eff = efficiency(row, now) * (1 + g.DARK_MATTER_BONUS * row["dm_level"])
        made: dict[str, float] = {}
        finish_education(conn, hid, now)
        for h in conn.execute(HEX_ROWS + " WHERE h.hid=? AND h.op!='campus'", (hid,)):
            end = min(now, parse(h["lease_until"]) or now)
            hours = (end - last).total_seconds() / 3600
            if hours <= 0:
                continue
            boost = 1 + (g.EDUCATION[h["edu"]][1] if h["edu"] is not None else 0)
            made[h["item"]] = made.get(h["item"], 0) + rate_per_hour(h["op"], h["item"], h["quality"]) * boost * hours
        for item, q in made.items():
            add_stock(conn, hid, item, q * eff, row["storage_level"])
        # the plants pause while the Campus moves: they run only after the move is done
        plant_from = last if not move else (max(last, moved_at) if moved_at else now)
        for hook in PRODUCTION_HOOKS:
            hook(conn, hid, row, max(0.0, (now - plant_from).total_seconds() / 3600), eff)
        conn.execute("UPDATE co_state SET last_collect=? WHERE hid=?", (iso(now), hid))
        row = conn.execute("SELECT * FROM co_state WHERE hid=?", (hid,)).fetchone()
    # leases that ran out (their output was counted above, up to the end of the lease)
    if conn.execute("DELETE FROM co_hexes WHERE hid=? AND op!='campus' AND lease_until<?", (hid, iso(now))).rowcount:
        free_supervisors(conn, hid)
    return row


HEX_ROWS = ("SELECT h.id, h.op, h.item, h.quality, h.lease_until, s.edu FROM co_hexes h "
            "LEFT JOIN co_supervisors s ON s.hex_id = h.id")


def free_supervisors(conn, hid) -> None:
    """Supervisors whose hex is gone go back to the Campus."""
    conn.execute("UPDATE co_supervisors SET hex_id=NULL WHERE hid=? AND hex_id IS NOT NULL AND hex_id NOT IN "
                 "(SELECT id FROM co_hexes WHERE hid=?)", (hid, hid))


def ensure_supervisors(conn, hid, campus_level) -> None:
    have = conn.execute("SELECT COUNT(*) FROM co_supervisors WHERE hid=?", (hid,)).fetchone()[0]
    for _ in range(campus_level * g.SUPERVISORS_PER_LEVEL - have):
        conn.execute("INSERT INTO co_supervisors(hid) VALUES(?)", (hid,))


def finish_education(conn, hid, now) -> None:
    for e in conn.execute("SELECT id, sup_id, to_step FROM co_education WHERE hid=? AND finish_at<=?",
                          (hid, iso(now))).fetchall():
        conn.execute("UPDATE co_supervisors SET edu=? WHERE id=?", (e["to_step"], e["sup_id"]))
        conn.execute("DELETE FROM co_education WHERE id=?", (e["id"],))


def hex_value_per_hour(op, item, quality) -> float:
    price = g.PRICES[item] / (1000 if item == g.ENERGY else 1)
    return rate_per_hour(op, item, quality) * price


def income_per_hour(conn, hid, row) -> dict:
    eff = efficiency(row, utcnow()) * (1 + g.DARK_MATTER_BONUS * row["dm_level"])
    out: dict[str, float] = {}
    for h in conn.execute(HEX_ROWS + " WHERE h.hid=? AND h.op!='campus'", (hid,)):
        boost = 1 + (g.EDUCATION[h["edu"]][1] if h["edu"] is not None else 0)
        out[h["item"]] = out.get(h["item"], 0) + rate_per_hour(h["op"], h["item"], h["quality"]) * boost * eff
    return out


# ── the hex under a point ──────────────────────────────────────────────────────────────────────

def options_at(lat: float, lng: float) -> dict:
    """What could be built at a point: {op: {item: quality}}."""
    here = world.at(lat, lng)
    if here["land"] == "water":
        return {"land": "water", "options": {}}             # nothing is built on water
    out: dict[str, dict] = {}
    for op, (_n, _land, items, _u) in g.OPERATIONS.items():
        if op == "fishing_port":
            continue                                   # sea fishing: later
        for item in items:
            if item == g.ENERGY:
                q = here["sun"] if op == "solar_farm" else here["wind"]
            else:
                q = here["items"].get(item, 0)
            if q > 0:
                out.setdefault(op, {})[item] = q
    return {"land": here["land"], "options": out}


def tier_of(op: str, item: str) -> int:
    return g.OPERATIONS[op][2][item][0]


def lease_price(op: str, item: str) -> int:
    return g.lease_cost(item) if item != g.ENERGY else int(round(g.TIER_INCOME[tier_of(op, item)] * g.LEASE_HOURS, -2))


def renew_price(op: str, item: str, lease_until, now) -> int:
    """What renewing a lease costs now: it grows with the days used, full from day 30."""
    days_left = (lease_until - now).total_seconds() / 86400
    return int(round(lease_price(op, item) * g.lease_renew_factor(days_left)))


def renew_wait_hours(lease_until, now) -> float:
    """Hours until a lease may be renewed again (a day after the last renewal or the build)."""
    used_h = (g.LEASE_DAYS * 24) - (lease_until - now).total_seconds() / 3600
    return max(0.0, g.LEASE_RENEW_MIN_HOURS - used_h)


def cancel_refund(op: str, item: str, lease_until, now) -> int:
    """30 % of what the days left on the lease are worth."""
    days_left = max(0.0, (lease_until - now).total_seconds() / 86400)
    return int(lease_price(op, item) * days_left / g.LEASE_DAYS * g.LEASE_CANCEL_REFUND)


def hex_detail(r, now) -> dict:
    lease_until = parse(r["lease_until"])
    return {"id": r["id"], "lat": r["lat"], "lng": r["lng"], "op": r["op"], "item": r["item"],
            "quality": r["quality"], "edu": r["edu"], "builtAt": r["built_at"], "leaseUntil": r["lease_until"],
            "leaseDays": round((lease_until - now).total_seconds() / 86400, 3),
            "renewPrice": renew_price(r["op"], r["item"], lease_until, now),
            "renewInHours": round(renew_wait_hours(lease_until, now), 2),
            "cancelRefund": cancel_refund(r["op"], r["item"], lease_until, now),
            "valuePerHour": round(hex_value_per_hour(r["op"], r["item"], r["quality"]), 1),
            "ratePerHour": round(rate_per_hour(r["op"], r["item"], r["quality"])
                                 * (1 + (g.EDUCATION[r["edu"]][1] if r["edu"] is not None else 0)), 2)}


def build_price(op: str, item: str) -> int:
    return g.hex_build_cost(item) if item != g.ENERGY else int(round(g.TIER_INCOME[tier_of(op, item)] * g.HEX_BUILD_HOURS, -2))


# ── endpoints ──────────────────────────────────────────────────────────────────────────────────

def install(api) -> None:
    global _add_log
    h = api.h
    _add_log = getattr(h, "add_proto", None)
    install_campus(api)
    install_streak(api)
    install_views(api)
    with h.get_db() as conn:
        init_schema(conn)
        migrate(conn)
        conn.commit()

    def player_pos(form):
        return float_arg(form, "lat", lo=-90, hi=90), float_arg(form, "lng", lo=-180, hi=180)

    def build_spot(form):
        """Where a hex or Campus goes and where the player stands: (lat, lng, plat, plng)."""
        lat, lng = player_pos(form)
        return lat, lng, float_arg(form, "plat", lo=-90, hi=90), float_arg(form, "plng", lo=-180, hi=180)

    def in_reach(lat, lng, plat, plng):
        d = dist_m(lat, lng, plat, plng)
        if d > BUILD_RANGE_M + GPS_TOLERANCE_M:
            raise econ.GameError("range", f"Too far: build within {BUILD_RANGE_M} m of where you stand ({d:.0f} m)")

    def travel_check(conn, hid, lat, lng):
        """Refuse impossible jumps (GPS spoofing) and remember the position (main.check_travel)."""
        if getattr(h, "check_travel", None):
            h.check_travel(conn, hid, lat, lng)

    def active_today(conn, hid) -> None:
        """A day the company played (the leaderboards weigh value and Campus by it)."""
        rec = getattr(h, "record_daily_activity", None)
        if rec:
            rec(conn, hid)

    @api.endpoint("/api/v3/me")
    def me(conn, hid, form):
        """Who is signed in (0.2.3; the 1.2.3 /api/game/player sent mines, HQ and warehouse too)."""
        with econ.tx(conn):
            active_today(conn, hid)
            state_row(conn, hid)                     # a new company gets its start credits here
        p = conn.execute("SELECT company_name, credits, country_code FROM players WHERE hID=?", (hid,)).fetchone()
        if not p:
            raise econ.GameError("no_player", "Please sign in again.")
        st = conn.execute("SELECT campus_level FROM co_state WHERE hid=?", (hid,)).fetchone()
        return {"err": 0, "hID": hid, "name": p["company_name"], "credits": int(p["credits"] or 0),
                "country": p["country_code"] or "", "campusLevel": st[0] if st else 0}

    @api.endpoint("/api/v3/state")
    def state(conn, hid, form):
        with econ.tx(conn):
            active_today(conn, hid)
            row = collect(conn, hid)
        now = utcnow()
        lv = row["campus_level"]
        hexes = conn.execute("SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus'", (hid,)).fetchone()[0]
        expiring = conn.execute("SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus' AND lease_until<?",
                                (hid, iso(now + datetime.timedelta(days=30)))).fetchone()[0]
        campus = None
        if lv:
            campus = {"level": lv, "lat": row["campus_lat"], "lng": row["campus_lng"], "stage": g.campus_stage(lv),
                  "efficiency": efficiency(row, now), "lastVisit": row["last_visit"],
                  "next": g.campus_upgrade(lv) if lv < g.CAMPUS_MAX else None, **move_status(conn, hid, row, now)}
        survey = None
        if row["survey_at"]:
            survey = {"lat": row["survey_lat"], "lng": row["survey_lng"], "radius": row["survey_r"],
                      "at": row["survey_at"]}
        return {"err": 0, "credits": credits(conn, hid), "campus": campus,
                "storage": {"level": row["storage_level"], "capacity": g.storage_capacity(row["storage_level"]),
                            "used": round(used(conn, hid), 3),
                            "nextCost": g.storage_upgrade_cost(row["storage_level"]),
                            "nextCapacity": g.storage_capacity(row["storage_level"] + 1)},
                "stock": stock(conn, hid), "incomePerHour": income_per_hour(conn, hid, row),
                "hexes": hexes, "maxHexes": g.MAX_HEXES, "expiringSoon": expiring,
                "survey": survey, "surveyNext": row["survey_next"],
                "surveyMaxRadius": g.survey_max_radius(max(1, lv)),
                "supervisors": lv * g.SUPERVISORS_PER_LEVEL}

    @api.endpoint("/api/v3/campus/place")
    def campus_place(conn, hid, form):
        lat, lng, plat, plng = build_spot(form)
        with econ.tx(conn):
            travel_check(conn, hid, plat, plng)
            row = collect(conn, hid)
            if row["campus_level"]:
                raise econ.GameError("has_campus", "You already have a campus")
            integrity.require(conn, hid)
            in_reach(lat, lng, plat, plng)
            for clat, clng in compound_cells(lat, lng):
                place_check(conn, hid, clat, clng, allow_shared=False)
            now = iso(utcnow())
            for clat, clng in compound_cells(lat, lng):
                conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, built_at) VALUES(?,?,?,?,?)",
                             (hid, clat, clng, "campus", now))
            conn.execute("UPDATE co_state SET campus_level=1, campus_lat=?, campus_lng=?, last_visit=? WHERE hid=?",
                         (lat, lng, now, hid))
            ensure_supervisors(conn, hid, 1)
            log(conn, hid, "campus_placed", lat=lat, lng=lng)
        return {"err": 0, "level": 1}

    @api.endpoint("/api/v3/campus/visit")
    def campus_visit(conn, hid, form):
        lat, lng = player_pos(form)
        with econ.tx(conn):
            travel_check(conn, hid, lat, lng)
            row = collect(conn, hid)
            if not row["campus_level"]:
                raise econ.GameError("no_campus", "Place your campus first")
            d = dist_m(lat, lng, row["campus_lat"], row["campus_lng"])
            if d > g.INSPECTION_RANGE_M + GPS_TOLERANCE_M:
                raise econ.GameError("range", f"Come within {g.INSPECTION_RANGE_M} m of your campus ({d:.0f} m now)")
            conn.execute("UPDATE co_state SET last_visit=? WHERE hid=?", (iso(utcnow()), hid))
            econ.emit(conn, "campus_visit", hid, {}, public=False)
            log(conn, hid, "campus_visit", lat=row["campus_lat"], lng=row["campus_lng"])
        return {"err": 0, "efficiency": 1.0}

    @api.endpoint("/api/v3/campus/move")
    def campus_move(conn, hid, form):
        """Start moving the Campus to a spot in reach, like a hex: 7 free hexes, 24 h, plants pause; once
        a month."""
        lat, lng, plat, plng = build_spot(form)
        with econ.tx(conn):
            travel_check(conn, hid, plat, plng)
            row = collect(conn, hid)
            if not row["campus_level"]:
                raise econ.GameError("no_campus", "Place your campus first")
            st = move_status(conn, hid, row)
            if st["moving"]:
                raise econ.GameError("moving", "Your Campus is already moving. Cancel that move first.")
            if st["nextMove"]:
                raise econ.GameError("too_soon", f"Your Campus can move again on {st['nextMove'][:10]}")
            integrity.require(conn, hid)
            in_reach(lat, lng, plat, plng)
            if dist_m(lat, lng, row["campus_lat"], row["campus_lng"]) < 1:
                raise econ.GameError("same_place", "Your Campus is already here")
            for clat, clng in compound_cells(lat, lng):
                place_check(conn, hid, clat, clng, allow_shared=False, ignore_own_campus=True)
            conn.execute("INSERT INTO co_moves(hid, lat, lng, started_at) VALUES(?,?,?,?)", (hid, lat, lng, iso(utcnow())))
            log(conn, hid, "campus_move", lat=lat, lng=lng)
            out = move_status(conn, hid, row)
        return {"err": 0, **out}

    @api.endpoint("/api/v3/campus/move/cancel")
    def campus_move_cancel(conn, hid, form):
        """Call a move off: it doesn't count, so another place can be picked right away."""
        with econ.tx(conn):
            collect(conn, hid)
            if not conn.execute("DELETE FROM co_moves WHERE hid=?", (hid,)).rowcount:
                raise econ.GameError("not_moving", "Your Campus isn't moving")
            log(conn, hid, "campus_move_cancelled")
        return {"err": 0}

    @api.endpoint("/api/v3/survey")
    def survey(conn, hid, form):
        lat, lng = player_pos(form)
        radius = float_arg(form, "radius", default=100, lo=50, hi=50_000)
        with econ.tx(conn):
            row = collect(conn, hid)
            max_r = g.survey_max_radius(max(1, row["campus_level"]))
            if radius > max_r:
                raise econ.GameError("radius", f"Your campus allows surveys up to {max_r:,} m")
            now = utcnow()
            pay(conn, hid, g.survey_tax(radius), "survey")             # no waiting, only the tax
            nxt = now + datetime.timedelta(minutes=g.survey_wait_minutes(radius))
            conn.execute("UPDATE co_state SET survey_lat=?, survey_lng=?, survey_r=?, survey_at=?, survey_next=? "
                         "WHERE hid=?", (lat, lng, radius, iso(now), iso(nxt), hid))
            econ.emit(conn, "survey", hid, {"radius": radius}, public=False)
            log(conn, hid, "survey", lat=lat, lng=lng, radius=radius, cost=g.survey_tax(radius))
        return {"err": 0, "tax": g.survey_tax(radius), "next": iso(nxt)}

    @api.endpoint("/api/v3/survey/map")
    def survey_map(conn, hid, form):
        what = (form.get("what") or "land").strip()
        if what not in ("land", "sun", "wind") and what not in world.items():
            raise econ.GameError("bad_input", "Unknown resource")
        row = state_row(conn, hid)
        if not row["survey_at"]:
            raise econ.GameError("no_survey", "Order a survey first")
        values, clat, clng, step, n = world.survey_grid(what, row["survey_lat"], row["survey_lng"], row["survey_r"])
        # the picture's edges: half a pixel beyond the outermost pixel centres
        half_m = (n // 2 + 0.5) * step
        dlat = half_m / 111320.0
        dlng = half_m / (111320.0 * max(abs(math.cos(math.radians(clat))), 0.001))
        return {"err": 0, "what": what, "n": n, "step": step, "south": clat - dlat, "west": clng - dlng,
                "north": clat + dlat, "east": clng + dlng, "lat": row["survey_lat"], "lng": row["survey_lng"],
                "radius": row["survey_r"], "values": base64.b64encode(values.tobytes()).decode()}

    @api.endpoint("/api/v3/hex/info")
    def hex_info(conn, hid, form):
        lat, lng = player_pos(form)
        info = options_at(lat, lng)
        row = state_row(conn, hid)
        unlocked = {t for t, lv in g.TIER_UNLOCK.items() if row["campus_level"] >= lv}
        out = {}
        for op, items in info["options"].items():
            for item, q in items.items():
                tier = tier_of(op, item)
                out.setdefault(op, {})[item] = {"quality": q, "tier": tier, "unlocked": tier in unlocked,
                                                "unlockLevel": g.TIER_UNLOCK[tier], "build": build_price(op, item),
                                                "lease": lease_price(op, item),
                                                # without a supervisor (electricity in kWh)
                                                "perHour": round(rate_per_hour(op, item, q) / (1000 if item == g.ENERGY else 1), 1),
                                                "valuePerHour": round(hex_value_per_hour(op, item, q))}
        return {"err": 0, "land": info["land"], "options": out}

    @api.endpoint("/api/v3/hex/build")
    def hex_build(conn, hid, form):
        lat, lng, plat, plng = build_spot(form)
        op, item = (form.get("op") or "").strip(), (form.get("item") or "").strip()
        if op not in g.OPERATIONS or op == "fishing_port" or item not in g.OPERATIONS[op][2]:
            raise econ.GameError("bad_input", "Unknown operation or product")
        with econ.tx(conn):
            travel_check(conn, hid, plat, plng)
            row = collect(conn, hid)
            if not row["campus_level"]:
                raise econ.GameError("no_campus", "Place your campus first")
            integrity.require(conn, hid)
            tier = tier_of(op, item)
            if row["campus_level"] < g.TIER_UNLOCK[tier]:
                raise econ.GameError("level", f"Unlocked at campus level {g.TIER_UNLOCK[tier]}")
            in_reach(lat, lng, plat, plng)
            q = options_at(lat, lng)["options"].get(op, {}).get(item, 0)
            if q <= 0:
                raise econ.GameError("no_resource", f"There is no {g.ITEM_NAMES[item].lower()} here")
            n = conn.execute("SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus'", (hid,)).fetchone()[0]
            if n >= g.MAX_HEXES:
                raise econ.GameError("max_hexes", f"You have the maximum of {g.MAX_HEXES:,} hexes")
            place_check(conn, hid, lat, lng)
            pay(conn, hid, build_price(op, item), "hex")
            now = utcnow()
            cur = conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, item, quality, built_at, lease_until) "
                               "VALUES(?,?,?,?,?,?,?,?)", (hid, lat, lng, op, item, q, iso(now),
                                                           iso(now + datetime.timedelta(days=g.LEASE_DAYS))))
            econ.emit(conn, "hex_built", hid, {"op": op, "item": item}, public=False)
            log(conn, hid, "hex_built", lat=lat, lng=lng, name=g.ITEM_NAMES[item], quality=q, cost=build_price(op, item))
        return {"err": 0, "id": cur.lastrowid, "quality": q}

    @api.endpoint("/api/v3/hex/renew")
    def hex_renew(conn, hid, form):
        ids = [int(x) for x in (form.get("ids") or "").split(",") if x.strip().isdigit()][:10_000]
        if not ids:
            raise econ.GameError("bad_input", "No hexes")
        with econ.tx(conn):
            collect(conn, hid)
            now = utcnow()
            until = iso(now + datetime.timedelta(days=g.LEASE_DAYS))      # always back to the full 90 days
            total, rows = 0, []
            for i in ids:
                r = conn.execute("SELECT id, op, item, lease_until FROM co_hexes WHERE id=? AND hid=? AND op!='campus'",
                                 (i, hid)).fetchone()
                if not r:
                    continue
                wait = renew_wait_hours(parse(r["lease_until"]), now)
                if wait > 0:
                    if len(ids) == 1:
                        raise econ.GameError("too_soon", f"This lease can be renewed in {math.ceil(wait)} h")
                    continue                                   # renewed today: skipped in "renew all"
                total += renew_price(r["op"], r["item"], parse(r["lease_until"]), now)
                rows.append((until, r["id"]))
                one = r
            if not rows:
                raise econ.GameError("too_soon", "Nothing to renew: leases can be renewed a day after the last renewal")
            pay(conn, hid, total, "lease")
            conn.executemany("UPDATE co_hexes SET lease_until=? WHERE id=?", rows)
            for _ in rows:
                econ.emit(conn, "hex_renewed", hid, {}, public=False)
            if len(rows) == 1:
                at = conn.execute("SELECT lat, lng FROM co_hexes WHERE id=?", (one["id"],)).fetchone()
                log(conn, hid, "hex_renewed", n=1, cost=total, name=g.ITEM_NAMES.get(one["item"], ""), lat=at[0], lng=at[1])
            else:
                log(conn, hid, "hex_renewed", n=len(rows), cost=total)
        return {"err": 0, "renewed": len(rows), "paid": total}

    @api.endpoint("/api/v3/hex/switch")
    def hex_switch(conn, hid, form):
        hex_id = int_arg(form, "id")
        item = (form.get("item") or "").strip()
        with econ.tx(conn):
            collect(conn, hid)
            r = conn.execute("SELECT * FROM co_hexes WHERE id=? AND hid=? AND op!='campus'", (hex_id, hid)).fetchone()
            if not r:
                raise econ.GameError("not_found", "Hex not found")
            if r["op"] == "mine":
                raise econ.GameError("fixed", "A mine always produces what its deposit holds")
            if item == r["item"] or item not in g.OPERATIONS[r["op"]][2]:
                raise econ.GameError("bad_input", "Choose another product of this operation")
            q = options_at(r["lat"], r["lng"])["options"].get(r["op"], {}).get(item, 0)
            if q <= 0:
                raise econ.GameError("no_resource", f"{g.ITEM_NAMES[item]} doesn't grow here")
            if credits(conn, hid) < lease_price(r["op"], item):
                raise econ.GameError("credits", "Not enough credits")
            pay(conn, hid, lease_price(r["op"], item), "lease")
            conn.execute("UPDATE co_hexes SET item=?, quality=? WHERE id=?", (item, q, hex_id))
            log(conn, hid, "hex_switched", lat=r["lat"], lng=r["lng"], name=g.ITEM_NAMES[item], quality=q,
                cost=lease_price(r["op"], item))
        return {"err": 0, "quality": q}

    @api.endpoint("/api/v3/hex/cancel")
    def hex_cancel(conn, hid, form):
        ids = [int(x) for x in (form.get("ids") or form.get("id") or "").split(",") if x.strip().isdigit()][:10_000]
        if not ids:
            raise econ.GameError("bad_input", "No hexes")
        with econ.tx(conn):
            row = collect(conn, hid)
            now = utcnow()
            if len(ids) > 1:
                last = parse(row["bulk_cancel"])
                if last and (now - last).total_seconds() < g.LEASE_BULK_CANCEL_S:
                    raise econ.GameError("wait", f"Wait {g.LEASE_BULK_CANCEL_S} s between cancelling several hexes")
                conn.execute("UPDATE co_state SET bulk_cancel=? WHERE hid=?", (iso(now), hid))
            refund, done = 0, 0
            for i in ids:
                r = conn.execute("SELECT id, op, item, lat, lng, lease_until FROM co_hexes WHERE id=? AND hid=? "
                                 "AND op!='campus'", (i, hid)).fetchone()
                if not r:
                    continue
                one = r
                refund += cancel_refund(r["op"], r["item"], parse(r["lease_until"]), now)
                conn.execute("DELETE FROM co_hexes WHERE id=?", (i,))
                done += 1
            if not done:
                raise econ.GameError("not_found", "Hex not found")
            conn.execute("UPDATE players SET credits=credits+? WHERE hID=?", (refund, hid))
            free_supervisors(conn, hid)
            if done == 1:
                log(conn, hid, "hex_cancelled", n=1, refund=refund, name=g.ITEM_NAMES.get(one["item"], ""),
                    lat=one["lat"], lng=one["lng"])
            else:
                log(conn, hid, "hex_cancelled", n=done, refund=refund)
        return {"err": 0, "cancelled": done, "refund": refund}

    @api.endpoint("/api/v3/hex/detail")
    def hex_detail_ep(conn, hid, form):
        hex_id = int_arg(form, "id")
        with econ.tx(conn):
            collect(conn, hid)
        r = conn.execute("SELECT h.id, h.hid, h.lat, h.lng, h.op, h.item, h.quality, h.built_at, h.lease_until, "
                         "s.edu AS edu FROM co_hexes h LEFT JOIN co_supervisors s ON s.hex_id=h.id "
                         "WHERE h.id=? AND h.hid=? AND h.op!='campus'", (hex_id, hid)).fetchone()
        if not r:
            raise econ.GameError("not_found", "Hex not found")
        return {"err": 0, "hex": hex_detail(r, utcnow())}

    @api.endpoint("/api/v3/hex/list")
    def hex_list(conn, hid, form):
        sort = (form.get("sort") or "lease").strip()
        offset = int_arg(form, "offset", default=0, lo=0)
        limit = int_arg(form, "limit", default=100, lo=1, hi=g.MAX_HEXES)     # the Mines tab loads all
        order = {"lease": "h.lease_until", "item": "h.item, h.quality DESC", "quality": "h.quality DESC"}.get(sort)
        if order is None and sort != "value":
            raise econ.GameError("bad_input", "Unknown sort")
        with econ.tx(conn):
            collect(conn, hid)
        now = utcnow()
        q = ("SELECT h.id, h.hid, h.lat, h.lng, h.op, h.item, h.quality, h.built_at, h.lease_until, "
             "s.edu AS edu FROM co_hexes h LEFT JOIN co_supervisors s ON s.hex_id=h.id "
             "WHERE h.hid=? AND h.op!='campus'")
        if sort == "value":
            rows = conn.execute(q, (hid,)).fetchall()
            rows.sort(key=lambda r: -hex_value_per_hour(r["op"], r["item"], r["quality"]))
            rows = rows[offset:offset + limit]
        else:
            rows = conn.execute(q + f" ORDER BY {order} LIMIT ? OFFSET ?", (hid, limit, offset)).fetchall()
        total = conn.execute("SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus'", (hid,)).fetchone()[0]
        return {"err": 0, "total": total, "offset": offset, "hexes": [hex_detail(r, now) for r in rows]}

    @api.endpoint("/api/v3/map")
    def map_view(conn, hid, form):
        """Everything on the map in an area, in one answer: the Campuses (biggest first, yours always),
        and the hexes in full (`detail`=1, up close, nearest the centre first) or as flat [lat, lng, ...]
        dots for the clouds (`detail`=0). `more` = the answer was cut off at a limit."""
        s, w = float_arg(form, "south", lo=-90, hi=90), float_arg(form, "west", lo=-180, hi=180)
        n, e = float_arg(form, "north", lo=-90, hi=90), float_arg(form, "east", lo=-180, hi=180)
        campuses = conn.execute("SELECT c.hid, c.campus_level, c.campus_lat, c.campus_lng, p.company_name FROM co_state c "
                                "JOIN players p ON p.hID=c.hid WHERE c.campus_level>0 AND c.campus_lat BETWEEN ? AND ? "
                                "AND c.campus_lng BETWEEN ? AND ? ORDER BY c.hid=? DESC, c.campus_level DESC LIMIT ?",
                                (s, n, w, e, hid, MAP_CAMPUSES)).fetchall()
        res = {"err": 0, "more": len(campuses) == MAP_CAMPUSES,
               "campuses": [{"own": r["hid"] == hid, "level": r["campus_level"], "lat": r["campus_lat"],
                             "lng": r["campus_lng"], "name": r["company_name"]} for r in campuses]}
        # a Campus being moved: its new place is a construction site, taken like hexes
        moves = conn.execute("SELECT m.hid, m.lat, m.lng, p.company_name FROM co_moves m JOIN players p ON p.hID=m.hid "
                             "WHERE m.lat BETWEEN ? AND ? AND m.lng BETWEEN ? AND ?", (s, n, w, e)).fetchall()
        res["moves"] = [{"own": m["hid"] == hid, "lat": m["lat"], "lng": m["lng"], "name": m["company_name"]} for m in moves]
        site_cells = [(m["hid"], c) for m in moves for c in compound_cells(m["lat"], m["lng"])]
        if form.get("detail", "1") == "0":
            rows = conn.execute("SELECT lat, lng FROM co_hexes WHERE lat BETWEEN ? AND ? "       # Campus cells too
                                "AND lng BETWEEN ? AND ? LIMIT ?", (s, n, w, e, MAP_DOTS)).fetchall()
            res["more"] = res["more"] or len(rows) == MAP_DOTS
            res["dots"] = [v for r in rows for v in (round(r["lat"], 6), round(r["lng"], 6))]
            res["dots"] += [round(v, 6) for _, c in site_cells for v in c]
            return res
        if (n - s) * (e - w) > 0.05:
            raise econ.GameError("too_big", "Zoom in to see hexes")
        now = utcnow()
        out = []
        for r in conn.execute("SELECT h.id, h.hid, h.lat, h.lng, h.op, h.item, h.quality, h.lease_until, h.built_at, s.edu "
                              "FROM co_hexes h LEFT JOIN co_supervisors s ON s.hex_id = h.id "
                              "WHERE h.lat BETWEEN ? AND ? AND h.lng BETWEEN ? AND ? "
                              "ORDER BY ABS(h.lat-?) + ABS(h.lng-?) LIMIT ?",
                              (s, n, w, e, (s + n) / 2, (w + e) / 2, MAP_HEXES)):
            mine = r["hid"] == hid
            hx = {"id": r["id"], "lat": r["lat"], "lng": r["lng"], "op": r["op"], "item": r["item"], "own": mine}
            age = (now - parse(r["built_at"])).total_seconds()
            if r["op"] != "campus" and age < SHARED_HEX_S:
                hx["shareFor"] = round(SHARED_HEX_S - age, 1)          # others may still build on it
            if mine and r["op"] != "campus":
                hx["quality"] = r["quality"]
                hx["edu"] = r["edu"]
                days = (parse(r["lease_until"]) - now).total_seconds() / 86400
                if days < g.LEASE_CRITICAL_DAYS:              # only the critical ones (red countdown)
                    hx["leaseDays"] = round(days, 2)
            out.append(hx)
        res["more"] = res["more"] or len(out) == MAP_HEXES
        out += [{"id": None, "lat": c[0], "lng": c[1], "op": "campus", "item": None, "own": owner == hid}
                for owner, c in site_cells]
        res["hexes"] = out
        return res


def install_campus(api) -> None:
    """Campus and storage levels, supervisors and their education."""

    @api.endpoint("/api/v3/campus/upgrade")
    def campus_upgrade(conn, hid, form):
        with econ.tx(conn):
            row = collect(conn, hid)
            lv = row["campus_level"]
            if not lv:
                raise econ.GameError("no_campus", "Place your campus first")
            if lv >= g.CAMPUS_MAX:
                raise econ.GameError("max", "Your campus is at the highest level")
            need = g.campus_upgrade(lv)
            if row["storage_level"] < need["storage"]:
                raise econ.GameError("storage", f"Needs Central Storage level {need['storage']}")
            have = stock(conn, hid)
            missing = [f"{q - int(have.get(i, 0)):,} {g.ITEM_NAMES[i].lower()}"
                       for i, q in need["materials"].items() if have.get(i, 0) + 1e-9 < q]
            if missing:
                raise econ.GameError("materials", "Missing: " + ", ".join(missing))
            pay(conn, hid, need["credits"], "campus")
            for item, q in need["materials"].items():
                take_stock(conn, hid, item, q)
            mat_value = sum(g.PRICES[i] * q for i, q in need["materials"].items())
            conn.execute("UPDATE players SET xp=COALESCE(xp,0)+? WHERE hID=?", (mat_value * g.XP_PER_CREDIT["campus"], hid))
            conn.execute("UPDATE co_state SET campus_level=? WHERE hid=?", (lv + 1, hid))
            log(conn, hid, "campus_upgrade", level=lv + 1, cost=need["credits"])
            ensure_supervisors(conn, hid, lv + 1)
        return {"err": 0, "level": lv + 1, "stage": g.campus_stage(lv + 1),
                "supervisors": (lv + 1) * g.SUPERVISORS_PER_LEVEL}

    @api.endpoint("/api/v3/campus/levels")
    def campus_levels(conn, hid, form):
        """Every Campus level: its stage, what it gives and unlocks, and what reaching it costs."""
        row = conn.execute("SELECT campus_level FROM co_state WHERE hid=?", (hid,)).fetchone()
        out = []
        for lv in range(1, g.CAMPUS_MAX + 1):
            out.append({"level": lv, "stage": g.campus_stage(lv), "supervisors": lv * g.SUPERVISORS_PER_LEVEL,
                        "queueSlots": g.queue_slots(lv), "surveyRadius": g.survey_max_radius(lv),
                        "plants": [k for k, (_n, u, _m, _r) in g.FACTORIES.items() if u == lv],
                        "tiers": [t for t, u in g.TIER_UNLOCK.items() if u == lv],
                        "cost": g.campus_upgrade(lv - 1) if lv > 1 else None})
        return {"err": 0, "level": row["campus_level"] if row else 0, "levels": out}

    @api.endpoint("/api/v3/storage/upgrade")
    def storage_upgrade(conn, hid, form):
        with econ.tx(conn):
            row = collect(conn, hid)
            lv = row["storage_level"]
            pay(conn, hid, g.storage_upgrade_cost(lv), "storage")
            conn.execute("UPDATE co_state SET storage_level=? WHERE hid=?", (lv + 1, hid))
            log(conn, hid, "storage_upgrade", level=lv + 1, cost=g.storage_upgrade_cost(lv))
        return {"err": 0, "level": lv + 1, "capacity": g.storage_capacity(lv + 1)}

    @api.endpoint("/api/v3/supervisors")
    def supervisors(conn, hid, form):
        with econ.tx(conn):
            row = collect(conn, hid)
        sups = [{"id": r["id"], "edu": r["edu"], "hex": r["hex_id"]}
                for r in conn.execute("SELECT id, edu, hex_id FROM co_supervisors WHERE hid=? ORDER BY id", (hid,))]
        queue = [{"sup": r["sup_id"], "to": r["to_step"], "finish": r["finish_at"]}
                 for r in conn.execute("SELECT sup_id, to_step, finish_at FROM co_education WHERE hid=? "
                                       "ORDER BY finish_at", (hid,))]
        maxed = sum(1 for s in sups if s["edu"] >= 4)
        total = row["campus_level"] * g.SUPERVISORS_PER_LEVEL
        return {"err": 0, "total": total, "maxed": maxed, "assigned": sum(1 for s in sups if s["hex"]),
                "byStep": [sum(1 for s in sups if s["edu"] == k) for k in range(5)],
                "supervisors": sups, "queue": queue, "slots": g.queue_slots(row["campus_level"]),
                "allEducated": total == g.CAMPUS_MAX * g.SUPERVISORS_PER_LEVEL and maxed == total,
                "steps": [{"name": n, "boost": b, "hours": hrs, "books": bk, "credits": c}
                          for n, b, hrs, bk, c in g.EDUCATION.values()]}

    @api.endpoint("/api/v3/supervisors/assign")
    def supervisors_assign(conn, hid, form):
        """Put supervisor `sup` on hex `hex`; without `sup`: the best one not working on a hex."""
        hex_id = int_arg(form, "hex")
        with econ.tx(conn):
            collect(conn, hid)
            if form.get("sup"):
                sup = conn.execute("SELECT id, hex_id FROM co_supervisors WHERE id=? AND hid=?",
                                   (int_arg(form, "sup"), hid)).fetchone()
            else:
                sup = conn.execute("SELECT id, hex_id FROM co_supervisors WHERE hid=? AND hex_id IS NULL "
                                   "ORDER BY edu DESC, id LIMIT 1", (hid,)).fetchone()
                if not sup:
                    raise econ.GameError("none_free", "Every supervisor is already working on a hex")
            sup_id = sup["id"] if sup else None
            hx = conn.execute("SELECT id FROM co_hexes WHERE id=? AND hid=? AND op!='campus'", (hex_id, hid)).fetchone()
            if not sup or not hx:
                raise econ.GameError("not_found", "Supervisor or hex not found")
            # the supervisor already there takes this one's old place (or goes back to the Campus)
            conn.execute("UPDATE co_supervisors SET hex_id=? WHERE hid=? AND hex_id=?", (sup["hex_id"], hid, hex_id))
            conn.execute("UPDATE co_supervisors SET hex_id=? WHERE id=?", (hex_id, sup_id))
        return {"err": 0}

    @api.endpoint("/api/v3/supervisors/unassign")
    def supervisors_unassign(conn, hid, form):
        """Take the supervisor off hex `hex` (back to the Campus)."""
        hex_id = int_arg(form, "hex")
        with econ.tx(conn):
            collect(conn, hid)
            if not conn.execute("UPDATE co_supervisors SET hex_id=NULL WHERE hid=? AND hex_id=?", (hid, hex_id)).rowcount:
                raise econ.GameError("not_found", "No supervisor on this hex")
        return {"err": 0}

    @api.endpoint("/api/v3/education/start")
    def education_start(conn, hid, form):
        sup_id = int_arg(form, "sup")
        with econ.tx(conn):
            row = collect(conn, hid)
            sup = conn.execute("SELECT id, edu FROM co_supervisors WHERE id=? AND hid=?", (sup_id, hid)).fetchone()
            if not sup:
                raise econ.GameError("not_found", "Supervisor not found")
            queue = conn.execute("SELECT sup_id, finish_at FROM co_education WHERE hid=? ORDER BY finish_at",
                                 (hid,)).fetchall()
            if any(q["sup_id"] == sup_id for q in queue):
                raise econ.GameError("busy", "This supervisor is already in the queue")
            if sup["edu"] >= 4:
                raise econ.GameError("max", "This supervisor has the highest education")
            if len(queue) >= g.queue_slots(row["campus_level"]):
                raise econ.GameError("queue", "The education queue is full")
            step = sup["edu"] + 1
            _name, _boost, hours, books, cost = g.EDUCATION[step]
            take_stock(conn, hid, "books", books)
            pay(conn, hid, cost, "education")
            conn.execute("UPDATE players SET xp=COALESCE(xp,0)+? WHERE hID=?",
                         (books * g.PRICES["books"] * g.XP_PER_CREDIT["education"], hid))
            start = max([utcnow()] + [parse(q["finish_at"]) for q in queue])
            finish = start + datetime.timedelta(hours=hours)
            conn.execute("INSERT INTO co_education(hid, sup_id, to_step, finish_at) VALUES(?,?,?,?)",
                         (hid, sup_id, step, iso(finish)))
            econ.emit(conn, "education_started", hid, {"step": step}, public=False)
            log(conn, hid, "education", step=g.EDUCATION[step][0], cost=cost, books=books)
        return {"err": 0, "step": step, "finish": iso(finish)}


_add_log = None          # main.add_proto, set by install(): the player's activity log (7 days)


def log(conn, hid, kind: str, **data) -> None:
    """One line in the player's activity log (Account > Activity log); lat/lng make it a map link."""
    if _add_log:
        _add_log(conn, hid, kind, data)


def finish_move(conn, hid, move, when) -> None:
    """The move is finished: the Campus's 7 hexes are now at the new place."""
    conn.execute("DELETE FROM co_hexes WHERE hid=? AND op='campus'", (hid,))
    for a, b in compound_cells(move["lat"], move["lng"]):
        conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, built_at) VALUES(?,?,?,?,?)", (hid, a, b, "campus", iso(when)))
    conn.execute("UPDATE co_state SET campus_lat=?, campus_lng=?, last_move=? WHERE hid=?",
                 (move["lat"], move["lng"], iso(when), hid))
    conn.execute("DELETE FROM co_moves WHERE hid=?", (hid,))
    econ.emit(conn, "campus_moved", hid, {}, public=False)
    log(conn, hid, "campus_moved", lat=move["lat"], lng=move["lng"])


def move_status(conn, hid, row, now=None) -> dict:
    now = now or utcnow()
    m = conn.execute("SELECT * FROM co_moves WHERE hid=?", (hid,)).fetchone()
    nxt = parse(row["last_move"]) + datetime.timedelta(days=g.MOVE_EVERY_DAYS) if row["last_move"] else None
    return {"moving": None if not m else {"lat": m["lat"], "lng": m["lng"], "finish": iso(parse(m["started_at"])
                                                                                        + datetime.timedelta(hours=g.MOVE_HOURS))},
            "nextMove": iso(nxt) if nxt and nxt > now else None}


def streak_status(row, now=None) -> dict:
    """The login streak: the day a claim today would be, whether today is claimed already."""
    today = (now or utcnow()).date()
    last = row["streak_last"]
    claimed = last == today.isoformat()
    going = last in (today.isoformat(), (today - datetime.timedelta(days=1)).isoformat())
    current = row["streak_day"] if going else 0
    day = current if claimed else current + 1
    return {"day": day, "current": current, "claimed": claimed, "credits": g.streak_reward(day),
            "materials": g.streak_materials(day)}


def install_streak(api) -> None:
    """Login streak (plan section 10): credits + books every day you claim; it grows at days 7, 14
    and 30 and stays at the day-30 reward; missing a day resets it."""

    @api.endpoint("/api/v3/streak")
    def streak(conn, hid, form):
        with econ.tx(conn):
            row = collect(conn, hid)
        return {"err": 0, **streak_status(row),
                "table": [{"from": d, "credits": c, "materials": g.streak_materials(d)} for d, c in g.STREAK_REWARD]}

    @api.endpoint("/api/v3/streak/claim")
    def streak_claim(conn, hid, form):
        with econ.tx(conn):
            row = collect(conn, hid)
            s = streak_status(row)
            if s["claimed"]:
                raise econ.GameError("claimed", "Today's reward is already yours. Come back tomorrow.")
            got = {item: add_stock(conn, hid, item, q, row["storage_level"]) for item, q in s["materials"].items()}
            econ.credit(conn, hid, s["credits"], "login_streak", str(s["day"]))
            conn.execute("UPDATE co_state SET streak_day=?, streak_last=? WHERE hid=?",
                         (s["day"], utcnow().date().isoformat(), hid))
            log(conn, hid, "daily_reward", day=s["day"], credits=s["credits"])
        return {"err": 0, "day": s["day"], "credits": s["credits"], "materials": got}


def install_views(api) -> None:
    """What the app needs to draw the map and its lists."""

    @api.endpoint("/api/v3/catalog")
    def catalog(conn, hid, form):
        return {"err": 0,
                "items": {k: {"name": n, "price": g.PRICES.get(k), "tradable": k not in g.UNTRADABLE}
                          for k, n in g.ITEM_NAMES.items()},
                "operations": {op: {"name": n, "land": land, "items": list(items)}
                               for op, (n, land, items, _u) in g.OPERATIONS.items()},
                "plants": {k: {"name": n, "unlock": u} for k, (n, u, _m, _r) in g.FACTORIES.items()},
                "lands": {k: n for k, n in g.LANDS.items()},
                # every product of a hex with its operation, tier and the Campus level that unlocks it
                "raw": {item: {"op": op, "tier": tier, "unlock": g.TIER_UNLOCK[tier]}
                        for op, (_n, _l, items, _u) in g.OPERATIONS.items() if op != "fishing_port"
                        for item, (tier, _r) in items.items()},
                "education": [{"name": n, "boost": b, "hours": h, "books": bk, "credits": c}
                              for n, b, h, bk, c in g.EDUCATION.values()],
                "campusStages": [{"from": lv, "name": n} for lv, n in g.CAMPUS_STAGES], "campusMax": g.CAMPUS_MAX,
                "leaseDays": g.LEASE_DAYS, "leaseCriticalDays": g.LEASE_CRITICAL_DAYS,
                "surveyRadius": {"perLevel": g.SURVEY_RADIUS_STEP},
                "surveyBase": {"radius": g.SURVEY_BASE_M, "tax": g.SURVEY_BASE_TAX, "exponent": g.SURVEY_EXPONENT}}

    @api.endpoint("/api/v3/campuses/top")
    def campuses_top(conn, hid, form):
        """The biggest Campus of every country, for the map zoomed far out (owner 2026-10-30)."""
        best = {}
        for r in conn.execute("SELECT c.hid, c.campus_level, c.campus_lat, c.campus_lng, p.company_name, p.country_code "
                              "FROM co_state c JOIN players p ON p.hID=c.hid WHERE c.campus_level>0 "
                              "AND c.campus_lat IS NOT NULL ORDER BY c.campus_level DESC, c.hid"):
            cc = (r["country_code"] or "").lower()
            if cc and cc not in best:
                best[cc] = {"country": cc, "own": r["hid"] == hid, "level": r["campus_level"], "lat": r["campus_lat"],
                            "lng": r["campus_lng"], "name": r["company_name"]}
        return {"err": 0, "campuses": sorted(best.values(), key=lambda c: -c["level"])}
