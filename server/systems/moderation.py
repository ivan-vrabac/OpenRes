"""Moderation (owner 2026-10-25; Google Play requires reporting and acting on reports). Chat and
private messages were removed in 0.2.3, so what is left is about players (company names).

- Report: a player reports another player (company), with a reason and an optional note.
- Bans: a full ban (no sign-in at all), for some hours or forever.
- Moderators: /api/v1/mod/* with the moderator password (MOD_PASSWORD, environment) -- the page
  https://resources.vrabac.eu/mod.html and `python admin.py` use them.
- Cheat signals (owner 2026-11-06): impossible position jumps (the travel check), failed Play Integrity checks
  and fake GPS the app saw are kept in cheat_signals; the page lists suspects, a company's full picture, and
  can ban and wipe a company's game. Reviewed signals go to the archive.
- Retention (mod_settings): how long moderation data is kept, 30 days up to what the privacy policy promises
  (RETENTION_LIMITS); nothing is deleted by hand, the daily janitor does it.
"""
from __future__ import annotations

import datetime
import hmac
import math
import os
import re
import time

import econ
import names

REASONS = ("insult", "hate", "sexual", "spam", "cheating", "other")
SIGNAL_KINDS = ("teleport", "integrity", "mock_gps")
SIGNAL_GAP_S = 600              # the same kind for the same company counts once per 10 minutes
# key: (what it is, default days, the most the privacy policy allows). Longer needs a new privacy policy.
RETENTION_LIMITS = {
    "reports":      ("Reports (with the reported text)", 365, 365),
    "ended_bans":   ("Ended bans", 365, 365),
    "mod_log":      ("Moderation log", 365, 365),
    "contact":      ("Contact messages", 365, 365),
    "cheat_signals": ("Cheat signals (jumps, device checks, fake GPS)", 365, 365),
}
RETENTION_MIN = 30
# spoofing risk (owner 2026-11-06): points per unreviewed signal, per other company on the same phone, and for a
# failed device check; 0-4 low, 5-14 medium, 15+ high
RISK_POINTS = {"teleport": 3, "mock_gps": 5, "integrity": 4}
RISK_SAME_PHONE = 2
RISK_FAILED_CHECK = 5
RISK_LEVELS = ((15, "high"), (5, "medium"), (0, "low"))


def risk_of(kinds: dict, same_phone: int, integrity_ok) -> tuple[int, str]:
    pts = sum(RISK_POINTS.get(k, 1) * n for k, n in kinds.items()) + RISK_SAME_PHONE * same_phone
    if integrity_ok is False:
        pts += RISK_FAILED_CHECK
    return pts, next(name for floor, name in RISK_LEVELS if pts >= floor)
# a company's game, wiped by a moderator (the account, its ban, reports and cheat signals stay)
GAME_TABLES = ("co_state", "co_moves", "co_hexes", "co_supervisors", "co_education", "co_stock", "co_plants",
               "co_luxury", "daily_quests", "streak_rewards", "achievements")

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
        CREATE TABLE IF NOT EXISTS cheat_signals (
            id       INTEGER PRIMARY KEY AUTOINCREMENT,
            ts       TEXT NOT NULL,
            hid      TEXT NOT NULL,
            kind     TEXT NOT NULL,                 -- teleport | integrity | mock_gps
            detail   TEXT,
            lat      REAL, lng REAL,
            reviewed INTEGER NOT NULL DEFAULT 0     -- 1: looked at (the archive)
        );
        CREATE INDEX IF NOT EXISTS idx_cheat_hid ON cheat_signals(hid, ts);
        CREATE TABLE IF NOT EXISTS mod_settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
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
    """Full ban (cached for 15 s per process: a ban reaches every process of the server within 15 s)."""
    hit = _ban_cache.get(hid)
    if hit and time.time() - hit[0] < 15:
        return hit[1]
    with get_db() as conn:
        try:
            b = active_ban(conn, hid, "full")
        except Exception:
            b = None
    _ban_cache[hid] = (time.time(), b)
    return b


