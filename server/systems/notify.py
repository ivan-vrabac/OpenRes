"""Push notifications per kind with on/off and a daily maximum (owner 2026-10-23).

Kinds (0.2.3): a buy order filled, an education finished, leases ending soon, the Campus moved,
Central Storage above the player's chosen share, Central Storage full. Each player can switch a kind
off and choose how many per day (or unlimited, stored as 0). Things that happen on the clock (education, leases, a Campus move, storage) are found
by a sweep every SWEEP_S seconds (game_sweep); notif_once keeps each one from being sent twice. Sending happens on a background
thread with its own connection, so a slow push service never holds a game transaction.

Delivery (owner 2026-10-25: "actually notifies the user asap"): every push also lands in a
per-player inbox (`notif_inbox`) that the phone's background worker long-polls through
/api/v1/notify/poll; the request is held open until something arrives (no Firebase needed).
"""
from __future__ import annotations

import asyncio
import datetime
import os
import threading
import time

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.concurrency import run_in_threadpool

import econ
from . import int_arg

KINDS = {
    # kind: (label, default max per day, 0 = unlimited[, on by default])
    # 0.2.3: chat, auctions, factories, accidents, mines and the warehouse are gone
    "order_filled": ("Buy order filled", 20),
    "education_done": ("Education finished", 0),
    "lease_ending": ("Leases ending within 3 days", 3),
    "campus_arrived": ("Campus moved", 0),
    "storage_high": ("Central Storage filling up", 3),
    "storage_full": ("Central Storage full", 3),
}
SWEEP_S = 300
LEASE_WARN_DAYS = 3
ONCE_KEEP_DAYS = 30
CHOICES = (1, 3, 5, 10, 20, 50, 0)
INBOX_KEEP = 200          # newest notifications kept per player for the phone to fetch
POLL_MAX_WAIT = 50        # seconds a poll may be held open
STORAGE_HIGH_DEFAULT = 75 # % of Central Storage used that sends storage_high
STORAGE_HIGH_CHOICES = tuple(range(50, 100, 5))


