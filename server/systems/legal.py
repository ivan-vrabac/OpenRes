"""Terms of use and privacy policy (owner 2026-10-25).

The texts live in server/legal/*.md, so they can change without an app update. Bump
LEGAL_VERSION whenever they change: the app then shows them again when it opens, and the player
accepts (and keeps playing) or declines (the app closes). Acceptances are recorded per account.
LEGAL_OPERATOR / LEGAL_CONTACT (environment) fill in who runs the server and how to reach them.
"""
from __future__ import annotations

import os

import econ

RETENTION_DAYS = 30                 # logs and backups (privacy policy)
_contact_bucket = econ.TokenBucket(10, 1800.0)   # site-wide: 10 messages, then one more every 30 minutes
TURNSTILE_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"

LEGAL_VERSION = "2026-10-31.6"      # 0.2.3: no chat or messages, Campus/hexes, activity log 7 days
_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "legal")


def text(name: str) -> str:
    with open(os.path.join(_DIR, f"{name}.md"), encoding="utf-8") as f:
        s = f.read()
    return (s.replace("{version}", LEGAL_VERSION)
             .replace("{operator}", os.environ.get("LEGAL_OPERATOR", "the operator of this game server"))
             .replace("{contact}", os.environ.get("LEGAL_CONTACT",
                                                  "Questions, data requests (access, correction, deletion, objection) "
                                                  "and complaints: use the contact form at "
                                                  "https://resources.vrabac.eu/contact.html. We answer within 30 days.")))


def turnstile_ok(token: str) -> bool:
    secret = os.environ.get("TURNSTILE_SECRET", "")
    if not secret:
        return True
    if not token:
        return False
    import httpx
    try:
        return httpx.post(TURNSTILE_URL, timeout=10, data={"secret": secret, "response": token}).json().get("success") is True
    except Exception as e:
        print(f"turnstile check failed: {type(e).__name__}", flush=True)
        return False


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS legal_acceptance (
            hid TEXT NOT NULL, version TEXT NOT NULL, ts TEXT NOT NULL, PRIMARY KEY (hid, version))""")
        conn.execute("""CREATE TABLE IF NOT EXISTS contact_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, topic TEXT NOT NULL, reply_to TEXT,
            company TEXT, message TEXT NOT NULL, ip TEXT, handled INTEGER NOT NULL DEFAULT 0)""")
        conn.commit()

    def janitor():
        """What the privacy policy promises (owner 2026-10-25): server logs and database backups at
        most 30 days, handled contact messages at most 1 year. Runs daily."""
        import glob, json as _json, time
        time.sleep(120)
        while True:
            try:
                cutoff = time.time() - RETENTION_DAYS * 86400
                for pattern in ("/data/backup_*.db", "/data/*.bak", "/data/backups/*", "/logs/*.log.*"):
                    for f in glob.glob(pattern):
                        if os.path.isfile(f) and os.path.getmtime(f) < cutoff:
                            os.remove(f)
                log = os.environ.get("LOG_FILE", "/logs/requests.log")
                if os.path.exists(log):
                    keep_after = (econ.utcnow() - __import__("datetime").timedelta(days=RETENTION_DAYS)).isoformat()
                    with open(log, encoding="utf-8", errors="replace") as f:
                        lines = f.readlines()
                    kept = [l for l in lines if (_json.loads(l).get("ts", "9") if l.startswith("{") else "9") >= keep_after]
                    if len(kept) != len(lines):
                        with open(log, "w", encoding="utf-8") as f:
                            f.writelines(kept)
                with h.get_db() as conn:
                    with econ.tx(conn):
                        year = (econ.utcnow() - __import__("datetime").timedelta(days=365)).isoformat()
                        conn.execute("DELETE FROM contact_messages WHERE ts < ?", (year,))
                        # reports (with the reported text) and ended bans: at most a year
                        conn.execute("DELETE FROM reports WHERE ts < ?", (year,))
                        conn.execute("DELETE FROM player_bans WHERE until IS NOT NULL AND until < ?", (year,))
            except Exception:
                pass
            time.sleep(86400)

    if os.environ.get("WORLD_EVENTS_THREAD", "1") == "1":
        import threading
        threading.Thread(target=janitor, daemon=True, name="retention").start()

    @api.endpoint("/api/v1/legal", auth=False)
    def legal(conn, hid, form):
        """The current terms and privacy policy (no sign-in needed: shown before login)."""
        return {"err": 0, "version": LEGAL_VERSION, "terms": text("terms"), "privacy": text("privacy")}

    @api.endpoint("/api/v1/contact", auth=False)
    def contact(conn, hid, form):
        """The privacy point of contact (Google Play user data policy): a message to the operator.
        No sign-in needed. Stored in contact_messages. Against spam: Cloudflare Turnstile (with
        TURNSTILE_SECRET), a hidden field only robots fill in, and a site-wide limit."""
        if (form.get("website") or "").strip():
            return {"err": 0}                                  # a robot: it thinks it worked
        topic = (form.get("topic") or "other").strip()[:40]
        message = (form.get("message") or "").strip()
        reply_to = (form.get("reply_to") or "").strip()[:200]
        company = (form.get("company") or "").strip()[:40]
        if len(message) < 10:
            raise econ.GameError("bad_input", "Please write a little more (at least 10 characters)")
        if len(message) > 5000:
            raise econ.GameError("bad_input", "Please keep it under 5 000 characters")
        if not turnstile_ok(form.get("turnstile") or ""):
            raise econ.GameError("bad_token", "Please confirm you are not a robot and try again")
        if not _contact_bucket.allow("contact"):
            raise econ.GameError("rate_limited", "Too many messages, please try again later")
        with econ.tx(conn):
            conn.execute("INSERT INTO contact_messages(ts, topic, reply_to, company, message, ip) VALUES(?,?,?,?,?,?)",
                         (econ.utcnow_iso(), topic, reply_to, company, message, None))
        return {"err": 0}

    @api.endpoint("/api/v1/legal/accept")
    def accept(conn, hid, form):
        """Record that this account accepted `version`."""
        v = (form.get("version") or "").strip()
        if v != LEGAL_VERSION:
            raise econ.GameError("bad_input", "Please accept the current terms")
        with econ.tx(conn):
            conn.execute("INSERT OR IGNORE INTO legal_acceptance(hid, version, ts) VALUES(?,?,?)",
                         (hid, v, econ.utcnow_iso()))
        return {"err": 0}
