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

