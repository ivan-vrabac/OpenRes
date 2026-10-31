"""tools/fresh_world.py: dry run changes nothing; --yes backs up, empties the game, drops the old tables."""
import importlib.util
import os
import sqlite3

_spec = importlib.util.spec_from_file_location(
    "fresh_world", os.path.join(os.path.dirname(__file__), "..", "..", "tools", "fresh_world.py"))
fresh_world = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fresh_world)


def _db(path):
    c = sqlite3.connect(path)
    c.executescript("""
        CREATE TABLE players(hID TEXT, company_name TEXT, credits INTEGER, xp INTEGER, level INTEGER);
        CREATE TABLE scheduler(name TEXT, last_run TEXT);
        CREATE TABLE co_hexes(id INTEGER, lat REAL, edu INTEGER);
        CREATE TABLE mines(mine_id TEXT);
        CREATE TABLE warehouse(hid TEXT);
        INSERT INTO players VALUES('a', 'Acme', 500, 10, 3);
        INSERT INTO co_hexes VALUES(1, 45.0, 0);
        INSERT INTO mines VALUES('m');
    """)
    c.commit()
    c.close()


def _tables(path):
    with sqlite3.connect(path) as c:
        return {r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'")}


def test_dry_run_changes_nothing(tmp_path):
    p = str(tmp_path / "g.db")
    _db(p)
    assert fresh_world.main(["x", p]) == 0
    assert {"mines", "warehouse"} <= _tables(p)
    assert sqlite3.connect(p).execute("SELECT COUNT(*) FROM co_hexes").fetchone()[0] == 1


def test_fresh_world_backs_up_empties_and_drops(tmp_path):
    p = str(tmp_path / "g.db")
    _db(p)
    assert fresh_world.main(["x", p, "--yes"]) == 0
    assert "mines" not in _tables(p) and "warehouse" not in _tables(p)
    c = sqlite3.connect(p)
    assert c.execute("SELECT credits, xp, level, company_name FROM players").fetchone() == (0, 0, 1, "Acme")
    assert c.execute("SELECT COUNT(*) FROM co_hexes").fetchone()[0] == 0
    assert "edu" not in [r[1] for r in c.execute("PRAGMA table_info(co_hexes)")]
    backups = [f for f in os.listdir(tmp_path) if f.startswith("backup_pre_fresh_world_")]
    assert len(backups) == 1 and "mines" in _tables(str(tmp_path / backups[0]))