def signal(conn, hid, kind, detail="", lat=None, lng=None) -> None:
    """Record a cheat signal (inside the caller's transaction or on its own); once per SIGNAL_GAP_S per kind."""
    if not hid or kind not in SIGNAL_KINDS:
        return
    since = (econ.utcnow() - datetime.timedelta(seconds=SIGNAL_GAP_S)).isoformat()
    if conn.execute("SELECT 1 FROM cheat_signals WHERE hid=? AND kind=? AND ts>?", (hid, kind, since)).fetchone():
        return
    conn.execute("INSERT INTO cheat_signals(ts, hid, kind, detail, lat, lng) VALUES(?,?,?,?,?,?)",
                 (econ.utcnow_iso(), hid, kind, (detail or "")[:300], lat, lng))


def retention_days(conn, key) -> int:
    _, default, most = RETENTION_LIMITS[key]
    r = conn.execute("SELECT value FROM mod_settings WHERE key=?", (f"retention.{key}",)).fetchone()
    try:
        v = int(r[0]) if r else default
    except ValueError:
        v = default
    return max(RETENTION_MIN, min(most, v))


def prune(conn, now=None) -> None:
    """The janitor's part for moderation data (inside a tx): everything older than its retention."""
    now = now or econ.utcnow()
    cut = lambda key: (now - datetime.timedelta(days=retention_days(conn, key))).isoformat()
    conn.execute("DELETE FROM reports WHERE ts < ?", (cut("reports"),))
    conn.execute("DELETE FROM player_bans WHERE until IS NOT NULL AND until < ?", (cut("ended_bans"),))
    conn.execute("DELETE FROM mod_log WHERE ts < ?", (cut("mod_log"),))
    conn.execute("DELETE FROM cheat_signals WHERE ts < ?", (cut("cheat_signals"),))
    if conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='contact_messages'").fetchone():
        conn.execute("DELETE FROM contact_messages WHERE ts < ?", (cut("contact"),))


