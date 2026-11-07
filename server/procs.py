"""The server on many CPUs (owner 2026-11-06).

The game runs as several processes (serve.py starts one per CPU it may use) over ONE database. SQLite in WAL
mode lets every process read at the same time; writes take turns but each is short. One process with many
threads does not scale: Python runs one thread at a time and threads reading rows hand that lock back and
forth on every row (16 map requests took 10 s in threads, 60 ms in processes).

What a single process used to keep in memory and must be shared or done once lives here:
- init_lock(): start-up (tables, migrations) one process at a time
- as_leader(fn): a background job (data retention, notifications) runs in exactly one process; when that
  one stops, another takes over within LEADER_RETRY_S
- too_often(): the per-player action limits, counted across all processes (a small database of its own)
On Windows (no fcntl: tests, tools) there is one process, so the locks are not needed.
"""
from __future__ import annotations

import contextlib
import os
import random
import sqlite3
import threading
import time

try:
    import fcntl
except ImportError:            # Windows
    fcntl = None

LEADER_RETRY_S = 30


def data_dir() -> str:
    return os.path.dirname(os.path.abspath(os.environ.get("DB_PATH", "/data/game.db")))


@contextlib.contextmanager
def init_lock():
    """Hold while creating tables and migrating: the processes start together, one at a time does this."""
    if fcntl is None:
        yield
        return
    with open(os.path.join(data_dir(), ".init.lock"), "w") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


_leader = None
_leader_mutex = threading.Lock()


def is_leader() -> bool:
    """True in the one process that runs the background jobs (it keeps a lock on a file while it lives)."""
    global _leader
    if fcntl is None:
        return True
    with _leader_mutex:
        if _leader is not None:
            return True
        f = open(os.path.join(data_dir(), ".leader.lock"), "w")
        try:
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            f.close()
            return False
        _leader = f
        return True


def as_leader(fn, name: str) -> None:
    """Run the endless background job `fn` in the leader process only (started from every process)."""
    def run():
        while not is_leader():
            time.sleep(LEADER_RETRY_S)
        fn()
    threading.Thread(target=run, daemon=True, name=name).start()


# ── action limits across processes ───────────────────────────────────────────────────────────────

_rl = threading.local()


def _rl_conn() -> sqlite3.Connection:
    c = getattr(_rl, "conn", None)
    path = os.path.join(data_dir(), "ratelimit.db")
    if c is None or getattr(_rl, "path", None) != path:
        c = sqlite3.connect(path, timeout=5, isolation_level=None, check_same_thread=False)
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=OFF")          # counts of the last minute: nothing to lose
        c.execute("CREATE TABLE IF NOT EXISTS hits (hid TEXT NOT NULL, path TEXT NOT NULL, t REAL NOT NULL)")
        c.execute("CREATE INDEX IF NOT EXISTS idx_hits ON hits(hid, path, t)")
        c.execute("CREATE TABLE IF NOT EXISTS caps (key TEXT NOT NULL, minute INTEGER NOT NULL, n INTEGER NOT NULL, "
                  "PRIMARY KEY (key, minute)) WITHOUT ROWID")
        _rl.conn, _rl.path = c, path
    return c


def over_cap(key: str, limit: int, now: float | None = None) -> bool:
    """The general cap (owner 2026-11-07): True when `key` (a player, or an address) has made more than `limit`
    requests in this clock minute, counted across all the server's processes. One small write per request."""
    now = time.time() if now is None else now
    minute = int(now // 60)
    c = _rl_conn()
    try:
        n = c.execute("INSERT INTO caps(key, minute, n) VALUES (?, ?, 1) ON CONFLICT(key, minute) DO UPDATE SET n=n+1 "
                      "RETURNING n", (key, minute)).fetchone()[0]
        if random.random() < 0.001:                   # now and then: forget the minutes that are over
            c.execute("DELETE FROM caps WHERE minute < ?", (minute - 1,))
        return n > limit
    except sqlite3.Error:                             # never block a player because counting failed
        return False


def too_often(hid: str, path: str, n: int, window: float, now: float | None = None) -> bool:
    """True when `hid` already used `path` n times in the last `window` seconds (then not counted)."""
    now = time.time() if now is None else now
    c = _rl_conn()
    try:
        c.execute("BEGIN IMMEDIATE")
        used = c.execute("SELECT COUNT(*) FROM hits WHERE hid=? AND path=? AND t>?", (hid, path, now - window)).fetchone()[0]
        if used >= n:
            c.execute("ROLLBACK")
            return True
        c.execute("INSERT INTO hits(hid, path, t) VALUES(?,?,?)", (hid, path, now))
        if random.random() < 0.002:                   # now and then: forget what no window needs any more
            c.execute("DELETE FROM hits WHERE t<?", (now - 7200,))
        c.execute("COMMIT")
        return False
    except sqlite3.OperationalError:                  # busy for 5 s: let the action through, never block a player
        with contextlib.suppress(sqlite3.Error):
            c.execute("ROLLBACK")
        return False
