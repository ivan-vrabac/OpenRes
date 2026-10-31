"""Phase 3 — daily quests, streaks and their rewards.

Lifecycle (documented assumptions):
- Each UTC day a player gets DAILY_COUNT quests, picked deterministically from POOL by
  hash(player, day) when they first open the quest list that day.
- A quest is completed by doing the activity after it was assigned. Progress is counted from
  recorded game events (game_events), so it is server-side and survives restarts.
- A quest ends at the midnight (UTC) after its day (owner 2026-10-31: quests can't be done
  afterwards). What wasn't completed and claimed by then is gone; the next day starts from zero.
- Claiming is atomic and happens at most once per quest (conditional UPDATE + unique keys).
  Reward: credits = 0.2 % of what the next Campus level costs (owner 2026-10-31: no player level any
  more, and lower rewards), at least QUEST_MIN_CREDITS.
- Streak: a "qualifying day" is a UTC day whose whole quest set was claimed that day. The streak
  is the run of consecutive qualifying days. A streak day itself pays nothing
  (owner 2026-10-31: every day was too much); it is still recorded (an every=1 row with 0 credits)
  because the streak achievement counts the days. Milestones (relative to the streak's first day,
  paid once per streak):
    · every 7 consecutive days  → 5 quest rewards
    · every 30 consecutive days → 10 quest rewards  (30-day milestones, NOT calendar months;
      both are paid when a day is a multiple of 7 and of 30, e.g. day 210)
  (0.2.3: Crown Diamonds and Mine Improvements are gone, so the streak pays credits.)
  One missed day is forgiven (it adds nothing, it just doesn't end the streak); two missed days in
  a row end the streak, and a new streak starts its own milestones from day 1 (owner 2026-10-23:
  players need to be able to rest).
"""
from __future__ import annotations

import datetime
import hashlib

import econ
import gamedata as g
from . import int_arg

DAILY_COUNT = 3
QUEST_CAMPUS_SHARE = 0.002     # of the credits the next Campus level costs
QUEST_MIN_CREDITS = 5000


def quest_credits(campus_level: int) -> int:
    nxt = g.campus_upgrade(min(max(1, campus_level), g.CAMPUS_MAX - 1))["credits"]
    return max(QUEST_MIN_CREDITS, int(round(nxt * QUEST_CAMPUS_SHARE, -2)))


def campus_level(conn, hid) -> int:
    r = conn.execute("SELECT campus_level FROM co_state WHERE hid=?", (hid,)).fetchone()
    return max(1, r[0] if r else 1)
STREAK_MILESTONES = ((7, 5), (30, 10))     # (every N days, quest rewards)


# code: (title, event type, target) — target (lo, hi) varies per player and day
POOL = {
    "build_hexes":  ("Build {} hexes", "hex_built", (2, 5)),
    "survey":       ("Make {} government surveys", "survey", (1, 3)),
    "plant":        ("Build or upgrade a plant {} time(s)", "plant_upgraded", (1, 2)),
    "educate":      ("Send {} supervisor(s) to education", "education_started", (1, 2)),
    "trade":        ("Make {} market trades", "market_trade", (2, 5)),
    "renew":        ("Renew {} hex lease(s)", "hex_renewed", (1, 3)),
    "visit":        ("Visit your Campus", "campus_visit", 1),
}


def target_of(code, hid, day) -> int:
    t = POOL[code][2]
    if isinstance(t, tuple):
        lo, hi = t
        return lo + int(hashlib.sha256(f"target|{hid}|{day}|{code}".encode()).hexdigest(), 16) % (hi - lo + 1)
    return t


def title_of(code, target) -> str:
    return POOL[code][0].format(target)


def init_schema(conn) -> None:
    conn.executescript("""
        CREATE TABLE IF NOT EXISTS daily_quests (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            hid          TEXT NOT NULL,
            day          TEXT NOT NULL,          -- UTC date of the batch (YYYY-MM-DD)
            code         TEXT NOT NULL,
            assigned_at  TEXT NOT NULL,
            expires_at   TEXT NOT NULL,
            claimed_at   TEXT,
            target       INTEGER,
            UNIQUE (hid, day, code)
        );
        CREATE INDEX IF NOT EXISTS idx_dq_hid ON daily_quests(hid, day);
        CREATE TABLE IF NOT EXISTS streak_rewards (
            hid        TEXT NOT NULL,
            start_day  TEXT NOT NULL,
            length     INTEGER NOT NULL,
            every      INTEGER NOT NULL,
            diamonds   INTEGER NOT NULL,
            ts         TEXT NOT NULL,
            PRIMARY KEY (hid, start_day, length, every)
        );
    """)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(daily_quests)")]
    if "target" not in cols:
        conn.execute("ALTER TABLE daily_quests ADD COLUMN target INTEGER")
    conn.commit()


