"""Moderation (owner 2026-10-25): player reports, full bans, moderator actions."""
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
