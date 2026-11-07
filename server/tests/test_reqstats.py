"""Request statistics (owner 2026-11-07): every endpoint call is counted, flushed to req_stats, summed per path."""
import main
import reqstats
from helpers import call, new_player


def test_calls_are_counted_and_summed():
    _, sid, _ = new_player("rqs")
    with main.get_db() as conn:
        reqstats.flush(conn)                       # start from what earlier tests left
        before = {r["path"]: r["calls"] for r in reqstats.summary(conn)}
    for _ in range(3):
        call("/api/v3/state", sid)
    call("/api/v3/state", "not-a-session")            # refused: counted as refused
    with main.get_db() as conn:
        reqstats.flush(conn)
        row = next(r for r in reqstats.summary(conn) if r["path"] == "/api/v3/state")
    assert row["calls"] - before.get("/api/v3/state", 0) == 4
    assert row["refused"] >= 1 and row["avgMs"] >= 0 and row["maxMs"] >= row["avgMs"]


def test_general_cap_per_player_per_minute(monkeypatch):
    """Owner 2026-11-07: at most CAP_PER_MINUTE requests a minute per player (the map has its own allowance)."""
    import systems
    monkeypatch.setattr(systems, "CAP_PER_MINUTE", 5)
    monkeypatch.setattr(systems, "MAP_CAP_PER_MINUTE", 8)
    t = 1_900_000_020.0                                   # one fixed clock minute
    who = "cap-test-player"
    assert not any(systems.over_cap(who, "/api/v3/state", t) for _ in range(5))
    assert systems.over_cap(who, "/api/v3/state", t)      # the 6th in that minute
    assert not any(systems.over_cap(who, "/api/v3/map", t) for _ in range(8))    # the map counts apart
    assert systems.over_cap(who, "/api/v3/map", t)
    assert not systems.over_cap(who, "/api/v3/state", t + 60)                     # a new minute starts again


def test_client_ip_comes_from_cloudflare():
    import systems

    class R:
        def __init__(self, headers, host):
            self.headers, self.client = headers, type("C", (), {"host": host})()
    assert systems.client_ip(R({"cf-connecting-ip": "203.0.113.7"}, "172.18.0.5")) == "203.0.113.7"
    assert systems.client_ip(R({}, "172.18.0.5")) == "172.18.0.5"         # no Cloudflare (dev, tests)
