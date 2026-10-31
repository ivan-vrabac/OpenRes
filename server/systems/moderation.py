"""Moderation (owner 2026-10-25; Google Play requires reporting and acting on reports). Chat and
private messages were removed in 0.2.3, so what is left is about players (company names).

- Report: a player reports another player (company), with a reason and an optional note.
- Bans: a full ban (no sign-in at all), for some hours or forever.
- Moderators: /api/v1/mod/* with the moderator password (MOD_PASSWORD, environment) -- the page
  https://resources.vrabac.eu/mod.html and `python admin.py` use them.
"""
from __future__ import annotations

import datetime
import hmac
import os
import re
import time

import econ

REASONS = ("insult", "hate", "sexual", "spam", "cheating", "other")

def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS reports (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            ts           TEXT NOT NULL,
            reporter_hid TEXT NOT NULL,
            target_hid   TEXT NOT NULL,
            kind         TEXT NOT NULL,          -- player (chat | dm before 0.2.3)
            message_id   INTEGER,
            message_text TEXT,
            reason       TEXT NOT NULL,
            note         TEXT,
            status       TEXT NOT NULL DEFAULT 'open',   -- open | dismissed | actioned
            action       TEXT,
            handled_at   TEXT
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_reports_once ON reports(reporter_hid, kind, COALESCE(message_id, 0), target_hid);
        CREATE TABLE IF NOT EXISTS player_bans (
            hid    TEXT NOT NULL,
            kind   TEXT NOT NULL,                -- full (chat before 0.2.3)
            until  TEXT,                         -- NULL: forever
            reason TEXT,
            ts     TEXT NOT NULL,
            PRIMARY KEY (hid, kind)
        );
        CREATE TABLE IF NOT EXISTS player_devices (
            hid        TEXT NOT NULL,
            device     TEXT NOT NULL,             -- SHA-256 of the app's Android ID, never the ID itself
            first_seen TEXT NOT NULL,
            last_seen  TEXT NOT NULL,
            PRIMARY KEY (hid, device)
        );
        CREATE INDEX IF NOT EXISTS idx_player_devices ON player_devices(device);
        CREATE TABLE IF NOT EXISTS mod_log (
            id     INTEGER PRIMARY KEY AUTOINCREMENT,
            ts     TEXT NOT NULL,
            action TEXT NOT NULL,
            target TEXT,                          -- company name or what the action was about
            detail TEXT
        );
    """)


def active_ban(conn, hid, kind="full") -> dict | None:
    """{until, reason} of an active full ban, else None."""
    r = conn.execute("SELECT until, reason FROM player_bans WHERE hid=? AND kind='full' AND (until IS NULL OR until > ?)",
                     (hid, econ.utcnow_iso())).fetchone()
    return {"kind": "full", "until": r[0], "reason": r[1]} if r else None


def ban_text(b) -> str:
    when = "for good" if not b["until"] else "until " + b["until"][:16].replace("T", " ") + " UTC"
    return f"This company is banned {when}." + (f" Reason: {b['reason']}" if b.get("reason") else "")


def set_ban(conn, hid, kind, hours, reason) -> None:
    """kind: 'full' (the only ban left)."""
    until = None if not hours else (econ.utcnow() + datetime.timedelta(hours=float(hours))).isoformat()
    conn.execute("INSERT INTO player_bans(hid, kind, until, reason, ts) VALUES(?,?,?,?,?) ON CONFLICT(hid, kind) "
                 "DO UPDATE SET until=excluded.until, reason=excluded.reason, ts=excluded.ts",
                 (hid, kind, until, reason, econ.utcnow_iso()))
    _ban_cache.clear()


_ban_cache: dict = {}


def is_banned(get_db, hid) -> dict | None:
    """Full ban (cached for 60 s): used when signing in and for every request."""
    hit = _ban_cache.get(hid)
    if hit and time.time() - hit[0] < 60:
        return hit[1]
    with get_db() as conn:
        try:
            b = active_ban(conn, hid, "full")
        except Exception:
            b = None
    _ban_cache[hid] = (time.time(), b)
    return b


def _mod_ok(form) -> bool:
    want = os.environ.get("MOD_PASSWORD", "")
    return bool(want) and hmac.compare_digest(want.encode(), (form.get("mod_password") or "").encode())


_mod_fail = econ.TokenBucket(10, 60.0)


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)
        conn.commit()
    h.is_banned = lambda hid: is_banned(h.get_db, hid)
    import auth
    auth.ban_check = h.is_banned

    from . import players as social

    @api.endpoint("/api/v1/device")
    def device(conn, hid, form):
        """The app's hashed device ID (multi-account detection, owner 2026-10-25)."""
        d = (form.get("device") or "").strip().lower()
        if not re.fullmatch(r"[0-9a-f]{64}", d):
            raise econ.GameError("bad_input", "Invalid device")
        now = econ.utcnow_iso()
        with econ.tx(conn):
            conn.execute("INSERT INTO player_devices(hid, device, first_seen, last_seen) VALUES(?,?,?,?) "
                         "ON CONFLICT(hid, device) DO UPDATE SET last_seen=excluded.last_seen", (hid, d, now, now))
        return {"err": 0}

    @api.endpoint("/api/v1/report", feature="SOCIAL")
    def report(conn, hid, form):
        """kind=player (`pid`); reason one of REASONS; optional note."""
        kind = form.get("kind", "")
        reason = form.get("reason", "other")
        if kind != "player" or reason not in REASONS:
            raise econ.GameError("bad_input", "Invalid report")
        note = (form.get("note") or "").strip()[:500]
        target = social.hid_of(conn, form.get("pid"))
        if not target:
            raise econ.GameError("not_found", "Player not found")
        if target == hid:
            raise econ.GameError("bad_input", "You can't report yourself")
        with econ.tx(conn):
            conn.execute("INSERT OR IGNORE INTO reports(ts, reporter_hid, target_hid, kind, reason, note) "
                         "VALUES(?,?,?,?,?,?)", (econ.utcnow_iso(), hid, target, kind, reason, note))
        return {"err": 0, "message": "Thank you. A moderator will look at it."}

    # ── moderators ──────────────────────────────────────────────────────────

    def mod(fn):
        def wrapped(conn, hid, form):
            if not _mod_ok(form):
                if not _mod_fail.allow("mod"):
                    raise econ.GameError("rate_limited", "Too many attempts. Try again later.")
                raise econ.GameError("auth", "Wrong moderator password")
            return fn(conn, form)
        wrapped.__name__ = fn.__name__
        return wrapped

    def name_of(conn, hid):
        r = conn.execute("SELECT company_name FROM players WHERE hID=?", (hid,)).fetchone()
        return r[0] if r else "(deleted)"

    @api.endpoint("/api/v1/mod/reports", auth=False)
    @mod
    def mod_reports(conn, form):
        status = form.get("status", "open")
        rows = conn.execute("SELECT * FROM reports WHERE status=? ORDER BY id DESC LIMIT 200", (status,)).fetchall()
        out = []
        for r in rows:
            b = active_ban(conn, r["target_hid"])
            out.append({"id": r["id"], "ts": r["ts"], "kind": r["kind"], "reason": r["reason"], "note": r["note"],
                        "text": r["message_text"], "messageId": r["message_id"], "status": r["status"],
                        "reporter": name_of(conn, r["reporter_hid"]), "target": name_of(conn, r["target_hid"]),
                        "targetPid": social.pid_of(conn, r["target_hid"]), "targetBan": b})
        contact = [dict(c) for c in conn.execute("SELECT id, ts, topic, reply_to, company, message, handled FROM contact_messages "
                                                 "WHERE handled=0 ORDER BY id DESC LIMIT 100")] if social._has_table(conn, "contact_messages") else []
        done_contact = [dict(c) for c in conn.execute("SELECT id, ts, topic, reply_to, message FROM contact_messages "
                                                      "WHERE handled=1 ORDER BY id DESC LIMIT 30")] if social._has_table(conn, "contact_messages") else []
        done_reports = [{"id": r["id"], "ts": r["ts"], "reason": r["reason"], "status": r["status"], "action": r["action"],
                         "target": name_of(conn, r["target_hid"])}
                        for r in conn.execute("SELECT * FROM reports WHERE status!='open' ORDER BY id DESC LIMIT 30")]
        q = (form.get("q") or "").strip()
        companies = [{"name": c[0], "pid": social.pid_of(conn, c[1]), "created": c[2], "banned": active_ban(conn, c[1]) is not None}
                     for c in conn.execute("SELECT company_name, hID, created_at FROM players WHERE company_name LIKE ? "
                                           "ORDER BY created_at DESC LIMIT 200", (f"%{q}%",)).fetchall()]
        log = [dict(x) for x in conn.execute("SELECT ts, action, target, detail FROM mod_log ORDER BY id DESC LIMIT 100")]
        bans = [{"target": name_of(conn, b[0]), "pid": social.pid_of(conn, b[0]), "kind": b[1], "until": b[2], "reason": b[3]}
                for b in conn.execute("SELECT hid, kind, until, reason FROM player_bans WHERE until IS NULL OR until > ? "
                                      "ORDER BY ts DESC", (econ.utcnow_iso(),))]
        # phones used by more than one company (possible multi-accounts)
        shared = []
        for (dev,) in conn.execute("SELECT device FROM player_devices GROUP BY device HAVING COUNT(DISTINCT hid) > 1 "
                                   "ORDER BY MAX(last_seen) DESC LIMIT 100").fetchall():
            shared.append({"device": dev[:10], "companies": [
                {"name": name_of(conn, r[0]), "pid": social.pid_of(conn, r[0]), "lastSeen": r[1]}
                for r in conn.execute("SELECT hid, last_seen FROM player_devices WHERE device=? ORDER BY last_seen DESC", (dev,))]})
        conn.commit()
        return {"err": 0, "reports": out, "contact": contact, "bans": bans, "sharedDevices": shared,
                "companies": companies, "doneContact": done_contact, "doneReports": done_reports, "log": log}

    @api.endpoint("/api/v1/mod/act", auth=False)
    @mod
    def mod_act(conn, form):
        """action: dismiss | ban | unban | contact_done | contact_reopen | report_reopen; report id and/or
        pid; hours (empty = forever); reason. Everything is kept in mod_log (one year)."""
        action = form.get("action", "")
        rid = int(form.get("report") or 0)
        r = conn.execute("SELECT * FROM reports WHERE id=?", (rid,)).fetchone() if rid else None
        target = r["target_hid"] if r else (social.hid_of(conn, form.get("pid")) if form.get("pid") else None)
        hours = form.get("hours") or None
        reason = (form.get("reason") or (r["reason"] if r else "")).strip()[:200]
        with econ.tx(conn):
            if action == "ban" and target:
                set_ban(conn, target, "full", hours, reason)
            elif action == "unban" and target:
                conn.execute("DELETE FROM player_bans WHERE hid=?", (target,))
                _ban_cache.clear()
            elif action == "contact_done":
                conn.execute("UPDATE contact_messages SET handled=1 WHERE id=?", (int(form.get("contact") or 0),))
            elif action == "contact_reopen":
                conn.execute("UPDATE contact_messages SET handled=0 WHERE id=?", (int(form.get("contact") or 0),))
            elif action == "report_reopen" and r:
                conn.execute("UPDATE reports SET status='open', action=NULL, handled_at=NULL WHERE id=?", (rid,))
            elif action != "dismiss":
                raise econ.GameError("bad_input", "Unknown action")
            if r and action != "report_reopen":
                status = "dismissed" if action == "dismiss" else "actioned"
                conn.execute("UPDATE reports SET status=?, action=?, handled_at=? WHERE id=? AND status='open'",
                             (status, action, econ.utcnow_iso(), rid))
            what = name_of(conn, target) if target else f"message #{form.get('contact')}" if form.get("contact") else ""
            detail = " ".join(x for x in (f"report #{rid}" if rid else "", f"{hours} hours" if hours else "",
                                          "forever" if action == "ban" and not hours else "", reason) if x)
            conn.execute("INSERT INTO mod_log(ts, action, target, detail) VALUES(?,?,?,?)",
                         (econ.utcnow_iso(), action, what, detail))
            year = (econ.utcnow() - datetime.timedelta(days=365)).isoformat()
            conn.execute("DELETE FROM mod_log WHERE ts < ?", (year,))
        return {"err": 0}
