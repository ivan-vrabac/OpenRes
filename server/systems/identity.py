"""Sign in with Google only (owner 2026-10-25).

The app (and the website's account-deletion page) send the ID token Google gave them; we check it
(signature, audience = one of GOOGLE_CLIENT_IDS, issuer, expiry). Then:
- a known Google account signs in;
- a new one either names a new company (`name`), or links an existing company once with its old
  company name + password (`link_name`, `link_password`); the password is then removed, so the
  company signs in with Google from then on.

GOOGLE_CLIENT_IDS (environment, comma separated): the OAuth client IDs tokens may be issued for (the
Web client ID the app and the website ask Google for). Without it Google sign-in is off and the old
password sign-in stays as it was.

Play Games gives the app a one-time code instead; with GOOGLE_CLIENT_SECRET (of the game server client,
one of GOOGLE_CLIENT_IDS) we swap it for an ID token of the same Google account, and the app signs in
with that as above, so a company keeps working whichever way its player comes in.
"""
from __future__ import annotations

import os
import time

import econ

CERTS_URL = "https://www.googleapis.com/oauth2/v1/certs"
TOKEN_URL = "https://oauth2.googleapis.com/token"
ISSUERS = ("accounts.google.com", "https://accounts.google.com")

_certs = {"at": 0.0, "certs": {}}


def google_client_ids() -> list:
    return [x.strip() for x in os.environ.get("GOOGLE_CLIENT_IDS", "").split(",") if x.strip()]


def google_only() -> bool:
    """With Google set up, new companies can only be made through Google."""
    return bool(google_client_ids())


def _google_certs() -> dict:
    if time.time() - _certs["at"] > 3600 or not _certs["certs"]:
        import httpx
        _certs["certs"] = httpx.get(CERTS_URL, timeout=10).json()
        _certs["at"] = time.time()
    return _certs["certs"]


def verify_google(token: str) -> dict:
    """The verified claims of a Google ID token, or GameError."""
    ids = google_client_ids()
    if not ids:
        raise econ.GameError("disabled", "Google sign-in is not set up on this server")
    from google.auth import jwt
    try:
        # clock skew allowed (owner 2026-10-25: sign-in failed 2-3 times before working: our clock was
        # ~3 s behind Google's, so a fresh token looked "used too early")
        claims = jwt.decode(token, certs=_google_certs(), audience=ids, clock_skew_in_seconds=300)
    except Exception as e:
        print(f"google token rejected: {e}", flush=True)
        raise econ.GameError("bad_token", "Google sign-in failed. Please try again.")
    if claims.get("iss") not in ISSUERS or not claims.get("sub"):
        raise econ.GameError("bad_token", "Google sign-in failed. Please try again.")
    return claims


