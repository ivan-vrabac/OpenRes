"""Moderation (owner 2026-10-25): player reports, full bans, moderator actions."""
import os
import time

import pytest

import auth
import main
from helpers import call, client, new_player
from systems import moderation as M


def _pid(sid):
    return call("/api/v1/social/profile", sid)["profile"]["pid"]


@pytest.fixture
def modpw(monkeypatch):
    monkeypatch.setenv("MOD_PASSWORD", "mod-" + "secret-1")
    return "mod-" + "secret-1"


def test_report_a_player_and_dismiss_it(modpw):
    _, sid, _ = new_player("rp1")
    _, sid2, name2 = new_player("rp2")
    assert call("/api/v1/report", sid, kind="chat", id=1, reason="spam")["code"] == "bad_input"
    assert call("/api/v1/report", sid, kind="player", pid=_pid(sid), reason="spam")["code"] == "bad_input"
    assert call("/api/v1/report", sid, kind="player", pid=_pid(sid2), reason="cheating")["err"] == 0
    reps = [r for r in call("/api/v1/mod/reports", "", mod_password=modpw)["reports"] if r["target"] == name2]
    assert len(reps) == 1 and reps[0]["kind"] == "player"
    assert call("/api/v1/mod/act", "", mod_password=modpw, action="dismiss", report=reps[0]["id"])["err"] == 0
    assert not [r for r in call("/api/v1/mod/reports", "", mod_password=modpw)["reports"] if r["target"] == name2]


def test_full_ban_stops_sessions_and_sign_in(modpw):
    hid, sid, name = new_player("ban")
    assert auth.hid_from_sid(sid) == hid
    assert call("/api/v1/mod/act", "", mod_password=modpw, action="ban", pid=_pid(sid), reason="cheating")["err"] == 0
    assert auth.hid_from_sid(sid) == ""
    from helpers import _PW
    r = client.post("/api/v1/auth/session", data={"name": name, "password": _PW, "mode": "login"}).json()
    assert r["error"] == "banned" and "for good" in r["message"]
    with main.get_db() as conn:
        conn.execute("DELETE FROM player_bans WHERE hid=?", (hid,))
        conn.commit()
    M._ban_cache.clear()
    assert auth.hid_from_sid(sid) == hid


def test_shared_phone_shows_both_companies(modpw):
    dev = "ab" * 32
    _, s1, n1 = new_player("dv1")
    _, s2, n2 = new_player("dv2")
    assert call("/api/v1/device", s1, device=dev)["err"] == 0
    assert call("/api/v1/device", s2, device=dev)["err"] == 0
    assert call("/api/v1/device", s2, device="not-a-hash")["code"] == "bad_input"
    shared = call("/api/v1/mod/reports", "", mod_password=modpw)["sharedDevices"]
    names = [{c["name"] for c in x["companies"]} for x in shared]
    assert {n1, n2} in names


def test_any_company_can_be_banned_and_mistakes_undone_and_all_is_logged(modpw):
    pw = os.environ["MOD_PASSWORD"]
    mod = lambda path, **f: call(path, "", mod_password=pw, **f)
    hid, sid = new_player("Listed Co")[:2]
    pid = _pid(sid)
    with main.get_db() as conn:
        name = conn.execute("SELECT company_name FROM players WHERE hID=?", (hid,)).fetchone()[0]
    row = next(c for c in mod("/api/v1/mod/reports", q=name)["companies"] if c["pid"] == pid)
    assert row["pid"] == pid and row["banned"] is False
    assert mod("/api/v1/mod/reports", q="no such company")["companies"] == []

    assert mod("/api/v1/mod/act", action="ban", pid=pid, hours="2", reason="spam")["err"] == 0
    assert next(c for c in mod("/api/v1/mod/reports", q=name)["companies"] if c["pid"] == pid)["banned"] is True
    assert mod("/api/v1/mod/act", action="unban", pid=pid)["err"] == 0

    with main.get_db() as conn:
        cid = conn.execute("INSERT INTO contact_messages(ts, topic, message) VALUES('2026-10-31T00:00:00','other','hello there')").lastrowid
        conn.commit()
    assert mod("/api/v1/mod/act", action="contact_done", contact=cid)["err"] == 0
    got = mod("/api/v1/mod/reports")
    assert cid not in [c["id"] for c in got["contact"]] and cid in [c["id"] for c in got["doneContact"]]
    assert mod("/api/v1/mod/act", action="contact_reopen", contact=cid)["err"] == 0
    got = mod("/api/v1/mod/reports")
    assert cid in [c["id"] for c in got["contact"]]
    log = [(x["action"], x["target"]) for x in got["log"]]
    assert ("ban", name) in log and ("unban", name) in log and ("contact_reopen", f"message #{cid}") in log
    assert any("2 hours" in x["detail"] and "spam" in x["detail"] for x in got["log"] if x["action"] == "ban")


