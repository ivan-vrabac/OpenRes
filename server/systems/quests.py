"""Phase 3 — daily quests, streaks and their rewards.

Lifecycle (documented assumptions):
- Each UTC day a player gets DAILY_COUNT quests, picked deterministically from POOL by
  hash(player, day). The sweep deals them right after midnight (owner 2026-11-02: active at all times,
  not when the list is opened); opening the list deals them too, if that comes first.
- Progress counts everything done that UTC day, also before the list was first opened (owner 2026-11-02:
  a hex built just before opening Quests stayed at 0). It comes from recorded game events (game_events),
  so it is server-side and survives restarts.
- A quest ends at the midnight (UTC) after its day (owner 2026-10-31: quests can't be done
  afterwards). What wasn't completed and claimed by then is gone; the next day starts from zero.
- Only quests the company can do are dealt (doable()): without a Campus that is survey, trade and placing
  it. An undone quest that can't be done any more turns into another one (owner 2026-11-01), and targets
  stay reachable: never more renewals than leases that can be renewed today, never more educations than
  queue slots.
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
KEEP_DAYS = 7                  # days without a claim stay this long
ACTIVE_DAYS = 7                # the sweep deals to companies seen this recently
COMPACT_DAYS = 60              # older days keep one row
WINDOW_DAYS = 14               # compact() looks this far back, so a server that was down catches up
quest_credits, QUEST_MIN_CREDITS, QUEST_CAMPUS_SHARE = g.quest_credits, g.QUEST_MIN_CREDITS, g.QUEST_CAMPUS_SHARE


def campus_level(conn, hid) -> int:
    r = conn.execute("SELECT campus_level FROM co_state WHERE hid=?", (hid,)).fetchone()
    return max(1, r[0] if r else 1)
STREAK_MILESTONES = ((7, 5), (30, 10))     # (every N days, quest rewards)


# code: ((title for 1, title for more), event type, target); a target (lo, hi) varies per player and day
POOL = {
    "build_hexes":  (("Lease {} new hex", "Lease {} new hexes"), "hex_built", (2, 5)),
    "survey":       (("Make {} government survey", "Make {} government surveys"), "survey", (1, 3)),
    "plant":        (("Build or upgrade {} plant", "Build or upgrade {} plants"), "plant_upgraded", (1, 2)),
    "educate":      (("Send {} supervisor to education", "Send {} supervisors to education"), "education_started", (1, 2)),
    "trade":        (("Make {} market trade", "Make {} market trades"), "market_trade", (2, 5)),
    "renew":        (("Renew {} hex lease", "Renew {} hex leases"), "hex_renewed", (1, 3)),
    "visit":        (("Visit your Campus", "Visit your Campus"), "campus_visit", 1),
    "place_campus": (("Place your Campus", "Place your Campus"), "campus_placed", 1),
}


def target_of(code, hid, day) -> int:
    t = POOL[code][2]
    if isinstance(t, tuple):
        lo, hi = t
        return lo + int(hashlib.sha256(f"target|{hid}|{day}|{code}".encode()).hexdigest(), 16) % (hi - lo + 1)
    return t


def title_of(code, target) -> str:
    return POOL[code][0][0 if target == 1 else 1].format(target)


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
        CREATE INDEX IF NOT EXISTS idx_dq_day ON daily_quests(day);
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


def renewable(conn, hid, now) -> int:
    """How many leases can still be renewed before today's quests end (a lease waits a day after its
    last renewal or its build, so a company with few hexes can't do many)."""
    from .company import parse, renew_wait_hours
    left = (_midnight_after(now) - now).total_seconds() / 3600
    return sum(1 for r in conn.execute("SELECT lease_until FROM co_hexes WHERE hid=? AND op!='campus'", (hid,))
               if renew_wait_hours(parse(r[0]), now) <= left)


def doable(conn, hid, code, now) -> bool:
    """Can this company do this quest today?"""
    placed = conn.execute("SELECT 1 FROM co_state WHERE hid=? AND campus_level>0", (hid,)).fetchone() is not None
    if code == "place_campus":
        return not placed
    if code in ("survey", "trade"):
        return True
    if not placed:
        return False
    if code == "renew":
        return renewable(conn, hid, now) > 0
    if code == "educate":
        return conn.execute("SELECT 1 FROM co_supervisors WHERE hid=? AND edu<4", (hid,)).fetchone() is not None
    if code == "build_hexes":
        return conn.execute("SELECT COUNT(*) FROM co_hexes WHERE hid=? AND op!='campus'", (hid,)).fetchone()[0] < g.MAX_HEXES
    return True


