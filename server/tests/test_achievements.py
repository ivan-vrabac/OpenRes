"""Achievements: tiers computed from real data, recorded once."""
import main
from helpers import call, new_player


def test_tiers_unlock_once_and_progress():
    hid, sid, _ = new_player("ach", level=25)
    call("/api/v3/state", sid)                                   # the company exists
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=2000000000 WHERE hID=?", (hid,))
        conn.execute("INSERT INTO co_plants(hid, key, level) VALUES(?,?,?)", (hid, "sawmill", 12))
        conn.commit()
    r = call("/api/v1/achievements", sid)
    by = {a["key"]: a for a in r["achievements"]}
    assert by["balance"]["stars"] == 1 and by["balance"]["next"] == 10_000_000_000
    assert by["value"]["stars"] == 1 and by["plants"]["stars"] == 1 and by["plants"]["value"] == 12
    assert by["hexes"]["stars"] == 0 and by["hexes"]["value"] == 0
    assert {(n["key"], n["tier"]) for n in r["new"]} >= {("balance", 1), ("value", 1), ("plants", 1)}
    again = call("/api/v1/achievements", sid)
    assert again["new"] == [] and again["stars"] == r["stars"]
    assert len(r["achievements"]) == 13 and r["maxStars"] == 39
