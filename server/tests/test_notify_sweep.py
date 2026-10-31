"""Notifications of things that happen on the clock: education, leases, a Campus move, full storage
(systems/notify.py game_sweep). Each is sent once, and each respects the player's settings."""
import datetime

import econ
import gamedata as g
import main
from helpers import call, new_player


def _inbox(hid):
    with main.get_db() as conn:
        return [r[0] for r in conn.execute("SELECT kind FROM notif_inbox WHERE hid=? ORDER BY id", (hid,))]


def _sweep():
    with main.get_db() as conn:
        return main.SYSTEM_HELPERS.game_sweep(conn)


def test_clock_notifications_are_sent_once():
    hid, sid, _ = new_player("nsw")
    call("/api/v3/state", sid)
    now = econ.utcnow()
    with main.get_db() as conn:
        conn.execute("UPDATE co_state SET campus_level=1 WHERE hid=?", (hid,))
        conn.execute("INSERT INTO co_education(hid, sup_id, to_step, finish_at) VALUES(?,?,?,?)",
                     (hid, 1, 1, (now - datetime.timedelta(minutes=5)).isoformat()))
        conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, item, quality, built_at, lease_until) VALUES(?,?,?,?,?,?,?,?)",
                     (hid, 33.0, 33.0, "logging_camp", "wood", 80, now.isoformat(),
                      (now + datetime.timedelta(days=2)).isoformat()))
        conn.execute("INSERT INTO co_moves(hid, lat, lng, started_at) VALUES(?,?,?,?)",
                     (hid, 33.1, 33.1, (now - datetime.timedelta(hours=g.MOVE_HOURS, minutes=5)).isoformat()))
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) DO UPDATE SET qty=excluded.qty",
                     (hid, "wood", g.storage_capacity(1)))
        conn.commit()
    _sweep()
    assert sorted(_inbox(hid)) == ["campus_arrived", "education_done", "lease_ending", "storage_full"]
    _sweep()
    assert len(_inbox(hid)) == 4                       # never twice


def test_switched_off_kind_is_not_sent():
    hid, sid, _ = new_player("nsw2")
    call("/api/v3/state", sid)
    assert call("/api/v1/notify/set", sid, kind="storage_full", enabled=0, maxPerDay=3)["err"] == 0
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) DO UPDATE SET qty=excluded.qty",
                     (hid, "clay", g.storage_capacity(1)))
        conn.commit()
    _sweep()
    assert "storage_full" not in _inbox(hid)
    kinds = {k["kind"] for k in call("/api/v1/notify/prefs", sid)["kinds"]}
    assert kinds >= {"order_filled", "education_done", "lease_ending", "campus_arrived", "storage_full"}


def _fill(hid, share):
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) DO UPDATE SET qty=excluded.qty",
                     (hid, "clay", g.storage_capacity(1) * share))
        conn.commit()


def test_storage_high_follows_the_players_threshold():
    hid, sid, _ = new_player("nsw3")
    call("/api/v3/state", sid)
    prefs = call("/api/v1/notify/prefs", sid)
    assert prefs["storageHigh"] == 75 and 90 in prefs["thresholds"]
    _fill(hid, 0.70)
    _sweep()
    assert "storage_high" not in _inbox(hid)           # below the default 75 %
    assert call("/api/v1/notify/storage_high", sid, percent=60)["storageHigh"] == 60
    _sweep()
    assert _inbox(hid).count("storage_high") == 1
    _sweep()
    assert _inbox(hid).count("storage_high") == 1      # once a day
    assert call("/api/v1/notify/storage_high", sid, percent=61)["err"] == 1


def test_a_full_storage_sends_only_the_full_notice():
    hid, sid, _ = new_player("nsw4")
    call("/api/v3/state", sid)
    _fill(hid, 1)
    _sweep()
    assert "storage_full" in _inbox(hid) and "storage_high" not in _inbox(hid)


def test_changing_the_limit_keeps_the_threshold():
    hid, sid, _ = new_player("nsw5")
    call("/api/v3/state", sid)
    call("/api/v1/notify/storage_high", sid, percent=90)
    assert call("/api/v1/notify/set", sid, kind="storage_high", enabled=1, maxPerDay=5)["storageHigh"] == 90
