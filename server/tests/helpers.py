"""Shared helpers for system tests: register players through the real auth endpoint and call
the zlib-JSON system endpoints."""
import json
import zlib

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)
_n = [0]
_PW = "password1"  # test accounts only


def new_player(prefix="p", credits=None, level=None, wh_level=None, password=_PW):
    """Register a fresh player; returns (hid, sid, name)."""
    import names
    while True:                       # skip numbers the name filter reads as words (b0080 → "boob")
        _n[0] += 1
        name = f"{prefix}{_n[0]:04d}"[:20]
        if names.name_problem(name) is None:
            break
    r = client.post("/api/v1/auth/session", data={"name": name, "password": password, "mode": "register"})
    assert r.status_code == 200, r.text
    hid, sid = r.json()["hID"], r.json()["sid"]
    sets = {"credits": credits, "level": level, "wh_level": wh_level}
    with main.get_db() as conn:
        for col, v in sets.items():
            if v is not None:
                conn.execute(f"UPDATE players SET {col}=? WHERE hID=?", (v, hid))
        conn.commit()
    return hid, sid, name


def call(path, sid, **form):
    r = client.post(path, data={"sid": sid, **{k: str(v) for k, v in form.items()}})
    assert r.status_code == 200, r.text
    return json.loads(zlib.decompress(r.content))


def give(hid, item, qty):
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) "
                     "ON CONFLICT(hid, item) DO UPDATE SET qty=qty+excluded.qty", (hid, item, qty))
        conn.commit()


def credits(hid):
    with main.get_db() as conn:
        return conn.execute("SELECT credits FROM players WHERE hID=?", (hid,)).fetchone()[0]
