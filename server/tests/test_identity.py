"""Google sign-in only (owner 2026-10-25): new company by name, linking an old password company once,
no password sign-in afterwards, no unsigned sessions for Google accounts, deletion from the website."""
import base64
import json

import pytest

import auth
import main
from helpers import _PW, call, client, new_player

WRONG = _PW[::-1]          # any other value (the repo scanner rejects literal passwords)
from systems import identity


@pytest.fixture
def google(monkeypatch):
    monkeypatch.setenv("GOOGLE_CLIENT_IDS", "web-client-id")
    monkeypatch.setattr(identity, "verify_google",
                        lambda t: {"sub": t.split(":")[0], "email": t.split(":")[1], "email_verified": True,
                                   "iss": "accounts.google.com"})


def g(token, **form):
    return call("/api/v1/auth/google", "", id_token=token, **form)


def test_new_google_player_names_a_company(google):
    assert g("sub-new:a@x.org")["code"] == "need_name"
    r = g("sub-new:a@x.org", name="Google Co")
    assert r["err"] == 0 and r["created"] and r["name"] == "Google Co" and auth.hid_from_sid(r["sid"]) == r["hID"]
    again = g("sub-new:a@x.org")                                   # next time straight in
    assert again["hID"] == r["hID"] and not again["created"]
    assert g("sub-other:b@x.org", name="Google Co")["code"] == "name_taken"


def test_password_registration_closed_and_old_company_links_once(google, monkeypatch):
    monkeypatch.setattr(identity, "google_client_ids", lambda: [])          # Google off: make a password company
    hid, sid, name = new_player("lnk")
    monkeypatch.undo()
    monkeypatch.setenv("GOOGLE_CLIENT_IDS", "web-client-id")
    monkeypatch.setattr(identity, "verify_google",
                        lambda t: {"sub": t.split(":")[0], "email": t.split(":")[1], "email_verified": True,
                                   "iss": "accounts.google.com"})
    r = client.post("/api/v1/auth/session", data={"name": "Brand New Co", "password": _PW, "mode": "register"})
    assert r.json()["error"] == "use_google"
    assert g("sub-lnk:c@x.org", link_name=name, link_password=WRONG)["code"] == "wrong_password"
    r = g("sub-lnk:c@x.org", link_name=name, link_password=_PW)
    assert r["err"] == 0 and r["hID"] == hid and not r["created"]
    r = client.post("/api/v1/auth/session", data={"name": name, "password": _PW, "mode": "login"})
    assert r.json()["error"] == "use_google"                                # password is gone
    with main.get_db() as conn:
        assert auth.get_hash(conn, hid) is None
    assert g("sub-x:d@x.org", link_name=name, link_password=_PW)["code"] == "wrong_password"


def test_google_account_never_opened_by_unsigned_session(google, monkeypatch):
    r = g("sub-uns:e@x.org", name="Unsigned Co")
    forged = base64.b64encode(json.dumps({"hID": r["hID"]}).encode()).decode()
    monkeypatch.setattr(auth, "AUTH_MODE", "mixed")
    assert auth.hid_from_sid(forged) == ""


def test_delete_from_website_with_google(google):
    r = g("sub-del:f@x.org", name="Delete Me Co")
    d = g("sub-del:f@x.org")
    out = call("/api/v1/auth/google/delete", "", id_token="sub-del:f@x.org")
    assert out["err"] == 0 and out["deleted"] is True
    with main.get_db() as conn:
        assert conn.execute("SELECT 1 FROM players WHERE hID=?", (r["hID"],)).fetchone() is None
        assert conn.execute("SELECT 1 FROM auth_identities WHERE hid=?", (r["hID"],)).fetchone() is None
    assert call("/api/v1/auth/google/delete", "", id_token="sub-none:g@x.org")["code"] == "no_account"


def test_google_off_by_default():
    assert call("/api/v1/auth/config", "")["google"] is False