def _day(dt: datetime.datetime) -> str:
    return dt.strftime("%Y-%m-%d")


def _midnight_after(dt: datetime.datetime) -> datetime.datetime:
    return datetime.datetime.combine(dt.date() + datetime.timedelta(days=1), datetime.time.min)


def pick(hid: str, day: str, codes) -> list:
    """Deterministic choice of DAILY_COUNT quest codes for (player, day)."""
    ranked = sorted(codes, key=lambda c: hashlib.sha256(f"{hid}|{day}|{c}".encode()).hexdigest())
    return ranked[:DAILY_COUNT]


def assign_today(conn, hid, now=None) -> None:
    now = now or econ.utcnow()
    day = _day(now)
    # quests of a kind that no longer exists (an older quest list) are dropped, so today's are dealt again
    # (claimed ones stay: they count for the streak)
    gone = [c for (c,) in conn.execute("SELECT DISTINCT code FROM daily_quests WHERE hid=? AND claimed_at IS NULL",
                                       (hid,)) if c not in POOL]
    for c in gone:
        conn.execute("DELETE FROM daily_quests WHERE hid=? AND code=? AND claimed_at IS NULL", (hid, c))
    if gone and not conn.execute("SELECT 1 FROM daily_quests WHERE hid=? AND day=? AND claimed_at IS NOT NULL",
                                 (hid, day)).fetchone():
        conn.execute("DELETE FROM daily_quests WHERE hid=? AND day=?", (hid, day))
    if conn.execute("SELECT 1 FROM daily_quests WHERE hid=? AND day=?", (hid, day)).fetchone():
        return
    for code in pick(hid, day, list(POOL)):
        conn.execute("INSERT OR IGNORE INTO daily_quests(hid, day, code, assigned_at, expires_at, target) "
                     "VALUES(?,?,?,?,?,?)", (hid, day, code, now.isoformat(),
                                             _midnight_after(now).isoformat(),
                                             target_of(code, hid, day)))


def progress(conn, q) -> int:
    title, event, _ = POOL[q["code"]]
    target = q["target"] or target_of(q["code"], q["hid"], q["day"])
    n = econ.count_events(conn, q["hid"], event, q["assigned_at"])
    return min(n, target)


def streak_run(conn, hid, day: str):
    """(qualifying days, first day) of the streak ending at `day` (0 if day isn't qualifying).
    Owner 2026-10-23: one missed day is forgiven, two missed days in a row end the streak."""
    qualifying = {r[0] for r in conn.execute(
        "SELECT day FROM daily_quests WHERE hid=? GROUP BY day "
        "HAVING COUNT(*) = SUM(CASE WHEN claimed_at IS NOT NULL THEN 1 ELSE 0 END)", (hid,))}
    d = datetime.date.fromisoformat(day)
    if d.isoformat() not in qualifying:
        return 0, day
    n, gap, first = 0, 0, d
    while gap < 2:
        if d.isoformat() in qualifying:
            n, gap, first = n + 1, 0, d
        else:
            gap += 1
        d -= datetime.timedelta(days=1)
    return n, first.isoformat()


def streak_ending(conn, hid, day: str) -> int:
    return streak_run(conn, hid, day)[0]


def current_streak(conn, hid, now=None) -> int:
    now = now or econ.utcnow()
    # alive while at most one day has been missed since the last qualifying day
    for back in (0, 1, 2):
        n = streak_ending(conn, hid, _day(now - datetime.timedelta(days=back)))
        if n:
            return n
    return 0