def wipe_game(conn, hid) -> int:
    """A company's whole game goes (inside a tx): Campus, hexes, storage, plants, quests, open buy orders,
    credits. The account stays (so a ban holds), and so do reports, cheat signals and the ledger."""
    n = 0
    have = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    for t in GAME_TABLES:
        if t in have:
            n += conn.execute(f"DELETE FROM {t} WHERE hid=?", (hid,)).rowcount
    if "market_orders" in have:
        n += conn.execute("UPDATE market_orders SET status='cancelled', qty_open=0, escrow=0 "
                          "WHERE hid=? AND status='open'", (hid,)).rowcount
    conn.execute("UPDATE players SET credits=0, xp=0 WHERE hID=?", (hid,))
    return n


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

    @api.endpoint("/api/v1/signal")
    def app_signal(conn, hid, form):
        """The app saw a fake (mock) GPS position (owner 2026-11-06). Kept for moderators, nothing else happens."""
        kind = form.get("kind") or ""
        if kind != "mock_gps":
            raise econ.GameError("bad_input", "Invalid signal")
        try:
            lat, lng = float(form.get("lat")), float(form.get("lng"))
            if not (math.isfinite(lat) and math.isfinite(lng) and -90 <= lat <= 90 and -180 <= lng <= 180):
                lat = lng = None                       # NaN or nonsense would break the moderators' JSON
        except (TypeError, ValueError):
            lat = lng = None
        with econ.tx(conn):
            signal(conn, hid, kind, (form.get("detail") or "")[:100], lat, lng)
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
        # one company's full picture through this path too: the website forwards only reports and act (owner
        # 2026-11-06: the details never opened on resources.vrabac.eu)
        if form.get("company"):
            return mod_company(conn, "", {**form, "pid": form.get("company")})
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
        now_iso = econ.utcnow_iso()
        ended = [{"target": name_of(conn, b[0]), "pid": social.pid_of(conn, b[0]), "until": b[1], "reason": b[2]}
                 for b in conn.execute("SELECT hid, until, reason FROM player_bans WHERE until IS NOT NULL AND until <= ? "
                                       "ORDER BY until DESC LIMIT 100", (now_iso,))]
        # suspects: companies with cheat signals nobody has looked at yet, the most first
        suspects = []
        for hid_, n_, last in conn.execute("SELECT hid, COUNT(*), MAX(ts) FROM cheat_signals WHERE reviewed=0 "
                                           "GROUP BY hid ORDER BY COUNT(*) DESC, MAX(ts) DESC LIMIT 200").fetchall():
            kinds = dict(conn.execute("SELECT kind, COUNT(*) FROM cheat_signals WHERE hid=? AND reviewed=0 GROUP BY kind",
                                      (hid_,)).fetchall())
            short = _profile_short(conn, hid_)
            pts, level = risk_of(kinds, short["sameDevice"], short["integrityOk"])
            suspects.append({"name": name_of(conn, hid_), "pid": social.pid_of(conn, hid_), "signals": n_, "last": last,
                             "kinds": kinds, "risk": pts, "riskLevel": level, **short})
        suspects.sort(key=lambda x: -x["risk"])          # stable: then the most signals, the latest
        archived = [{"name": name_of(conn, r[0]), "pid": social.pid_of(conn, r[0]), "signals": r[1], "last": r[2]}
                    for r in conn.execute("SELECT hid, COUNT(*), MAX(ts) FROM cheat_signals WHERE reviewed=1 GROUP BY hid "
                                          "ORDER BY MAX(ts) DESC LIMIT 100")]
        retention = [{"key": k, "label": lab, "days": retention_days(conn, k), "min": RETENTION_MIN, "max": most,
                      "default": d} for k, (lab, d, most) in RETENTION_LIMITS.items()]
        conn.commit()
        return {"err": 0, "reports": out, "contact": contact, "bans": bans, "sharedDevices": shared,
                "companies": companies, "doneContact": done_contact, "doneReports": done_reports, "log": log,
                "endedBans": ended, "suspects": suspects, "archivedSignals": archived, "retention": retention}

    def _profile_short(conn, hid_):
        st = conn.execute("SELECT campus_level FROM co_state WHERE hid=?", (hid_,)).fetchone()
        ig = conn.execute("SELECT ok FROM co_integrity WHERE hid=?", (hid_,)).fetchone()
        devs = conn.execute("SELECT COUNT(DISTINCT d2.hid) FROM player_devices d1 JOIN player_devices d2 "
                            "ON d1.device=d2.device AND d2.hid<>d1.hid WHERE d1.hid=?", (hid_,)).fetchone()[0]
        return {"campus": st[0] if st else 0, "integrityOk": None if not ig else bool(ig[0]),
                "sameDevice": devs, "banned": active_ban(conn, hid_) is not None}

    @api.endpoint("/api/v1/mod/company", auth=False)
    @mod
    def mod_company(conn, form):
        """Everything about one company (pid) for an investigation."""
        hid_ = social.hid_of(conn, form.get("pid"))
        if not hid_:
            raise econ.GameError("not_found", "Company not found")
        p = conn.execute("SELECT * FROM players WHERE hID=?", (hid_,)).fetchone()
        keys = p.keys()
        st = conn.execute("SELECT * FROM co_state WHERE hid=?", (hid_,)).fetchone()
        ig = conn.execute("SELECT ok, problems, verdict, checked_at FROM co_integrity WHERE hid=?", (hid_,)).fetchone()
        devices = []
        for dev, first, last in conn.execute("SELECT device, first_seen, last_seen FROM player_devices WHERE hid=? "
                                             "ORDER BY last_seen DESC", (hid_,)).fetchall():
            others = [{"name": name_of(conn, o[0]), "pid": social.pid_of(conn, o[0])} for o in conn.execute(
                "SELECT hid FROM player_devices WHERE device=? AND hid<>?", (dev, hid_))]
            devices.append({"device": dev[:10], "first": first, "last": last, "others": others})
        signals = [dict(r) for r in conn.execute("SELECT id, ts, kind, detail, lat, lng, reviewed FROM cheat_signals "
                                                 "WHERE hid=? ORDER BY id DESC LIMIT 300", (hid_,))]
        log = [{"ts": r[0], "type": r[1], "data": r[2]} for r in conn.execute(
            "SELECT created_at, log_type, data_json FROM proto_log WHERE hid=? ORDER BY created_at DESC LIMIT 100", (hid_,))]
        hexes = conn.execute("SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus'", (hid_,)).fetchone()[0]
        reports = [{"ts": r[0], "reason": r[1], "note": r[2], "status": r[3], "by": name_of(conn, r[4])}
                   for r in conn.execute("SELECT ts, reason, note, status, reporter_hid FROM reports WHERE target_hid=? "
                                         "ORDER BY id DESC LIMIT 50", (hid_,))]
        days = conn.execute("SELECT COUNT(*) FROM player_activity WHERE hid=?", (hid_,)).fetchone()[0]
        col = lambda k: p[k] if k in keys else None
        return {"err": 0, "name": p["company_name"], "pid": form.get("pid"), "created": p["created_at"],
                "credits": p["credits"], "invested": p["xp"], "country": col("country_code") or "",
                "position": {"lat": col("pos_lat"), "lng": col("pos_lng"), "at": col("pos_at")},
                "campus": None if not st else {"level": st["campus_level"], "lat": st["campus_lat"], "lng": st["campus_lng"]},
                "hexes": hexes, "daysPlayed": days, "ban": active_ban(conn, hid_), "reports": reports,
                "integrity": None if not ig else {"ok": bool(ig["ok"]), "problems": ig["problems"],
                                                  "verdict": ig["verdict"], "at": ig["checked_at"]},
                "devices": devices, "signals": signals, "log": log}

    @api.endpoint("/api/v1/mod/act", auth=False)
    @mod
    def mod_act(conn, form):
        """action: dismiss | ban | unban | rename (`name`) | contact_done | contact_reopen | report_reopen; report id and/or
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
            elif action == "rename" and target:
                # an offensive name goes without asking the player (terms section 6); free, no name change used
                new = (form.get("name") or "").strip()
                problem = names.name_problem(new)
                if problem:
                    raise econ.GameError("invalid_name", problem)
                if conn.execute("SELECT 1 FROM players WHERE lower(company_name)=? AND hID<>?",
                                (h.norm_name(new), target)).fetchone():
                    raise econ.GameError("name_taken", "That company name is taken")
                old = name_of(conn, target)
                conn.execute("UPDATE players SET company_name=? WHERE hID=?", (new, target))
                h.add_proto(conn, target, "rename", {"from": old, "to": new, "cost": 0})
                reason = f"was {old}"
            elif action == "contact_done":
                conn.execute("UPDATE contact_messages SET handled=1 WHERE id=?", (int(form.get("contact") or 0),))
            elif action == "contact_reopen":
                conn.execute("UPDATE contact_messages SET handled=0 WHERE id=?", (int(form.get("contact") or 0),))
            elif action == "report_reopen" and r:
                conn.execute("UPDATE reports SET status='open', action=NULL, handled_at=NULL WHERE id=?", (rid,))
            elif action in ("signals_done", "signals_reopen") and target:
                conn.execute("UPDATE cheat_signals SET reviewed=? WHERE hid=?", (1 if action == "signals_done" else 0, target))
            elif action == "wipe" and target:
                # banned for good and the whole game removed; the company name typed again confirms it
                if (form.get("confirm") or "") != name_of(conn, target):
                    raise econ.GameError("bad_input", "Type the company name to confirm")
                set_ban(conn, target, "full", None, reason or "cheating")
                n = wipe_game(conn, target)
                conn.execute("UPDATE cheat_signals SET reviewed=1 WHERE hid=?", (target,))
                reason = f"{reason or 'cheating'}, banned for good, {n} rows of game data removed"
            elif action == "retention":
                key = form.get("key") or ""
                if key not in RETENTION_LIMITS:
                    raise econ.GameError("bad_input", "Unknown setting")
                try:
                    days = int(form.get("days") or 0)
                except ValueError:
                    days = 0
                most = RETENTION_LIMITS[key][2]
                if not RETENTION_MIN <= days <= most:
                    raise econ.GameError("bad_input", f"Between {RETENTION_MIN} and {most} days "
                                                      "(longer needs a new privacy policy)")
                conn.execute("INSERT INTO mod_settings(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET "
                             "value=excluded.value", (f"retention.{key}", str(days)))
                reason = f"{RETENTION_LIMITS[key][0]}: {days} days"
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
        return {"err": 0}