def play_games_token(code: str, client_id: str) -> str:
    """The ID token for a Play Games one-time code, or GameError (also when the player kept back the
    openid scope: then the app just offers the Google button)."""
    secret = os.environ.get("GOOGLE_CLIENT_SECRET", "")
    if not secret or client_id not in google_client_ids():
        raise econ.GameError("disabled", "Play Games sign-in is not set up on this server")
    import httpx
    try:
        r = httpx.post(TOKEN_URL, timeout=10, data={"code": code, "client_id": client_id, "client_secret": secret,
                                                    "grant_type": "authorization_code", "redirect_uri": ""})
        token = r.json().get("id_token") if r.status_code == 200 else None
    except Exception as e:
        print(f"play games code exchange failed: {type(e).__name__}", flush=True)
        token = None
    if not token:
        raise econ.GameError("bad_token", "Play Games sign-in failed. Please try again.")
    return token


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS auth_identities (
            provider   TEXT NOT NULL,
            subject    TEXT NOT NULL,
            hid        TEXT NOT NULL,
            email      TEXT,
            created_at TEXT NOT NULL,
            PRIMARY KEY (provider, subject)
        );
        CREATE INDEX IF NOT EXISTS idx_identities_hid ON auth_identities(hid);
    """)


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)
        conn.commit()

    @api.endpoint("/api/v1/auth/config", auth=False)
    def config(conn, hid, form):
        """What the login screen offers."""
        return {"err": 0, "google": bool(google_client_ids()), "googleOnly": google_only()}

    @api.endpoint("/api/v1/auth/google", auth=False)
    def google(conn, hid, form):
        """id_token, and for a Google account we don't know yet either `name` (new company) or
        `link_name` + `link_password` (an existing company, once). Returns {sid, hID, created, name}
        or the code need_name."""
        claims = verify_google((form.get("id_token") or "").strip())
        sub = str(claims["sub"])
        email = (claims.get("email") or "").lower() if claims.get("email_verified") else None
        with econ.tx(conn):
            row = conn.execute("SELECT hid FROM auth_identities WHERE provider='google' AND subject=?", (sub,)).fetchone()
            hid2, created = (row[0] if row else None), False
            if not hid2:
                link_name = (form.get("link_name") or "").strip()
                name = (form.get("name") or "").strip()
                if link_name:
                    hid2 = h.check_password_login(conn, link_name, form.get("link_password") or "")
                    if conn.execute("SELECT 1 FROM auth_identities WHERE hid=?", (hid2,)).fetchone():
                        raise econ.GameError("already_linked", "This company already signs in with another Google account")
                    h.remove_password(conn, hid2)          # Google only from now on
                elif name:
                    hid2 = h.create_company(conn, name)
                    created = True
                else:
                    raise econ.GameError("need_name", "Choose a name for your company")
                conn.execute("INSERT INTO auth_identities(provider, subject, hid, email, created_at) "
                             "VALUES('google',?,?,?,?)", (sub, hid2, email, econ.utcnow_iso()))
            ban = h.is_banned(hid2)
            if ban:
                from . import moderation
                raise econ.GameError("banned", moderation.ban_text(ban))
            conn.execute("UPDATE players SET delete_at=NULL WHERE hID=?", (hid2,))
            p = conn.execute("SELECT company_name FROM players WHERE hID=?", (hid2,)).fetchone()
        return {"err": 0, "hID": hid2, "sid": h.make_sid(hid2), "created": created, "name": p[0] if p else ""}

    @api.endpoint("/api/v1/auth/play_games", auth=False)
    def play_games(conn, hid, form):
        """code + client_id from Play Games: returns the id_token for /api/v1/auth/google."""
        return {"err": 0, "id_token": play_games_token((form.get("code") or "").strip(),
                                                       (form.get("client_id") or "").strip())}

    @api.endpoint("/api/v1/auth/status")
    def status(conn, hid, form):
        """How this company signs in (Settings › Account). With id_token (Play Games): `match`, whether
        that is the Google account of this company."""
        row = conn.execute("SELECT email, subject FROM auth_identities WHERE hid=? AND provider='google'", (hid,)).fetchone()
        pw = conn.execute("SELECT 1 FROM player_auth WHERE hid=?", (hid,)).fetchone() is not None
        out = {"err": 0, "google": row is not None, "email": (row[0] or "") if row else "", "password": pw,
               "googleAvailable": bool(google_client_ids())}
        token = (form.get("id_token") or "").strip()
        if token:
            out["match"] = row is not None and str(verify_google(token)["sub"]) == row[1]
        return out

    @api.endpoint("/api/v1/auth/google/link")
    def google_link(conn, hid, form):
        """A signed-in password company links its Google account (owner 2026-10-25): id_token plus the
        current password; the password is then removed and the company signs in with Google."""
        claims = verify_google((form.get("id_token") or "").strip())
        sub = str(claims["sub"])
        email = (claims.get("email") or "").lower() if claims.get("email_verified") else None
        name = conn.execute("SELECT company_name FROM players WHERE hID=?", (hid,)).fetchone()
        with econ.tx(conn):
            if conn.execute("SELECT 1 FROM auth_identities WHERE hid=?", (hid,)).fetchone():
                raise econ.GameError("already_linked", "This company already signs in with Google")
            if conn.execute("SELECT 1 FROM auth_identities WHERE provider='google' AND subject=?", (sub,)).fetchone():
                raise econ.GameError("google_taken", "This Google account already has a company")
            if h.check_password_login(conn, name[0] if name else "", form.get("password") or "") != hid:
                raise econ.GameError("wrong_password", "Wrong password.")
            h.remove_password(conn, hid)                  # Google only from now on
            conn.execute("INSERT INTO auth_identities(provider, subject, hid, email, created_at) "
                         "VALUES('google',?,?,?,?)", (sub, hid, email, econ.utcnow_iso()))
        return {"err": 0, "google": True, "email": email or ""}

    @api.endpoint("/api/v1/auth/google/delete", auth=False)
    def google_delete(conn, hid, form):
        """The website's account-deletion page: Google sign-in, then the same deletion as in the app."""
        claims = verify_google((form.get("id_token") or "").strip())
        row = conn.execute("SELECT hid FROM auth_identities WHERE provider='google' AND subject=?",
                           (str(claims["sub"]),)).fetchone()
        if not row:
            raise econ.GameError("no_account", "No OpenRes company uses this Google account")
        return h.delete_account(conn, row[0])
