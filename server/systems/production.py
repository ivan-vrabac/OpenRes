"""OpenRes 0.3: Production & Assembly (the plants inside the Campus), Tantalum-180m and dark matter.

A plant runs its chosen recipe continuously while it's switched on: each level runs the batch
from gamedata (scaled by gamedata.factory_scale) once more in parallel. It's limited by the inputs
and electricity in Central Storage and by room for its output. Plants run whenever the company is
collected (company.collect), power plants first, then in unlock order, so a chain like
wood -> lumber -> furniture flows within one collection.

Endpoints (/api/v3/..., signed-in):
  plants                       every plant: unlock level, level, recipe, per-hour flows, next cost
  plants/build    key          build a plant (level 1)
  plants/upgrade  key          next level
  plants/recipe   key recipe   choose which recipe it runs (index)
  plants/run      key on       switch it on (1) or off (0)
  luxury                       Tantalum-180m: held, produced in total, the leaderboard
  darkmatter                   research level, next cost, whether it's open
  darkmatter/invest            put Ta-180m into the next research level
"""
from __future__ import annotations

import econ
import gamedata as g
from . import int_arg
from . import company as co

ENERGY_FIRST = [k for k, (_n, _u, _m, recipes) in g.FACTORIES.items() if recipes[0][1][0] == g.ENERGY]
ORDER = ENERGY_FIRST + sorted((k for k in g.FACTORIES if k not in ENERGY_FIRST), key=lambda k: g.FACTORIES[k][1])


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS co_plants (
            hid     TEXT NOT NULL,
            key     TEXT NOT NULL,
            level   INTEGER NOT NULL DEFAULT 1,
            recipe  INTEGER NOT NULL DEFAULT 0,
            running INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (hid, key)
        );
        CREATE TABLE IF NOT EXISTS co_luxury (
            hid      TEXT PRIMARY KEY,
            produced REAL NOT NULL DEFAULT 0,      -- Ta-180m made in total (mg): the leaderboard
            invested REAL NOT NULL DEFAULT 0       -- put into dark matter research (mg)
        );
    """)


def units(item: str, qty: float) -> float:
    """Recipe quantities -> storage units (electricity: kWh -> Wh)."""
    return qty * 1000 if item == g.ENERGY else qty


def batch(key: str, recipe: int):
    """(inputs, (output, qty), hours, kWh) for one level of a plant (scaled)."""
    inputs, (out, qty), hours, kwh = g.FACTORIES[key][3][recipe]
    s = g.factory_scale(key)
    return {i: q * s for i, q in inputs.items()}, (out, qty * s), hours, kwh * s


def run_plants(conn, hid, row, hours: float, eff: float) -> None:
    """Run every switched-on plant for `hours` (called from company.collect)."""
    if hours <= 0:
        return
    plants = {r["key"]: r for r in conn.execute("SELECT key, level, recipe, running FROM co_plants WHERE hid=?", (hid,))}
    if not plants:
        return
    have = co.stock(conn, hid)
    for key in ORDER:
        p = plants.get(key)
        if not p or not p["running"]:
            continue
        inputs, (out, qty), bh, kwh = batch(key, p["recipe"])
        n = p["level"] * hours / bh * eff                       # batches time allows
        for item, q in inputs.items():
            n = min(n, have.get(item, 0.0) / q)
        if kwh:
            n = min(n, have.get(g.ENERGY, 0.0) / units(g.ENERGY, kwh))
        # one storage total: a batch takes its inputs out and puts its output in, so only the net grows it
        net = co.stock_units(out, units(out, qty)) - sum(co.stock_units(i, units(i, q)) for i, q in inputs.items())             - (kwh or 0)
        if net > 1e-9:
            n = min(n, max(0.0, co.free_units(conn, hid, row["storage_level"])) / net)
        if n <= 1e-9:
            continue
        for item, q in inputs.items():
            co.take_stock(conn, hid, item, q * n)
            have[item] = have.get(item, 0.0) - q * n
        if kwh:
            co.take_stock(conn, hid, g.ENERGY, units(g.ENERGY, kwh) * n)
            have[g.ENERGY] -= units(g.ENERGY, kwh) * n
        made = co.add_stock(conn, hid, out, units(out, qty) * n, row["storage_level"])
        have[out] = have.get(out, 0.0) + made
        if out == "ta180m":
            conn.execute("INSERT INTO co_luxury(hid, produced) VALUES(?,?) ON CONFLICT(hid) "
                         "DO UPDATE SET produced=produced+excluded.produced", (hid, made))


def plant_info(key: str, p, campus_level: int) -> dict:
    name, unlock, _m, recipes = g.FACTORIES[key]
    lv = p["level"] if p else 0
    rec = p["recipe"] if p else 0
    out = {"key": key, "name": name, "unlock": unlock, "unlocked": campus_level >= unlock, "level": lv,
           "recipe": rec, "running": bool(p["running"]) if p else False,
           "nextCost": g.factory_upgrade_cost(key, lv), "recipes": []}
    for i in range(len(recipes)):
        inputs, (o, qty), hours, kwh = batch(key, i)
        out["recipes"].append({"inputs": inputs, "output": o, "qty": qty, "hours": hours, "kwh": kwh,
                               "profitPerHour": round(g.recipe_profit_per_hour(key, i), 1)})
    return out


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)
        conn.commit()
    co.PRODUCTION_HOOKS.append(run_plants)

    def plant_row(conn, hid, key):
        return conn.execute("SELECT * FROM co_plants WHERE hid=? AND key=?", (hid, key)).fetchone()

    def known(key):
        if key not in g.FACTORIES:
            raise econ.GameError("bad_input", "Unknown plant")
        return key

    @api.endpoint("/api/v3/plants")
    def plants(conn, hid, form):
        with econ.tx(conn):
            row = co.collect(conn, hid)
        have = {r["key"]: r for r in conn.execute("SELECT * FROM co_plants WHERE hid=?", (hid,))}
        return {"err": 0, "plants": [plant_info(k, have.get(k), row["campus_level"]) for k in ORDER]}

    @api.endpoint("/api/v3/plants/build")
    def plants_build(conn, hid, form):
        key = known((form.get("key") or "").strip())
        with econ.tx(conn):
            row = co.collect(conn, hid)
            if row["campus_level"] < g.FACTORIES[key][1]:
                raise econ.GameError("level", f"Unlocked at campus level {g.FACTORIES[key][1]}")
            if plant_row(conn, hid, key):
                raise econ.GameError("exists", "Already built: upgrade it instead")
            co.pay(conn, hid, g.factory_upgrade_cost(key, 0), "factory")
            conn.execute("INSERT INTO co_plants(hid, key) VALUES(?,?)", (hid, key))
            econ.emit(conn, "plant_upgraded", hid, {"key": key, "level": 1}, public=False)
            co.log(conn, hid, "plant", name=g.FACTORIES[key][0], level=1, cost=g.factory_upgrade_cost(key, 0))
        return {"err": 0, "level": 1}

    @api.endpoint("/api/v3/plants/upgrade")
    def plants_upgrade(conn, hid, form):
        key = known((form.get("key") or "").strip())
        with econ.tx(conn):
            co.collect(conn, hid)
            p = plant_row(conn, hid, key)
            if not p:
                raise econ.GameError("not_built", "Build it first")
            co.pay(conn, hid, g.factory_upgrade_cost(key, p["level"]), "factory")
            conn.execute("UPDATE co_plants SET level=level+1 WHERE hid=? AND key=?", (hid, key))
            econ.emit(conn, "plant_upgraded", hid, {"key": key, "level": p["level"] + 1}, public=False)
            co.log(conn, hid, "plant", name=g.FACTORIES[key][0], level=p["level"] + 1,
                   cost=g.factory_upgrade_cost(key, p["level"]))
        return {"err": 0, "level": p["level"] + 1}

    @api.endpoint("/api/v3/plants/recipe")
    def plants_recipe(conn, hid, form):
        key = known((form.get("key") or "").strip())
        recipe = int_arg(form, "recipe", lo=0, hi=len(g.FACTORIES[key][3]) - 1)
        with econ.tx(conn):
            co.collect(conn, hid)
            if not conn.execute("UPDATE co_plants SET recipe=? WHERE hid=? AND key=?", (recipe, hid, key)).rowcount:
                raise econ.GameError("not_built", "Build it first")
        return {"err": 0}

    @api.endpoint("/api/v3/plants/run")
    def plants_run(conn, hid, form):
        key = known((form.get("key") or "").strip())
        on = int_arg(form, "on", lo=0, hi=1)
        with econ.tx(conn):
            co.collect(conn, hid)
            if not conn.execute("UPDATE co_plants SET running=? WHERE hid=? AND key=?", (on, hid, key)).rowcount:
                raise econ.GameError("not_built", "Build it first")
        return {"err": 0, "running": bool(on)}

    def luxury_row(conn, hid):
        r = conn.execute("SELECT produced, invested FROM co_luxury WHERE hid=?", (hid,)).fetchone()
        return (r["produced"], r["invested"]) if r else (0.0, 0.0)

    @api.endpoint("/api/v3/luxury")
    def luxury(conn, hid, form):
        with econ.tx(conn):
            co.collect(conn, hid)
        produced, invested = luxury_row(conn, hid)
        top = [{"name": r["company_name"], "mg": round(r["produced"], 3), "you": r["hid"] == hid}
               for r in conn.execute("SELECT l.hid, l.produced, p.company_name FROM co_luxury l "
                                     "JOIN players p ON p.hID=l.hid WHERE l.produced>0 "
                                     "ORDER BY l.produced DESC LIMIT 20")]
        return {"err": 0, "heldMg": round(co.stock(conn, hid).get("ta180m", 0.0), 3),
                "producedMg": round(produced, 3), "investedMg": round(invested, 3), "top": top}

    def all_educated(conn, hid, row) -> bool:
        total = row["campus_level"] * g.SUPERVISORS_PER_LEVEL
        if total < g.CAMPUS_MAX * g.SUPERVISORS_PER_LEVEL:
            return False
        return conn.execute("SELECT COUNT(*) FROM co_supervisors WHERE hid=? AND edu>=4", (hid,)).fetchone()[0] >= total

    @api.endpoint("/api/v3/darkmatter")
    def darkmatter(conn, hid, form):
        with econ.tx(conn):
            row = co.collect(conn, hid)
        lv = row["dm_level"]
        return {"err": 0, "open": all_educated(conn, hid, row), "level": lv,
                "bonus": lv * g.DARK_MATTER_BONUS, "nextMg": g.dark_matter_cost_mg(lv + 1),
                "heldMg": round(co.stock(conn, hid).get("ta180m", 0.0), 3)}

    @api.endpoint("/api/v3/darkmatter/invest")
    def darkmatter_invest(conn, hid, form):
        with econ.tx(conn):
            row = co.collect(conn, hid)
            if not all_educated(conn, hid, row):
                raise econ.GameError("closed", "Dark matter research opens when all 500 supervisors are fully educated")
            mg = g.dark_matter_cost_mg(row["dm_level"] + 1)
            co.take_stock(conn, hid, "ta180m", mg)
            conn.execute("UPDATE co_state SET dm_level=dm_level+1 WHERE hid=?", (hid,))
            co.log(conn, hid, "dark_matter", level=row["dm_level"] + 1, mg=mg)
            conn.execute("UPDATE players SET xp=COALESCE(xp,0)+? WHERE hID=?",
                         (mg * g.ta180m_value_mg() * g.XP_PER_CREDIT["dark_matter"], hid))
            conn.execute("INSERT INTO co_luxury(hid, invested) VALUES(?,?) ON CONFLICT(hid) "
                         "DO UPDATE SET invested=invested+excluded.invested", (hid, mg))
        return {"err": 0, "level": row["dm_level"] + 1}
