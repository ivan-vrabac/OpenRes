"""Shared foundations: atomic, non-negative, audited money/item movements."""
import sqlite3
import threading

import pytest

import econ
import main


def _player(conn, hid, credits=1000, wh_level=1):
    conn.execute("INSERT OR REPLACE INTO players(hID, company_name, credits, wh_level) VALUES(?,?,?,?)",
                 (hid, "econ " + hid[:6], credits, wh_level))
    conn.commit()


def test_debit_never_negative_and_rolls_back():
    with main.get_db() as conn:
        _player(conn, "e1" * 16, credits=100)
        with pytest.raises(econ.GameError):
            with econ.tx(conn):
                econ.credit(conn, "e1" * 16, 50, "test")
                econ.debit(conn, "e1" * 16, 1000, "test")   # fails -> whole tx rolled back
        assert econ.credits_of(conn, "e1" * 16) == 100
        with econ.tx(conn):
            econ.debit(conn, "e1" * 16, 100, "test")
        assert econ.credits_of(conn, "e1" * 16) == 0
        rows = conn.execute("SELECT credits FROM ledger WHERE hid=?", ("e1" * 16,)).fetchall()
        assert [r[0] for r in rows] == [-100]                # only the committed movement is audited


def test_concurrent_debits_never_overspend():
    hid = "e3" * 16
    with main.get_db() as conn:
        _player(conn, hid, credits=1000)
    ok, fail = [], []

    def worker():
        c = main.get_db()
        try:
            with econ.tx(c):
                econ.debit(c, hid, 300, "race")
            ok.append(1)
        except econ.GameError:
            fail.append(1)
        finally:
            c.close()

    threads = [threading.Thread(target=worker) for _ in range(10)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    with main.get_db() as conn:
        assert len(ok) == 3 and len(fail) == 7
        assert econ.credits_of(conn, hid) == 100


def test_idempotency_and_event_dedup():
    with main.get_db() as conn:
        assert econ.once_get(conn, "claim", "h", "k1") is None
        econ.once_put(conn, "claim", "h", "k1", {"reward": 5})
        assert econ.once_get(conn, "claim", "h", "k1") == {"reward": 5}
        with pytest.raises(sqlite3.IntegrityError):
            econ.once_put(conn, "claim", "h", "k1", {"reward": 5})
        econ.emit(conn, "quake", None, {"m": 6}, dedup="quake:2026-10-19")
        econ.emit(conn, "quake", None, {"m": 6}, dedup="quake:2026-10-19")
        conn.commit()
        assert conn.execute("SELECT COUNT(*) FROM game_events WHERE dedup='quake:2026-10-19'").fetchone()[0] == 1


def test_rate_limit():
    rl = econ.RateLimit(2, 60)
    assert rl.allow("a") and rl.allow("a") and not rl.allow("a") and rl.allow("b")
