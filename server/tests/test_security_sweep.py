"""Phase 11: cross-system checks — every v1 route needs a valid session, and no response leaks
another player's internal id (hID)."""
import json
import zlib

import econ
import main
from helpers import call, client, new_player

OPEN_ROUTES = {"/api/v1/auth/session", "/api/v1/auth/status", "/api/v1/auth/claim",
               "/api/v1/legal", "/api/v1/contact",
               "/api/v1/auth/config", "/api/v1/auth/google", "/api/v1/auth/google/delete",
               "/api/v1/mod/reports", "/api/v1/mod/act"}   # moderator password instead of a session   # shown / usable before sign-in


def _v1_routes():
    return sorted({r.path for r in main.app.routes
                   if getattr(r, "path", "").startswith(("/api/v1/", "/api/v3/"))} - OPEN_ROUTES)


def test_every_v1_and_v3_route_rejects_missing_or_forged_session():
    routes = _v1_routes()
    assert len(routes) > 60
    for path in routes:
        for sid in ("", "forged", "eyJoSUQiOiAieCJ9"):
            r = client.post(path, data={"sid": sid})
            if r.status_code == 405:
                continue
            body = json.loads(zlib.decompress(r.content)) if r.headers.get("content-type", "").startswith(
                "application/octet") or r.content[:1] == b"x" else r.json()
            assert body.get("err") or body.get("error"), (path, sid, body)


def test_no_foreign_hid_in_responses():
    a, a_sid, _ = new_player("sx1", credits=10**10)
    b, b_sid, b_name = new_player("sx2", credits=10**10)
    for h in (a, b):
        with main.get_db() as conn:
            conn.execute("UPDATE players SET created_at='2020-01-01 00:00:00' WHERE hID=?", (h,))
            conn.execute("INSERT INTO ledger(ts, hid, kind, credits) VALUES(?,?,?,?)",
                         (econ.utcnow_iso(), h, "system_sell", 10**8))
            conn.commit()
    call("/api/v3/state", a_sid)
    call("/api/v3/state", b_sid)
    assert call("/api/v3/campus/place", b_sid, lat=45.1, lng=15.1, plat=45.1, plng=15.1)["err"] == 0
    responses = [
        call("/api/v1/rank/players", a_sid),
        call("/api/v1/market/overview", a_sid),
    ]
    for r in responses:
        assert b not in json.dumps(r), r


def test_public_health_check_is_cors_readable_and_leaks_nothing():
    r = client.get("/api/v1/health")
    assert r.status_code == 200 and r.json()["ok"] is True
    assert r.headers["access-control-allow-origin"] == "*"
    assert set(r.json()) == {"ok", "time"}