def test_a_moderator_renames_a_company_without_asking(modpw):
    hid, sid, name = new_player("mren")
    other = new_player("mrtwo")[2]
    act = lambda **f: call("/api/v1/mod/act", "", mod_password=modpw, action="rename", pid=_pid(sid), **f)
    assert act(name="Company 4711")["err"] == 0
    with main.get_db() as conn:
        assert conn.execute("SELECT company_name, COALESCE(name_changes,0) FROM players WHERE hID=?", (hid,)).fetchone()[:2] == ("Company 4711", 0)
        assert conn.execute("SELECT detail FROM mod_log ORDER BY id DESC LIMIT 1").fetchone()[0].endswith(f"was {name}")
    assert act(name=other)["code"] == "name_taken"
    assert act(name="x")["code"] == "invalid_name"


def test_cheat_signals_suspects_archive_and_wipe(modpw):
    """Owner 2026-11-06: jumps, failed device checks and fake GPS are kept; a moderator sees the suspects,
    archives them, or bans and wipes the whole game."""
    hid, sid, name = new_player("chs1")
    from test_company import BASE
    at = (BASE[0] - 2.47, BASE[1] + 1.9)
    assert call("/api/v3/campus/place", sid, lat=at[0], lng=at[1], plat=at[0], plng=at[1])["err"] == 0
    far = (at[0] + 9, at[1])                                        # 1 000 km at once
    assert call("/api/v3/campus/place", sid, lat=far[0], lng=far[1], plat=far[0], plng=far[1])["code"] == "teleport"
    assert call("/api/v1/signal", sid, kind="mock_gps", lat=1, lng=2)["err"] == 0
    assert call("/api/v1/signal", sid, kind="mock_gps")["err"] == 0          # once per 10 minutes
    assert call("/api/v1/signal", sid, kind="speed")["code"] == "bad_input"
    d = call("/api/v1/mod/reports", "", mod_password=modpw)
    me = next(x for x in d["suspects"] if x["name"] == name)
    assert me["kinds"] == {"teleport": 1, "mock_gps": 1} and me["campus"] == 1
    pid = me["pid"]
    c = call("/api/v1/mod/company", "", mod_password=modpw, pid=pid)
    assert c["name"] == name and len(c["signals"]) == 2 and "km/h" in next(s for s in c["signals"]
                                                                         if s["kind"] == "teleport")["detail"]
    assert call("/api/v1/mod/act", "", mod_password=modpw, action="signals_done", pid=pid)["err"] == 0
    d = call("/api/v1/mod/reports", "", mod_password=modpw)
    assert not [x for x in d["suspects"] if x["name"] == name] and [x for x in d["archivedSignals"] if x["name"] == name]
    assert call("/api/v1/mod/act", "", mod_password=modpw, action="wipe", pid=pid, confirm="nope")["code"] == "bad_input"
    assert call("/api/v1/mod/act", "", mod_password=modpw, action="wipe", pid=pid, confirm=name)["err"] == 0
    with main.get_db() as conn:
        assert not conn.execute("SELECT 1 FROM co_hexes WHERE hid=?", (hid,)).fetchone()
        assert conn.execute("SELECT credits FROM players WHERE hID=?", (hid,)).fetchone()[0] == 0
        assert M.active_ban(conn, hid) is not None


def test_retention_is_30_days_up_to_the_privacy_policy(modpw):
    act = lambda **kw: call("/api/v1/mod/act", "", mod_password=modpw, action="retention", **kw)
    assert act(key="reports", days=29)["code"] == "bad_input"
    assert act(key="reports", days=366)["code"] == "bad_input"
    assert act(key="nothing", days=60)["code"] == "bad_input"
    assert act(key="cheat_signals", days=90)["err"] == 0
    r = {x["key"]: x for x in call("/api/v1/mod/reports", "", mod_password=modpw)["retention"]}
    assert r["cheat_signals"]["days"] == 90 and r["reports"]["max"] == 365
    import datetime
    import econ
    with main.get_db() as conn:
        old = (econ.utcnow() - datetime.timedelta(days=100)).isoformat()
        conn.execute("INSERT INTO cheat_signals(ts, hid, kind) VALUES(?,?,?)", (old, "x" * 32, "teleport"))
        with econ.tx(conn):
            M.prune(conn)
        assert not conn.execute("SELECT 1 FROM cheat_signals WHERE ts=?", (old,)).fetchone()
        conn.execute("DELETE FROM mod_settings")
        conn.commit()
