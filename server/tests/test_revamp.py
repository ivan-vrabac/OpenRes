"""Economy revamp (owner 2026-10-23): atomic legacy endpoints, XP only from permanent sinks,
working atmosphere, accidents, strikes, penalties, travel check."""
import datetime
import json
import threading
import zlib

import econ
import main
from helpers import call, client, credits, give, new_player


def game(path, sid, **form):
    """A game endpoint (/api/game/...), decoded."""
    r = client.post(path, data={"sid": sid, **{k: str(v) for k, v in form.items()}})
    return json.loads(zlib.decompress(r.content))


def xp(hid):
    with main.get_db() as conn:
        return conn.execute("SELECT xp FROM players WHERE hID=?", (hid,)).fetchone()[0]


def test_teleporting_is_refused():
    hid, sid, _ = new_player("rvt", credits=1_000_000)
    with main.get_db() as conn:
        with econ.tx(conn):
            main.check_travel(conn, hid, 45.0, 15.0)
        try:
            with econ.tx(conn):
                main.check_travel(conn, hid, 48.0, 15.0)        # 333 km a moment later
            assert False, "teleport accepted"
        except econ.GameError as e:
            assert e.code == "teleport"
        with econ.tx(conn):
            main.check_travel(conn, hid, 45.01, 15.0)           # 1 km: fine


def test_rename_costs_and_rules():
    hid, sid, name = new_player("rvn", credits=0)
    assert call("/api/v1/account/rename", sid, name="F.u.c.k Ltd")["code"] == "invalid_name"
    r = call("/api/v1/account/rename", sid, name="Clean Mining")
    assert r["err"] == 0 and r["cost"] == 0 and r["nextCost"] == 100_000              # first change free
    assert call("/api/v1/account/rename", sid, name="Clean Mining Two")["code"] == "insufficient_credits"
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=100000 WHERE hID=?", (hid,))
        conn.commit()
    r = call("/api/v1/account/rename", sid, name="Clean Mining Two")
    assert r["cost"] == 100_000 and r["nextCost"] == 200_000 and credits(hid) == 0
    r = client.post("/api/v1/auth/session", data={"name": "Clean Mining Two", "password": "password1", "mode": "login"})
    assert r.json()["hID"] == hid                                                   # signs in with the new name


def test_gdpr_delete_young_now_old_after_30_days_login_cancels():
    hid, sid, name = new_player("rvg")
    give(hid, "wood", 100)
    r = call("/api/v1/account/delete", sid, confirm="DELETE")
    assert r["deleted"] is True
    with main.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM players WHERE hID=?", (hid,)).fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM co_stock WHERE hid=?", (hid,)).fetchone()[0] == 0
    r = client.post("/api/v1/auth/session", data={"name": name, "password": "password1", "mode": "register"})
    assert r.json().get("created") is True                                          # the name is free again
    old, old_sid, old_name = new_player("rvo")
    with main.get_db() as conn:
        conn.execute("UPDATE players SET created_at='2026-01-01T00:00:00' WHERE hID=?", (old,))
        conn.commit()
    r = call("/api/v1/account/delete", old_sid, confirm="DELETE")
    assert r["deleted"] is False and r["deleteAt"]
    r = client.post("/api/v1/auth/session", data={"name": old_name, "password": "password1", "mode": "login"})
    assert r.json()["deletionCancelled"] is True
    assert call("/api/v1/account/info", old_sid)["deleteAt"] is None


def test_notification_kinds_defaults_and_limits():
    hid, sid, _ = new_player("rvq")
    r = call("/api/v1/notify/prefs", sid)
    by = {k["kind"]: k for k in r["kinds"]}
    assert set(by) == {"order_filled", "education_done", "lease_ending", "campus_arrived", "storage_high", "storage_full"}   # 0.2.3 kinds
    assert by["order_filled"]["enabled"] and by["order_filled"]["maxPerDay"] == 20
    r = call("/api/v1/notify/set", sid, kind="order_filled", enabled=1, maxPerDay=0)        # unlimited allowed
    assert {k["kind"]: k for k in r["kinds"]}["order_filled"]["maxPerDay"] == 0
    assert call("/api/v1/notify/set", sid, kind="order_filled", maxPerDay=7)["code"] == "bad_input"
    r = call("/api/v1/notify/set", sid, kind="order_filled", enabled=0, maxPerDay=10)
    assert {k["kind"]: k for k in r["kinds"]}["order_filled"]["enabled"] is False
