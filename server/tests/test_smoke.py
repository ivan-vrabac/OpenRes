"""Smoke tests against a throwaway database (see conftest.py).

Run from server/:  python -m pytest -q
"""
import json
import sqlite3
import zlib
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from conftest import TMP
import main

client = TestClient(main.app)


def unz(resp):
    return json.loads(zlib.decompress(resp.content).decode("utf-8"))


@pytest.fixture(scope="module")
def session():
    r = client.post("/api/v1/auth/session", data={"name": "Test Company", "password": "secret123"})
    assert r.status_code == 200, r.text
    return r.json()


def test_uses_isolated_database():
    assert main.DB_PATH.startswith(TMP)
    assert Path(main.DB_PATH).exists()


def test_fresh_schema_created():
    with sqlite3.connect(main.DB_PATH) as conn:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for t in ("players", "co_hexes", "co_state", "co_stock", "market_orders", "proto_log",
              "player_auth", "server_secrets"):
        assert t in tables


def test_player_data(session):
    data = unz(client.post("/api/v3/me", data={"sid": session["sid"]}))
    assert data["err"] == 0 and data["hID"] == session["hID"]


def test_upstream_proxy_disabled_by_default():
    r = client.get("/some/unimplemented/path")
    assert r.status_code == 404


