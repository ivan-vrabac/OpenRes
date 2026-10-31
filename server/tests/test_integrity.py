"""Play Integrity: verdicts are kept, nobody is blocked unless enforcing, a token works only once."""
import json
import time

import main
from helpers import call, new_player
from systems import integrity as it

C, R = "/api/v3/integrity/challenge", "/api/v3/integrity/report"


def good(nonce):
    return {
        "requestDetails": {"requestPackageName": it.PACKAGE, "requestHash": nonce, "timestampMillis": str(int(time.time() * 1000))},
        "appIntegrity": {"appRecognitionVerdict": "PLAY_RECOGNIZED"},
        "deviceIntegrity": {"deviceRecognitionVerdict": ["MEETS_DEVICE_INTEGRITY"],
                            "recentDeviceActivity": {"deviceActivityLevel": "LEVEL_1"}},
        "accountDetails": {"appLicensingVerdict": "LICENSED"},
        "environmentDetails": {"playProtectVerdict": "NO_ISSUES", "appAccessRiskVerdict": {}},
    }


def row(hid):
    with main.get_db() as conn:
        return conn.execute("SELECT * FROM co_integrity WHERE hid=?", (hid,)).fetchone()


def setup(monkeypatch, payload=good):
    monkeypatch.setenv("INTEGRITY_CREDENTIALS", "/secret.json")
    holder = {}
    monkeypatch.setattr(it, "decode", lambda token: payload(holder["nonce"]))
    return holder


def test_without_a_key_nothing_is_asked(monkeypatch):
    monkeypatch.delenv("INTEGRITY_CREDENTIALS", raising=False)
    hid, sid, _ = new_player("ia")
    assert call(C, sid) == {"err": 0, "due": False}


def test_a_good_device_is_kept_and_not_asked_again(monkeypatch):
    holder = setup(monkeypatch)
    hid, sid, _ = new_player("ib")
    c = call(C, sid)
    holder["nonce"] = c["nonce"]
    assert c["due"] and call(R, sid, token="t", nonce=c["nonce"])["status"] == "checked"
    r = row(hid)
    assert r["ok"] == 1 and json.loads(r["problems"]) == []
    assert json.loads(r["verdict"])["playProtect"] == "NO_ISSUES"
    assert call(C, sid)["due"] is False


def test_each_bad_verdict_names_its_problem(monkeypatch):
    now = time.time() * 1000
    assert it.evaluate(good("n"), "n", now)[0] == []
    bad = good("n")
    bad["deviceIntegrity"]["deviceRecognitionVerdict"] = []
    assert it.evaluate(bad, "n", now)[0] == ["device_integrity"]
    bad = good("n")
    bad["appIntegrity"]["appRecognitionVerdict"] = "UNRECOGNIZED_VERSION"
    assert it.evaluate(bad, "n", now)[0] == ["app_not_recognized"]
    bad = good("n")
    bad["accountDetails"]["appLicensingVerdict"] = "UNLICENSED"
    assert it.evaluate(bad, "n", now)[0] == ["not_licensed"]
    assert it.evaluate(good("n"), "other", now)[0] == ["wrong_nonce"]
    assert it.evaluate(good("n"), "n", now + 3_600_000)[0] == ["old_token"]
    bad = good("n")
    bad["requestDetails"]["requestPackageName"] = "evil.app"
    assert it.evaluate(bad, "n", now)[0] == ["wrong_package"]


def test_a_nonce_works_once_and_only_its_own(monkeypatch):
    holder = setup(monkeypatch)
    hid, sid, _ = new_player("ic")
    assert call(R, sid, token="t", nonce="made-up")["code"] == "bad_nonce"
    c = call(C, sid)
    holder["nonce"] = c["nonce"]
    assert call(R, sid, token="t", nonce=c["nonce"])["status"] == "checked"
    assert call(R, sid, token="t", nonce=c["nonce"])["code"] == "bad_nonce"


def test_google_being_away_blocks_nobody_and_stores_nothing(monkeypatch):
    setup(monkeypatch)
    def down(token):
        raise OSError("no connection")
    monkeypatch.setattr(it, "decode", down)
    hid, sid, _ = new_player("id")
    c = call(C, sid)
    assert call(R, sid, token="t", nonce=c["nonce"])["status"] == "unavailable"
    assert row(hid)["checked_at"] is None and call(C, sid)["due"] is True


def place(sid, lat):
    return call("/api/v3/campus/place", sid, lat=lat, lng=20.0, plat=lat, plng=20.0)


def test_report_only_lets_everyone_build(monkeypatch):
    monkeypatch.delenv("INTEGRITY_ENFORCE", raising=False)
    hid, sid, _ = new_player("ie")
    call("/api/v3/state", sid)
    assert place(sid, 21.0)["err"] == 0


def test_enforcing_needs_a_good_verdict(monkeypatch):
    holder = setup(monkeypatch)
    monkeypatch.setenv("INTEGRITY_ENFORCE", "1")
    hid, sid, _ = new_player("if")
    call("/api/v3/state", sid)
    assert place(sid, 22.0)["code"] == "integrity"
    c = call(C, sid)
    holder["nonce"] = c["nonce"]
    call(R, sid, token="t", nonce=c["nonce"])
    assert place(sid, 22.0)["err"] == 0


def test_the_play_review_account_is_never_blocked(monkeypatch):
    monkeypatch.setenv("INTEGRITY_ENFORCE", "1")
    hid, sid, _ = new_player("ig")
    with main.get_db() as conn:
        conn.execute("UPDATE players SET company_name='PlayReview' WHERE hID=?", (hid,))
        conn.commit()
    call("/api/v3/state", sid)
    assert place(sid, 23.0)["err"] == 0
