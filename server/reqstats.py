"""Request statistics (owner 2026-11-07, scaling step 0): how often each endpoint is called and how long it takes,
so caching and other speed work later goes where the real traffic is.

Each process counts in memory (no database work per request) and adds its counts to the shared table
req_stats once a minute. Days older than KEEP_DAYS are dropped. See them with
`python reqstats.py` inside the server container, or the moderator page (mod/reports with stats=1)."""
from __future__ import annotations

import datetime
import sys
import threading
import time

KEEP_DAYS = 30
FLUSH_SECONDS = 60

_lock = threading.Lock()
_now: dict[str, list[float]] = {}          # path: [calls, ms total, ms max, refused]
_started = False


def record(path: str, ms: float, refused: bool) -> None:
    with _lock:
        s = _now.get(path)
        if s is None:
            _now[path] = [1, ms, ms, 1 if refused else 0]
        else:
            s[0] += 1
            s[1] += ms
            if ms > s[2]:
                s[2] = ms
            if refused:
                s[3] += 1


def init(conn) -> None:
    conn.execute("""CREATE TABLE IF NOT EXISTS req_stats (
        day TEXT NOT NULL, path TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0, ms_total REAL NOT NULL DEFAULT 0,
        ms_max REAL NOT NULL DEFAULT 0, refused INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (day, path))""")
    conn.commit()


def flush(conn) -> None:
    """Adds this process's counts since the last flush to today's row of each path."""
    with _lock:
        batch = dict(_now)
        _now.clear()
    if not batch:
        return
    day = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d")
    conn.executemany(
        "INSERT INTO req_stats(day, path, calls, ms_total, ms_max, refused) VALUES (?,?,?,?,?,?) "
        "ON CONFLICT(day, path) DO UPDATE SET calls=calls+excluded.calls, ms_total=ms_total+excluded.ms_total, "
        "ms_max=MAX(ms_max, excluded.ms_max), refused=refused+excluded.refused",
        [(day, p, int(s[0]), s[1], s[2], int(s[3])) for p, s in batch.items()])
    old = (datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=KEEP_DAYS)).strftime("%Y-%m-%d")
    conn.execute("DELETE FROM req_stats WHERE day < ?", (old,))
    conn.commit()


def start(get_db) -> None:
    """One flusher thread per process."""
    global _started
    if _started:
        return
    _started = True

    def loop():
        while True:
            time.sleep(FLUSH_SECONDS)
            try:
                with get_db() as conn:
                    flush(conn)
            except Exception:
                pass                           # statistics never break the game

    threading.Thread(target=loop, name="reqstats", daemon=True).start()


def summary(conn, days: int = 1) -> list[dict]:
    """Per endpoint over the last `days` days, busiest first."""
    since = (datetime.datetime.now(datetime.UTC) - datetime.timedelta(days=days - 1)).strftime("%Y-%m-%d")
    rows = conn.execute(
        "SELECT path, SUM(calls), SUM(ms_total), MAX(ms_max), SUM(refused) FROM req_stats WHERE day >= ? "
        "GROUP BY path ORDER BY SUM(calls) DESC", (since,)).fetchall()
    return [{"path": r[0], "calls": r[1], "avgMs": round(r[2] / r[1], 1) if r[1] else 0, "maxMs": round(r[3], 1),
             "totalS": round(r[2] / 1000, 1), "refused": r[4]} for r in rows]


if __name__ == "__main__":                    # python reqstats.py [days]
    import sqlite3
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    c = sqlite3.connect("file:/data/game.db?mode=ro", uri=True)
    rows = summary(c, days)
    total = sum(r["calls"] for r in rows) or 1
    print(f"last {days} day(s): {total} calls")
    print(f"{'endpoint':45} {'calls':>9} {'share':>6} {'avg ms':>8} {'max ms':>9} {'busy s':>8} {'refused':>8}")
    for r in rows:
        print(f"{r['path']:45} {r['calls']:>9} {r['calls'] / total * 100:>5.1f}% {r['avgMs']:>8} {r['maxMs']:>9} "
              f"{r['totalS']:>8} {r['refused']:>8}")
