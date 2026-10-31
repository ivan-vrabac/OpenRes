"""Terms of use / privacy policy endpoints (owner 2026-10-25)."""
from helpers import call, client, new_player
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
