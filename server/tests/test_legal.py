"""Terms of use / privacy policy endpoints (owner 2026-10-25)."""
from helpers import call, client, new_player
import main
import json, zlib


def test_legal_texts_without_sign_in_and_acceptance():
    r = json.loads(zlib.decompress(client.post("/api/v1/legal", data={}).content))
    assert r["version"] and "Croatia" in r["terms"] and "GDPR" in r["privacy"]
    assert "{version}" not in r["terms"] and "{contact}" not in r["privacy"]
    _, sid, _ = new_player("lg")
    assert call("/api/v1/legal/accept", sid, version="old")["code"] == "bad_input"
    assert call("/api/v1/legal/accept", sid, version=r["version"])["err"] == 0


def test_contact_form_without_sign_in():
    import main
    r = json.loads(zlib.decompress(client.post("/api/v1/contact", data={"topic": "privacy",
                                                                        "message": "Please send me my data."}).content))
    assert r["err"] == 0
    r = json.loads(zlib.decompress(client.post("/api/v1/contact", data={"message": "hi"}).content))
    assert r["code"] == "bad_input"
    with main.get_db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM contact_messages WHERE topic='privacy'").fetchone()[0] >= 1


def _contact(**form):
    return json.loads(zlib.decompress(client.post("/api/v1/contact", data=form).content))


def test_contact_form_keeps_robots_out(monkeypatch):
    from systems import legal
    text = "A real question from a person"
    with main.get_db() as conn:
        count = lambda: conn.execute("SELECT COUNT(*) FROM contact_messages").fetchone()[0]
        before = count()
        assert _contact(message=text, website="spam.example")["err"] == 0        # the hidden field: not stored
        assert count() == before
        monkeypatch.setenv("TURNSTILE_SECRET", "s")
        assert _contact(message=text)["code"] == "bad_token"                     # no Turnstile answer
        monkeypatch.setattr(legal, "turnstile_ok", lambda t: t == "good")
        assert _contact(message=text, turnstile="bad")["code"] == "bad_token"
        assert _contact(message=text, turnstile="good")["err"] == 0
        assert count() == before + 1
