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