def test_settings_link_google_with_current_password(google, monkeypatch):
    monkeypatch.setattr(identity, "google_client_ids", lambda: [])          # a password company
    hid, sid, name = new_player("set")
    monkeypatch.setattr(identity, "google_client_ids", lambda: ["web-client-id"])
    st = call("/api/v1/auth/status", sid)
    assert st["password"] and not st["google"] and st["googleAvailable"]
    assert call("/api/v1/auth/google/link", sid, id_token="sub-set:s@x.org", password=WRONG)["code"] == "wrong_password"
    g("sub-busy:b@x.org", name="Busy Co")
    assert call("/api/v1/auth/google/link", sid, id_token="sub-busy:b@x.org", password=_PW)["code"] == "google_taken"
    r = call("/api/v1/auth/google/link", sid, id_token="sub-set:s@x.org", password=_PW)
    assert r["err"] == 0 and r["email"] == "s@x.org"
    st = call("/api/v1/auth/status", sid)                                   # same session keeps working
    assert st["google"] and not st["password"] and st["email"] == "s@x.org"
    assert g("sub-set:s@x.org")["hID"] == hid                               # signs in with Google now
    assert call("/api/v1/auth/google/link", sid, id_token="sub-z:z@x.org", password=_PW)["code"] == "already_linked"


def test_fresh_token_from_a_clock_slightly_ahead_is_accepted(monkeypatch):
    """Our clock was ~3 s behind Google's: a fresh token must not be refused as "used too early"."""
    import datetime
    import time
    crypto = pytest.importorskip("cryptography")  # noqa: F841
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from cryptography.x509.oid import NameOID
    from google.auth import crypt, jwt

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "test")])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key())
            .serial_number(1).not_valid_before(now - datetime.timedelta(days=1))
            .not_valid_after(now + datetime.timedelta(days=1)).sign(key, hashes.SHA256()))
    pem_key = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption()).decode()
    signer = crypt.RSASigner.from_string(pem_key, key_id="k1")
    t = int(time.time()) + 5                                    # issued "5 s from now" by Google's clock
    token = jwt.encode(signer, {"iss": "accounts.google.com", "aud": "web-client-id", "sub": "skew",
                                "iat": t, "exp": t + 3600}).decode()
    monkeypatch.setenv("GOOGLE_CLIENT_IDS", "web-client-id")
    monkeypatch.setattr(identity, "_google_certs", lambda: {"k1": cert.public_bytes(serialization.Encoding.PEM).decode()})
    assert identity.verify_google(token)["sub"] == "skew"


def test_status_tells_if_a_token_is_this_company(google):
    sid = g("sub-mine:m@x.org", name="Mine Co")["sid"]
    assert call("/api/v1/auth/status", sid, id_token="sub-mine:m@x.org")["match"] is True
    assert call("/api/v1/auth/status", sid, id_token="sub-other2:o@x.org")["match"] is False
    assert "match" not in call("/api/v1/auth/status", sid)


def test_play_games_code_becomes_an_id_token(google, monkeypatch):
    seen = {}

    class Answer:
        status_code = 200

        def json(self):
            return {"id_token": "sub-pg:p@x.org"}

    def post(url, data, timeout):
        seen.update(data)
        return Answer()

    import httpx
    monkeypatch.setattr(httpx, "post", post)
    pg = lambda **f: call("/api/v1/auth/play_games", "", **f)
    assert pg(code="c", client_id="web-client-id")["code"] == "disabled"             # no secret on this server
    monkeypatch.setenv("GOOGLE_CLIENT_SECRET", "s")
    assert pg(code="c", client_id="someone-else")["code"] == "disabled"
    r = pg(code="c", client_id="web-client-id")
    assert seen["code"] == "c" and seen["client_secret"] == "s"
    made = g(r["id_token"], name="Games Co")                                         # the normal Google sign-in
    assert made["created"] and g(r["id_token"])["hID"] == made["hID"]
    monkeypatch.setattr(Answer, "json", lambda self: {})                             # openid scope refused
    assert pg(code="c", client_id="web-client-id")["code"] == "bad_token"