def fit_target(conn, hid, code, target, now) -> int:
    """The day's target, cut to what the company can reach."""
    if code == "renew":
        return min(target, max(1, renewable(conn, hid, now)))
    if code == "educate":
        return min(target, g.queue_slots(campus_level(conn, hid)))
    return target


def available(conn, hid, now) -> list:
    return [c for c in POOL if doable(conn, hid, c, now)]


def repair(conn, hid, day, rows, now) -> None:
    """Today's undone quests stay doable: one that can't be done any more becomes another quest, a renew
    target shrinks when there are fewer leases left to renew than it still needs."""
    have = {r["code"] for r in rows}
    for q in rows:
        if q["claimed_at"] or q["code"] not in POOL:
            continue
        target, done = q["target"] or target_of(q["code"], hid, day), progress(conn, q)
        if done >= target:
            continue
        if q["code"] == "renew" and (done or renewable(conn, hid, now)):
            reachable = done + renewable(conn, hid, now)
            if reachable < target:
                conn.execute("UPDATE daily_quests SET target=? WHERE id=?", (reachable, q["id"]))
        elif not doable(conn, hid, q["code"], now):
            spare = [c for c in available(conn, hid, now) if c not in have]
            if spare:
                code = pick(hid, day, spare)[0]
                have.add(code)
                conn.execute("UPDATE daily_quests SET code=?, assigned_at=?, target=? WHERE id=?",
                             (code, now.isoformat(), fit_target(conn, hid, code, target_of(code, hid, day), now), q["id"]))


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
    rows = conn.execute("SELECT * FROM daily_quests WHERE hid=? AND day=?", (hid, day)).fetchall()
    if rows:
        repair(conn, hid, day, rows, now)
        return
    for code in pick(hid, day, available(conn, hid, now)):
        conn.execute("INSERT OR IGNORE INTO daily_quests(hid, day, code, assigned_at, expires_at, target) "
                     "VALUES(?,?,?,?,?,?)", (hid, day, code, now.isoformat(),
                                             _midnight_after(now).isoformat(),
                                             fit_target(conn, hid, code, target_of(code, hid, day), now)))


def deal_all(conn, now=None) -> int:
    """Deal today's quests to companies that played in the last ACTIVE_DAYS and have none yet (run by the sweep,
    a short write per company once a day; anyone else gets theirs on opening the list, so a million sleeping
    companies cost nothing)."""
    now = now or econ.utcnow()
    day = _day(now)
    hids = [r[0] for r in conn.execute(
        "SELECT DISTINCT hid FROM player_activity WHERE day>=? AND hid NOT IN "
        "(SELECT hid FROM daily_quests WHERE day=?)", (_day(now - datetime.timedelta(days=ACTIVE_DAYS)), day)).fetchall()]
    for hid in hids:
        with econ.tx(conn):
            assign_today(conn, hid, now)
    return len(hids)


def compact(conn, now=None) -> None:
    """Once a day (the janitor), over the days that just got old: forget days nothing was claimed on, and of
    older days keep one row, an unclaimed one if there is any, so a day still counts for a streak exactly
    when all of it was claimed."""
    now = now or econ.utcnow()
    span = lambda age: (_day(now - datetime.timedelta(days=age + WINDOW_DAYS)), _day(now - datetime.timedelta(days=age)))
    with econ.tx(conn):
        conn.execute("DELETE FROM daily_quests WHERE day>=? AND day<? AND NOT EXISTS (SELECT 1 FROM daily_quests x "
                     "WHERE x.hid=daily_quests.hid AND x.day=daily_quests.day AND x.claimed_at IS NOT NULL)",
                     span(KEEP_DAYS))
    with econ.tx(conn):
        conn.execute("DELETE FROM daily_quests WHERE day>=? AND day<? AND id NOT IN ("
                     "SELECT COALESCE(MIN(CASE WHEN claimed_at IS NULL THEN id END), MIN(id)) FROM daily_quests "
                     "WHERE day>=? AND day<? GROUP BY hid, day)", span(COMPACT_DAYS) * 2)


def progress(conn, q) -> int:
    target = q["target"] or target_of(q["code"], q["hid"], q["day"])
    n = econ.count_events(conn, q["hid"], POOL[q["code"]][1], f"{q['day']}T00:00:00")
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
