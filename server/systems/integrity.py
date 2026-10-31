"""Play Integrity (owner 2026-10-31): is this our real app, from Google Play, on a real device?

The phone asks for a challenge, gets a token for it from Google Play and hands it in; the server has
Google decode it and keeps the verdict. Once per player per CHECK_HOURS, so the 10,000 requests a day
last (a check costs one token and one decryption).

Report only by default: verdicts are stored and nobody is blocked. INTEGRITY_ENFORCE=1 makes
`require` refuse building and placing without a good, recent verdict; look at the stored verdicts
first, honest players on odd phones can fail too.

Needs a service account key of the Cloud project linked in Play Console (INTEGRITY_CREDENTIALS, the
path of its JSON file). Without one the check is simply skipped ("not_configured").

  challenge             a fresh value to bind the token to; `due` says whether a check is needed
  report  token nonce   the verdict for this device
"""
from __future__ import annotations

import datetime
import json
import os
import secrets
import time

import econ

PACKAGE = os.environ.get("INTEGRITY_PACKAGE", "resources.vrabac.eu")
CHECK_HOURS = 24
VALID_HOURS = 72                # enforcing: how long a good verdict lasts
NONCE_S = 300
TOKEN_AGE_S = 300               # a token older than this is refused
EXEMPT = {"PlayReview"}         # Google's reviewers test on emulators
SCOPE = "https://www.googleapis.com/auth/playintegrity"

_credentials = None


def enforcing() -> bool:
    return os.environ.get("INTEGRITY_ENFORCE", "0") == "1"


def configured() -> bool:
    return bool(os.environ.get("INTEGRITY_CREDENTIALS"))


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS co_integrity (
            hid         TEXT PRIMARY KEY,
            ok          INTEGER NOT NULL DEFAULT 0,      -- real app, real device, licensed
            problems    TEXT NOT NULL DEFAULT '[]',      -- why not
            verdict     TEXT NOT NULL DEFAULT '{}',      -- what Google said, for looking at it later
            checked_at  TEXT,
            nonce       TEXT,
            nonce_until REAL
        );
    """)
    conn.commit()


def decode(token: str) -> dict:
    """Google's verdict for a token (the payload). Replaced in the tests."""
    global _credentials
    import google.auth.transport.requests as google_requests
    import httpx
    from google.oauth2 import service_account
    if _credentials is None:
        _credentials = service_account.Credentials.from_service_account_file(
            os.environ["INTEGRITY_CREDENTIALS"], scopes=[SCOPE])
    if not _credentials.valid:
        _credentials.refresh(google_requests.Request())
    r = httpx.post(f"https://playintegrity.googleapis.com/v1/{PACKAGE}:decodeIntegrityToken",
                   headers={"Authorization": f"Bearer {_credentials.token}"},
                   json={"integrity_token": token}, timeout=15)
    r.raise_for_status()
    return r.json()["tokenPayloadExternal"]


def evaluate(payload: dict, nonce: str, now_ms: float) -> tuple[list, dict]:
    """(what is wrong, the verdict worth keeping) of a decoded token."""
    req = payload.get("requestDetails", {})
    app = payload.get("appIntegrity", {})
    device = payload.get("deviceIntegrity", {})
    account = payload.get("accountDetails", {})
    env = payload.get("environmentDetails", {})
    labels = device.get("deviceRecognitionVerdict", [])
    problems = []
    if req.get("requestPackageName") != PACKAGE:
        problems.append("wrong_package")
    if req.get("requestHash") != nonce:
        problems.append("wrong_nonce")
    if abs(now_ms - float(req.get("timestampMillis", 0))) > TOKEN_AGE_S * 1000:
        problems.append("old_token")
    if app.get("appRecognitionVerdict") != "PLAY_RECOGNIZED":
        problems.append("app_not_recognized")
    if "MEETS_DEVICE_INTEGRITY" not in labels:
        problems.append("device_integrity")
    if account.get("appLicensingVerdict") != "LICENSED":
        problems.append("not_licensed")
    return problems, {
        "app": app.get("appRecognitionVerdict"), "device": labels, "license": account.get("appLicensingVerdict"),
        "playProtect": env.get("playProtectVerdict"), "accessRisk": env.get("appAccessRiskVerdict"),
        "activity": device.get("recentDeviceActivity", {}).get("deviceActivityLevel"),
    }


def _name(conn, hid) -> str:
    r = conn.execute("SELECT company_name FROM players WHERE hID=?", (hid,)).fetchone()
    return r[0] if r else ""


def require(conn, hid) -> None:
    """Refuses when enforcing and the player has no good, recent verdict."""
    if not enforcing() or _name(conn, hid) in EXEMPT:
        return
    r = conn.execute("SELECT ok, checked_at FROM co_integrity WHERE hid=?", (hid,)).fetchone()
    limit = econ.utcnow() - datetime.timedelta(hours=VALID_HOURS)
    if not r or not r["ok"] or not r["checked_at"] or datetime.datetime.fromisoformat(r["checked_at"]) < limit:
        raise econ.GameError("integrity", "This needs the app from Google Play on a real device.")


def install(api) -> None:
    with api.h.get_db() as conn:
        init_schema(conn)

    @api.endpoint("/api/v3/integrity/challenge")
    def challenge(conn, hid, form):
        r = conn.execute("SELECT checked_at FROM co_integrity WHERE hid=?", (hid,)).fetchone()
        due = configured() and _name(conn, hid) not in EXEMPT and not (r and r["checked_at"] and (
            econ.utcnow() - datetime.datetime.fromisoformat(r["checked_at"])).total_seconds() < CHECK_HOURS * 3600)
        if not due:
            return {"err": 0, "due": False}
        nonce = secrets.token_urlsafe(32)
        with econ.tx(conn):
            conn.execute("INSERT INTO co_integrity(hid, nonce, nonce_until) VALUES(?,?,?) ON CONFLICT(hid) "
                         "DO UPDATE SET nonce=excluded.nonce, nonce_until=excluded.nonce_until",
                         (hid, nonce, time.time() + NONCE_S))
        return {"err": 0, "due": True, "nonce": nonce}

    @api.endpoint("/api/v3/integrity/report")
    def report(conn, hid, form):
        token, nonce = form.get("token") or "", form.get("nonce") or ""
        r = conn.execute("SELECT nonce, nonce_until FROM co_integrity WHERE hid=?", (hid,)).fetchone()
        if not token or not r or not r["nonce"] or r["nonce"] != nonce or (r["nonce_until"] or 0) < time.time():
            raise econ.GameError("bad_nonce", "Try again")
        with econ.tx(conn):
            conn.execute("UPDATE co_integrity SET nonce=NULL WHERE hid=?", (hid,))   # one use
        if not configured():
            return {"err": 0, "status": "not_configured"}
        try:
            payload = decode(token)
        except Exception:
            return {"err": 0, "status": "unavailable"}     # Google's side: the next check tries again
        problems, verdict = evaluate(payload, nonce, time.time() * 1000)
        with econ.tx(conn):
            conn.execute("UPDATE co_integrity SET ok=?, problems=?, verdict=?, checked_at=? WHERE hid=?",
                         (0 if problems else 1, json.dumps(problems), json.dumps(verdict), econ.utcnow_iso(), hid))
        return {"err": 0, "status": "checked"}