def default_on(kind) -> bool:
    return KINDS[kind][2] if len(KINDS[kind]) > 2 else True


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS notif_kinds (
            hid      TEXT NOT NULL,
            kind     TEXT NOT NULL,
            enabled  INTEGER NOT NULL DEFAULT 1,
            max_day  INTEGER NOT NULL DEFAULT 0,
            threshold INTEGER,
            PRIMARY KEY (hid, kind)
        );
        CREATE TABLE IF NOT EXISTS notif_sent (
            hid   TEXT NOT NULL,
            kind  TEXT NOT NULL,
            day   TEXT NOT NULL,
            n     INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (hid, kind, day)
        );
        CREATE TABLE IF NOT EXISTS notif_inbox (
            id    INTEGER PRIMARY KEY AUTOINCREMENT,
            hid   TEXT NOT NULL,
            kind  TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL,
            body  TEXT NOT NULL,
            tag   TEXT NOT NULL DEFAULT '',
            ts    TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_notif_inbox ON notif_inbox(hid, id);
        CREATE TABLE IF NOT EXISTS notif_once (          -- what the sweep already sent
            key TEXT PRIMARY KEY,
            ts  TEXT NOT NULL
        );
    """)
    if "threshold" not in {r[1] for r in conn.execute("PRAGMA table_info(notif_kinds)")}:
        conn.execute("ALTER TABLE notif_kinds ADD COLUMN threshold INTEGER")
    conn.commit()


def due(conn, now) -> list:
    """What the clock brought since the last sweep: (key, hid, kind, title, body). Only things of the
    last day count, so a server that was down doesn't send a backlog."""
    import gamedata as g
    from . import company as co
    nowi, day_ago = now.isoformat(), (now - datetime.timedelta(days=1)).isoformat()
    today = now.strftime("%Y-%m-%d")
    out = []
    for r in conn.execute("SELECT id, hid, to_step FROM co_education WHERE finish_at<=? AND finish_at>?", (nowi, day_ago)):
        name = g.EDUCATION.get(r["to_step"], ("education",))[0]
        out.append((f"edu:{r['id']}", r["hid"], "education_done", "Education finished",
                    f"A supervisor finished the {name}. Put them on a good hex."))
    soon = (now + datetime.timedelta(days=LEASE_WARN_DAYS)).isoformat()
    for hid, n in conn.execute("SELECT hid, COUNT(*) FROM co_hexes WHERE op!='campus' AND lease_until>? AND lease_until<=? "
                               "GROUP BY hid", (nowi, soon)):
        out.append((f"lease:{hid}:{today}", hid, "lease_ending", "Leases ending soon",
                    f"{n} hex lease{'s end' if n > 1 else ' ends'} within {LEASE_WARN_DAYS} days. Renew in Hexes "
                    "or the hexes are lost."))
    for r in conn.execute("SELECT hid, started_at FROM co_moves"):
        arrived = co.parse(r["started_at"]) + datetime.timedelta(hours=g.MOVE_HOURS)
        if now - datetime.timedelta(days=1) < arrived <= now:
            out.append((f"move:{r['hid']}:{r['started_at']}", r["hid"], "campus_arrived", "Your Campus moved",
                        "Your Campus is at its new place and your plants are working again."))
    levels = dict(conn.execute("SELECT hid, storage_level FROM co_state"))
    high = dict(conn.execute("SELECT hid, threshold FROM notif_kinds WHERE kind='storage_high' AND threshold IS NOT NULL"))
    for hid, used in conn.execute("SELECT hid, SUM(CASE item WHEN 'electricity' THEN qty / 1000.0 WHEN 'ta180m' THEN 0 "
                                  "ELSE qty END) FROM co_stock GROUP BY hid"):
        if hid not in levels:
            continue
        cap = g.storage_capacity(levels[hid])
        if used >= cap - 0.5:
            out.append((f"full:{hid}:{today}", hid, "storage_full", "Central Storage is full",
                        "Hexes and plants can't add to it. Sell something or upgrade the storage."))
        elif used >= cap * high.get(hid, STORAGE_HIGH_DEFAULT) / 100:
            out.append((f"high:{hid}:{today}", hid, "storage_high", "Central Storage is filling up",
                        f"It is {int(used * 100 / cap)} % full. Sell something or upgrade the storage."))
    return out


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)

    def prefs(conn, hid) -> dict:
        got = {r[0]: (bool(r[1]), int(r[2])) for r in conn.execute(
            "SELECT kind, enabled, max_day FROM notif_kinds WHERE hid=?", (hid,))}
        return {k: got.get(k, (default_on(k), v[1])) for k, v in KINDS.items()}

    latest = {}          # hid -> newest inbox id; held polls wake up when it grows
    fcm_push = h.push

    def _fcm(hid, title, body) -> None:
        try:
            with h.get_db() as c:
                fcm_push(c, hid, title, body)
        except Exception:
            pass

    def _store(conn, hid, kind, title, body, tag) -> None:
        """Into the inbox the phone polls (inside the caller's transaction)."""
        cur = conn.execute("INSERT INTO notif_inbox(hid, kind, title, body, tag, ts) VALUES(?,?,?,?,?,?)",
                           (hid, kind or "", title, body, tag or "", econ.utcnow_iso()))
        conn.execute("DELETE FROM notif_inbox WHERE hid=? AND id <= ?", (hid, cur.lastrowid - INBOX_KEEP))
        return cur.lastrowid

    def _stored(new_id, hid, title, body) -> None:
        latest[hid] = max(latest.get(hid, 0), new_id)
        threading.Thread(target=_fcm, args=(hid, title, body), daemon=True).start()   # slow network

    def _push_thread(hid, kind, title, body, tag) -> None:
        try:
            with h.get_db() as c:
                with econ.tx(c):
                    new_id = _store(c, hid, kind, title, body, tag)
            _stored(new_id, hid, title, body)
        except Exception:
            pass

    def push(conn, hid, title, body, kind="", tag="") -> None:
        """Deliver straight away, without settings (older callers). Stored on its own thread, so a
        caller still inside a write transaction never waits on itself."""
        threading.Thread(target=_push_thread, args=(hid, kind, title, body, tag), daemon=True).start()

    h.push = push

    def _deliver(conn, hid, kind, title, body, tag) -> None:
        """Settings, daily maximum and the inbox, in one short transaction on `conn`."""
        g = conn.execute("SELECT enabled FROM notif_prefs WHERE hid=?", (hid,)).fetchone()
        if g is not None and not g[0]:
            return                                  # all notifications off
        on, cap = prefs(conn, hid)[kind]
        if not on:
            return
        day = econ.utcnow().strftime("%Y-%m-%d")
        with econ.tx(conn):
            n = conn.execute("SELECT n FROM notif_sent WHERE hid=? AND kind=? AND day=?",
                             (hid, kind, day)).fetchone()
            if cap and n and n[0] >= cap:
                return
            conn.execute("INSERT INTO notif_sent(hid, kind, day, n) VALUES(?,?,?,1) ON CONFLICT(hid, kind, day) "
                         "DO UPDATE SET n=n+1", (hid, kind, day))
            new_id = _store(conn, hid, kind, title, body, tag)
        _stored(new_id, hid, title, body)

    def _send(hid, kind, title, body, tag="") -> None:
        try:
            with h.get_db() as conn:
                _deliver(conn, hid, kind, title, body, tag)
        except Exception:
            pass

    def notify(hid, kind, title, body, tag="", conn=None) -> None:
        """A push of `kind` for `hid` (respects the player's settings and daily maximum). `tag`
        groups them on the phone (one notification per conversation). With `conn` (a request whose
        own transaction is finished) it is written right there, with no second writer racing the
        next request; without it, on a background thread."""
        if kind not in KINDS or not hid:
            return
        if conn is not None:
            try:
                _deliver(conn, hid, kind, title, body, tag)
            except econ.GameError:
                raise
            except Exception:
                pass
            return
        threading.Thread(target=_send, args=(hid, kind, title, body, tag), daemon=True).start()

    h.notify = notify

    def game_sweep(conn, now=None) -> int:
        """Send what the clock brought (each once). Returns how many were new."""
        now = now or econ.utcnow()
        sent = 0
        for key, hid, kind, title, body in due(conn, now):
            with econ.tx(conn):
                if conn.execute("INSERT OR IGNORE INTO notif_once(key, ts) VALUES(?,?)", (key, now.isoformat())).rowcount != 1:
                    continue
            notify(hid, kind, title, body, tag=kind, conn=conn)
            sent += 1
        with econ.tx(conn):
            conn.execute("DELETE FROM notif_once WHERE ts < ?",
                         ((now - datetime.timedelta(days=ONCE_KEEP_DAYS)).isoformat(),))
        return sent

    h.game_sweep = game_sweep

    def sweeper() -> None:
        while True:
            time.sleep(SWEEP_S)
            try:
                with h.get_db() as conn:
                    game_sweep(conn)
            except Exception:
                pass

    if os.environ.get("WORLD_EVENTS_THREAD", "1") == "1":
        threading.Thread(target=sweeper, daemon=True, name="notify-sweep").start()
    h.notify_enabled_for = lambda conn, kind: [r[0] for r in conn.execute(
        "SELECT hid FROM notif_kinds WHERE kind=? AND enabled=1", (kind,))]

    @api.app.post("/api/v1/notify/poll")
    async def poll(request: Request):
        """The phone's notification worker: notifications after `after` (-1 = just tell me where
        the inbox is now). With `wait` the request is held up to 50 s until one arrives. JSON."""
        _, form = await h.read_form(request)
        hid = h.hid_from_sid(form.get("sid", ""))
        if not hid:
            return JSONResponse({"err": 1, "code": "auth"})
        try:
            after = int(form.get("after", -1))
            wait = max(0, min(POLL_MAX_WAIT, int(form.get("wait", 0))))
        except (TypeError, ValueError):
            return JSONResponse({"err": 1, "code": "bad_input"})

        def fetch():
            with h.get_db() as c:
                if after < 0:
                    return [], c.execute("SELECT COALESCE(MAX(id),0) FROM notif_inbox WHERE hid=?", (hid,)).fetchone()[0]
                rows = c.execute("SELECT id, kind, title, body, tag, ts FROM notif_inbox WHERE hid=? AND id>? "
                                 "ORDER BY id LIMIT 20", (hid, after)).fetchall()
                return rows, (rows[-1][0] if rows else after)

        rows, nxt = await run_in_threadpool(fetch)
        deadline = time.monotonic() + wait
        while not rows and after >= 0 and time.monotonic() < deadline:
            await asyncio.sleep(1)
            if latest.get(hid, 0) > after:
                rows, nxt = await run_in_threadpool(fetch)
        return JSONResponse({"err": 0, "next": nxt, "items": [
            {"id": r[0], "kind": r[1], "title": r[2], "body": r[3], "tag": r[4], "ts": r[5]} for r in rows]})

    @api.endpoint("/api/v1/notify/prefs")
    def get_prefs(conn, hid, form):
        p = prefs(conn, hid)
        row = conn.execute("SELECT threshold FROM notif_kinds WHERE hid=? AND kind='storage_high'", (hid,)).fetchone()
        return {"err": 0, "choices": list(CHOICES), "thresholds": list(STORAGE_HIGH_CHOICES),
                "storageHigh": row[0] if row and row[0] else STORAGE_HIGH_DEFAULT,
                "kinds": [{"kind": k, "label": KINDS[k][0], "enabled": p[k][0], "maxPerDay": p[k][1],
                           "default": KINDS[k][1]} for k in KINDS]}

    @api.endpoint("/api/v1/notify/set")
    def set_pref(conn, hid, form):
        kind = (form.get("kind") or "").strip()
        if kind not in KINDS:
            raise econ.GameError("bad_input", "Unknown notification")
        enabled = 1 if form.get("enabled", "1") in ("1", "true") else 0
        mx = int_arg(form, "maxPerDay", KINDS[kind][1], 0, 1000)
        if mx not in CHOICES:
            raise econ.GameError("bad_input", "Choose one of the offered limits")
        with econ.tx(conn):
            conn.execute("INSERT INTO notif_kinds(hid, kind, enabled, max_day) VALUES(?,?,?,?) ON CONFLICT(hid, kind) "
                         "DO UPDATE SET enabled=excluded.enabled, max_day=excluded.max_day", (hid, kind, enabled, mx))
        return get_prefs(conn, hid, form)

    @api.endpoint("/api/v1/notify/storage_high")
    def set_storage_high(conn, hid, form):
        """How full Central Storage has to be for storage_high (% of the total)."""
        pct = int_arg(form, "percent", STORAGE_HIGH_DEFAULT, 0, 100)
        if pct not in STORAGE_HIGH_CHOICES:
            raise econ.GameError("bad_input", "Choose one of the offered levels")
        on, mx = prefs(conn, hid)["storage_high"]
        with econ.tx(conn):
            conn.execute("INSERT INTO notif_kinds(hid, kind, enabled, max_day, threshold) VALUES(?,?,?,?,?) "
                         "ON CONFLICT(hid, kind) DO UPDATE SET threshold=excluded.threshold",
                         (hid, "storage_high", int(on), mx, pct))
        return get_prefs(conn, hid, form)