def pay_milestones(conn, hid, day: str) -> list:
    """Pay the streak day and any streak milestones reached by the run ending at `day` (idempotent per
    streak). The amounts are in credits, in quest rewards of the company's Campus level."""
    length, start = streak_run(conn, hid, day)
    if not length:
        return []
    unit = quest_credits(campus_level(conn, hid))
    paid = []
    # the streak day is recorded for the achievement (every=1 rows; PK keeps it once per day), unpaid
    conn.execute("INSERT OR IGNORE INTO streak_rewards(hid, start_day, length, every, diamonds, ts) "
                 "VALUES(?,?,?,?,?,?)", (hid, start, length, 1, 0, econ.utcnow_iso()))
    for every, times in STREAK_MILESTONES:
        for m in range(every, length + 1, every):
            amount = unit * times
            cur = conn.execute("INSERT OR IGNORE INTO streak_rewards(hid, start_day, length, every, diamonds, ts) "
                               "VALUES(?,?,?,?,?,?)", (hid, start, m, every, amount, econ.utcnow_iso()))
            if cur.rowcount == 1:
                econ.credit(conn, hid, amount, "streak_reward", f"{start}+{m}")
                econ.emit(conn, "streak_milestone", hid, {"days": m, "credits": amount},
                          dedup=f"streak:{hid}:{start}:{m}:{every}")
                conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                             (hid, f"streak_{m}", f"{m}-day quest streak", econ.utcnow_iso()))
                paid.append({"days": m, "credits": amount, "every": every})
    return paid


def install(api) -> None:
    h = api.h
    with h.get_db() as conn:
        init_schema(conn)
        conn.commit()

    def view(conn, hid, now):
        rows = conn.execute("SELECT * FROM daily_quests WHERE hid=? AND day=? ORDER BY id", (hid, _day(now))).fetchall()
        out = []
        for q in rows:
            if q["code"] not in POOL:
                continue
            target = q["target"] or target_of(q["code"], hid, q["day"])
            p = progress(conn, q)
            out.append({"id": q["id"], "day": q["day"], "code": q["code"], "title": title_of(q["code"], target),
                        "target": target,
                        "progress": p, "expiresAt": q["expires_at"], "claimed": q["claimed_at"] is not None,
                        "claimable": q["claimed_at"] is None and p >= target})
        return out

    @api.endpoint("/api/v1/quests", feature="QUESTS")
    def quests(conn, hid, form):
        now = econ.utcnow()
        with econ.tx(conn):
            assign_today(conn, hid, now)
        level = campus_level(conn, hid)
        streak = current_streak(conn, hid, now)
        nxt = min(((streak // e) + 1) * e for e, _ in STREAK_MILESTONES)
        return {"err": 0, "quests": view(conn, hid, now), "streak": streak, "nextMilestone": nxt,
                "reward": {"credits": quest_credits(level)},
                "milestones": [{"every": e, "credits": quest_credits(level) * t} for e, t in STREAK_MILESTONES],
                # everything the Rewards button lists
                "rewardPlan": {
                    "perQuest": [{"itemID": 1, "qty": quest_credits(level)}],
                    "milestones": [{"every": e, "credits": quest_credits(level) * t} for e, t in STREAK_MILESTONES]}}

    @api.endpoint("/api/v1/quests/claim", feature="QUESTS")
    def claim(conn, hid, form):
        qid = int_arg(form, "id", None, 1)
        now = econ.utcnow()
        with econ.tx(conn):
            q = conn.execute("SELECT * FROM daily_quests WHERE id=? AND hid=?", (qid, hid)).fetchone()
            if not q:
                raise econ.GameError("not_found", "Quest not found")
            if q["claimed_at"]:
                raise econ.GameError("already_claimed", "Reward already claimed")
            if q["day"] != _day(now):
                raise econ.GameError("expired", "This quest has expired")
            if progress(conn, q) < (q["target"] or target_of(q["code"], hid, q["day"])):
                raise econ.GameError("not_done", "Quest not completed yet")
            cur = conn.execute("UPDATE daily_quests SET claimed_at=? WHERE id=? AND claimed_at IS NULL",
                               (now.isoformat(), qid))
            if cur.rowcount != 1:      # lost a race with a concurrent claim
                raise econ.GameError("already_claimed", "Reward already claimed")
            credits = quest_credits(campus_level(conn, hid))
            econ.credit(conn, hid, credits, "quest_reward", str(qid))
            econ.emit(conn, "quest_completed", hid, {"code": q["code"]}, public=False)
            conn.execute("INSERT OR IGNORE INTO achievements(hid, code, title, ts) VALUES(?,?,?,?)",
                         (hid, "first_quest", "Completed a daily quest", now.isoformat()))
            milestones = pay_milestones(conn, hid, q["day"])
        return {"err": 0, "credits": credits, "milestones": milestones,
                "streak": current_streak(conn, hid, now)}
