import base64
import json
import zlib

from fastapi.testclient import TestClient

import auth
import main

client = TestClient(main.app)


def signin(name, password):
    return client.post("/api/v1/auth/session", data={"name": name, "password": password})


def forged_sid(hid: str) -> str:
    return base64.b64encode(json.dumps({"hID": hid}).encode()).decode().rstrip("=")


def player_data(sid: str):
    return json.loads(zlib.decompress(client.post("/api/v3/me", data={"sid": sid}).content))


def test_register_then_login():
    r = signin("Alpha Corp", "hunter22")
    assert r.status_code == 200 and r.json()["created"] is True
    hid = r.json()["hID"]
    r2 = signin("alpha corp", "hunter22")  # names are case-insensitive
    assert r2.status_code == 200 and r2.json()["created"] is False
    assert r2.json()["hID"] == hid
    assert player_data(r2.json()["sid"])["hID"] == hid


def test_wrong_password_rejected():
    signin("Beta Corp", "correct-horse")
    r = signin("Beta Corp", "wrong-horse")
    assert r.status_code == 401
    assert "sid" not in r.json()


def test_weak_password_rejected():
    r = signin("Gamma Corp", "123")
    assert r.json()["error"] == "weak_password"


def test_invalid_name_rejected():
    assert signin("x" * 21, "longenough").json()["error"] == "invalid_name"
    r = signin("<script>", "longenough")
    assert r.json()["error"] == "invalid_name"


def test_forged_unsigned_sid_rejected():
    hid = signin("Delta Corp", "password1").json()["hID"]
    assert player_data(forged_sid(hid))["code"] == "auth"


def test_tampered_signature_rejected():
    sid = signin("Epsilon Corp", "password1").json()["sid"]
    data = json.loads(base64.b64decode(sid + "=" * (-len(sid) % 4)))
    data["hID"] = "0" * 32
    tampered = base64.b64encode(json.dumps(data).encode()).decode().rstrip("=")
    assert auth.hid_from_sid(tampered) == ""


def test_expired_session_rejected(monkeypatch):
    sid = signin("Zeta Corp", "password1").json()["sid"]
    assert auth.hid_from_sid(sid)
    monkeypatch.setattr(auth, "SESSION_TTL_S", -1)
    assert auth.hid_from_sid(sid) == ""


def test_rate_limit_after_repeated_failures():
    signin("Iota Corp", "password1")
    for _ in range(auth.limiter.limit):
        signin("Iota Corp", "nope-nope")
    r = signin("Iota Corp", "password1")  # even the right password is blocked for now
    assert r.status_code == 429
    auth.limiter.reset("name:iota corp", "ip:testclient")


def test_change_password():
    sid = signin("Kappa Corp", "old-password").json()["sid"]
    url = "/api/v1/auth/password"
    assert client.post(url, data={"sid": sid, "old_password": "nope-nope",
                                  "new_password": "new-password"}).status_code == 401
    assert client.post(url, data={"sid": sid, "old_password": "old-password",
                                  "new_password": "x"}).json()["error"] == "weak_password"
    assert client.post(url, data={"sid": forged_sid("whatever"), "old_password": "old-password",
                                  "new_password": "new-password"}).status_code == 401
    r = client.post(url, data={"sid": sid, "old_password": "old-password", "new_password": "new-password"})
    assert r.json() == {"ok": True}
    assert signin("Kappa Corp", "old-password").status_code == 401
    assert signin("Kappa Corp", "new-password").status_code == 200


def test_legacy_mode_accepts_unsigned_sessions(monkeypatch):
    hid = signin("Lambda Corp", "password1").json()["hID"]
    assert auth.hid_from_sid(forged_sid(hid)) == ""
    monkeypatch.setattr(auth, "AUTH_MODE", "legacy")
    assert auth.hid_from_sid(forged_sid(hid)) == hid


def test_login_and_register_modes():
    r = client.post("/api/v1/auth/session", data={"name": "Mu Corp", "password": "password1", "mode": "login"})
    assert r.json()["error"] == "not_found"
    r = client.post("/api/v1/auth/session", data={"name": "Mu Corp", "password": "password1", "mode": "register"})
    assert r.status_code == 200 and r.json()["created"] is True
    r = client.post("/api/v1/auth/session", data={"name": "mu corp", "password": "other-pass", "mode": "register"})
    assert r.json()["error"] == "name_taken"
    r = client.post("/api/v1/auth/session", data={"name": "Mu Corp", "password": "password1", "mode": "login"})
    assert r.status_code == 200 and r.json()["created"] is False


def test_other_players_internal_ids_not_exposed():
    a = signin("Omicron Corp", "password1").json()
    b = signin("Pi Corp", "password1").json()
    call = lambda path, sid, **f: json.loads(zlib.decompress(client.post(path, data={"sid": sid, **f}).content))  # noqa: E731
    assert call("/api/v3/campus/place", a["sid"], lat=10.0, lng=10.0, plat=10.0, plng=10.0)["err"] == 0
    box = dict(south=9.999, west=9.999, north=10.001, east=10.001)
    hexes = call("/api/v3/map", b["sid"], **box)
    ranks = [call(f"/api/v1/rank/{board}", b["sid"]) for board in ("players", "campus", "countries", "tantalum")]
    blob = json.dumps([hexes, ranks])
    assert a["hID"] not in blob
    assert any(c["name"] == "Omicron Corp" and not c["own"] for c in hexes["campuses"])   # shown as typed
    assert hexes["hexes"] and not any(h["own"] for h in hexes["hexes"])


def test_password_hash_roundtrip():
    h = auth.hash_password("s3cret!")
    assert h.startswith("scrypt$") and "s3cret" not in h
    assert auth.verify_password("s3cret!", h)
    assert not auth.verify_password("s3cret?", h)


def test_unprotected_legacy_account_needs_admin(monkeypatch):
    with main.get_db() as conn:
        conn.execute("INSERT INTO players(hID, company_name) VALUES('legacyhid0000000000000000000001', 'old co')")
        conn.commit()
    r = signin("Old Co", "password1")
    assert r.json()["error"] == "no_password"
    monkeypatch.setattr(auth, "LEGACY_CLAIM", True)
    r = signin("Old Co", "password1")
    assert r.status_code == 200 and r.json()["hID"] == "legacyhid0000000000000000000001"
