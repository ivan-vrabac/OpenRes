"""Huge companies and countries (owner 2026-11-03): every leaderboard and the company card still answer,
with the numbers whole, when values reach far beyond anything played so far."""
import gamedata as g
import main
from helpers import call, new_player
from systems import rankings


def _big(hid, credits, invested, stock_qty, country, days=5):
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=?, xp=?, country_code=? WHERE hID=?", (credits, invested, country, hid))
        conn.execute("INSERT INTO co_stock(hid, item, qty) VALUES(?,?,?) ON CONFLICT(hid, item) DO UPDATE SET qty=excluded.qty",
                     (hid, "gold", stock_qty))
        for d in range(days):
            conn.execute("INSERT OR IGNORE INTO player_activity(hid, day) VALUES(?, date('now', ?))", (hid, f"-{d} days"))
        conn.commit()


def test_huge_values_on_every_board():
    rankings._cache.clear()
    hids = []
    # a spread up to 5e18 credits (near SQLite's integer limit) and stock worth ~1e18
    for i, (cr, inv, qty, cc) in enumerate([(5 * 10**18, 10**18, 10**15, "HR"), (10**18, 10**17, 10**12, "HR"),
                                             (10**15, 10**15, 10**9, "DE"), (123_456_789_012, 0, 0, "US"),
                                             (0, 0, 0, "CN"), (-50_000, 0, 0, "JP")]):
        hid, sid, _ = new_player(f"big{i}")
        _big(hid, cr, inv, qty, cc)
        hids.append((hid, sid))
    sid = hids[0][1]
    for path, extra in [("/api/v1/rank/players", {}), ("/api/v1/rank/campus", {}), ("/api/v1/rank/hexes", {}),
                        ("/api/v1/rank/countries", {}), ("/api/v1/rank/tantalum", {}),
                        ("/api/v1/rank/resource", {"kind": "all"}), ("/api/v1/rank/resource", {"kind": "raw"}),
                        ("/api/v1/rank/players", {"country": "1"})]:
        r = call(path, sid, **extra)
        assert r["err"] == 0, (path, r)
    top = call("/api/v1/rank/players", sid)["rows"][0]
    assert top["value"] >= 5 * 10**18 and isinstance(top["value"], int)
    hr = next(r for r in call("/api/v1/rank/countries", sid)["rows"] if r["country"] == "HR")
    assert hr["companies"] == 2 and hr["score"] > 5 * 10**18           # adding up past the 64-bit range is fine
    for _hid, s in hids:
        assert call("/api/v3/state", s)["err"] == 0
    for _hid, s in hids:                                            # each company's own card
        assert call("/api/v1/social/profile", s)["err"] == 0


def test_company_value_never_negative():
    hid, _sid, _ = new_player("neg")
    _big(hid, -10**12, 0, 0, "HR")
    assert rankings.company_values(main.get_db(), only=hid)[hid] == 0
