"""Daily quests on the 0.2.3 activities, progress from events, exactly-once claims, streak rewards."""
import datetime
import threading

import econ
import main
from helpers import call, credits, new_player
from systems import quests

Q = "/api/v1/quests"


def _force_quests(hid, codes, day=None, hours_ago=0):
    """Replace today's batch with known quests (deterministic tests)."""
    now = econ.utcnow() - datetime.timedelta(hours=hours_ago)
    day = day or now.strftime("%Y-%m-%d")
    with main.get_db() as conn:
        conn.execute("DELETE FROM daily_quests WHERE hid=? AND day=?", (hid, day))
        for c in codes:
            conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at) VALUES(?,?,?,?,?)",
                         (hid, day, c, now.isoformat(), (now + datetime.timedelta(hours=48)).isoformat()))
        conn.commit()


def _events(hid, type_, n):
    with main.get_db() as conn:
        for _ in range(n):
            econ.emit(conn, type_, hid, {}, public=False)
        conn.commit()


def test_assignment_is_deterministic_and_daily():
    hid, sid, _ = new_player("qa")
    a = call(Q, sid)["quests"]
    b = call(Q, sid)["quests"]
    assert len(a) == quests.DAILY_COUNT and [q["code"] for q in a] == [q["code"] for q in b]
    assert quests.pick(hid, "2026-01-01", list(quests.POOL)) == quests.pick(hid, "2026-01-01", list(quests.POOL))


def test_progress_claim_once_and_rewards():
    hid, sid, _ = new_player("qb", credits=0)
    call(Q, sid)
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_state(hid, campus_level) VALUES(?,10) ON CONFLICT(hid) DO UPDATE SET campus_level=10",
                     (hid,))
        conn.commit()
    _force_quests(hid, ["survey", "renew", "plant"])
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["survey"]["progress"] == 0 and not qs["survey"]["claimable"]
    assert call(Q + "/claim", sid, id=qs["survey"]["id"])["code"] == "not_done"
    _events(hid, "survey", 5)
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["survey"]["progress"] == qs["survey"]["target"] and qs["survey"]["claimable"]
    r = call(Q + "/claim", sid, id=qs["survey"]["id"])
    assert r["credits"] == quests.quest_credits(10)
    assert credits(hid) == quests.quest_credits(10)
    assert call(Q + "/claim", sid, id=qs["survey"]["id"])["code"] == "already_claimed"


def test_events_before_assignment_do_not_count():
    hid, sid, _ = new_player("qc")
    _events(hid, "survey", 5)
    _force_quests(hid, ["survey", "renew", "plant"])
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["survey"]["progress"] == 0


def test_concurrent_claims_pay_once():
    hid, sid, _ = new_player("qd", credits=0, level=1)
    _force_quests(hid, ["plant", "survey", "renew"])
    _events(hid, "plant_upgraded", 2)
    qid = next(q["id"] for q in call(Q, sid)["quests"] if q["code"] == "plant")
    out = []
    ts = [threading.Thread(target=lambda: out.append(call(Q + "/claim", sid, id=qid))) for _ in range(6)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert sum(1 for r in out if r["err"] == 0) == 1
    assert credits(hid) == quests.quest_credits(1)


def test_expired_quest_cannot_be_claimed():
    hid, sid, _ = new_player("qe")
    yesterday = (econ.utcnow() - datetime.timedelta(days=3)).strftime("%Y-%m-%d")
    _force_quests(hid, ["plant"], day=yesterday, hours_ago=72)
    _events(hid, "plant_upgraded", 2)
    with main.get_db() as conn:
        qid = conn.execute("SELECT id FROM daily_quests WHERE hid=? AND day=?", (hid, yesterday)).fetchone()[0]
    assert call(Q + "/claim", sid, id=qid)["code"] == "expired"


def test_yesterdays_quests_are_gone_even_with_time_left_on_them():
    hid, sid, _ = new_player("qy")
    now = econ.utcnow()
    yesterday = (now - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    _force_quests(hid, ["plant"], day=yesterday, hours_ago=2)            # expires_at is tomorrow: an old quest
    _events(hid, "plant_upgraded", 2)
    with main.get_db() as conn:
        qid = conn.execute("SELECT id FROM daily_quests WHERE hid=? AND day=?", (hid, yesterday)).fetchone()[0]
    assert all(q["day"] != yesterday for q in call(Q, sid)["quests"])
    assert call(Q + "/claim", sid, id=qid)["code"] == "expired"
    assert call(Q, sid)["streak"] == 0                                   # and it can't add a streak day


def test_new_quests_end_at_midnight():
    hid, sid, _ = new_player("qm")
    tomorrow = (econ.utcnow() + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    assert all(q["expiresAt"] == tomorrow + "T00:00:00" for q in call(Q, sid)["quests"])


def test_a_missed_day_adds_nothing_and_today_still_counts_once():
    hid, sid, _ = new_player("qz")
    today = econ.utcnow().date()
    with main.get_db() as conn:
        for back in (3, 2):                   # two good days, yesterday missed
            d = (today - datetime.timedelta(days=back)).isoformat()
            conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                         "VALUES(?,?,?,?,?,?)", (hid, d, "survey", d, d, d))
        conn.commit()
    assert call(Q, sid)["streak"] == 2                                   # alive, and yesterday isn't counted
    today_s = today.isoformat()
    _force_quests(hid, ["plant"], day=today_s)
    _events(hid, "plant_upgraded", 2)
    with main.get_db() as conn:
        qid = conn.execute("SELECT id FROM daily_quests WHERE hid=? AND day=?", (hid, today_s)).fetchone()[0]
    assert call(Q + "/claim", sid, id=qid)["streak"] == 3


def test_seven_and_thirty_day_streak_milestones_paid_once():
    hid, sid, _ = new_player("qf", level=1)
    today = econ.utcnow().date()
    with main.get_db() as conn:          # 29 previous fully-claimed days
        for i in range(29, 0, -1):
            d = (today - datetime.timedelta(days=i)).isoformat()
            for c in ("survey", "renew", "plant"):
                conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                             "VALUES(?,?,?,?,?,?)", (hid, d, c, d, d, d))
        conn.commit()
    _force_quests(hid, ["plant", "survey", "renew"])
    _events(hid, "plant_upgraded", 2)
    _events(hid, "survey", 5)
    _events(hid, "hex_renewed", 3)
    paid = []
    for q in call(Q, sid)["quests"]:
        paid += call(Q + "/claim", sid, id=q["id"])["milestones"]
    # day 30 completes: 7,14,21,28 (5 quest rewards each) + 30 (10 quest rewards)
    u = quests.quest_credits(1)
    assert sorted((m["days"], m["credits"]) for m in paid if "every" in m) == \
        [(7, 5 * u), (14, 5 * u), (21, 5 * u), (28, 5 * u), (30, 10 * u)]
    assert not [m for m in paid if m.get("daily")]                               # a streak day itself pays nothing
    with main.get_db() as conn:
        assert quests.pay_milestones(conn, hid, today.isoformat()) == []   # never twice
        assert quests.current_streak(conn, hid) == 30
        days = conn.execute("SELECT MAX(length) FROM streak_rewards WHERE hid=? AND every=1", (hid,)).fetchone()[0]
        assert days == 30                                       # recorded for the streak achievement


def test_broken_streak_restarts_milestones():
    hid, sid, _ = new_player("qg")
    today = econ.utcnow().date()
    with main.get_db() as conn:
        # 7-day streak long ago (already paid), a gap, then 6 days up to yesterday
        days = [today - datetime.timedelta(days=i) for i in list(range(20, 13, -1)) + list(range(6, 0, -1))]
        for d in days:
            for c in ("survey",):
                conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                             "VALUES(?,?,?,?,?,?)", (hid, d.isoformat(), c, d.isoformat(), d.isoformat(), d.isoformat()))
        quests.pay_milestones(conn, hid, (today - datetime.timedelta(days=14)).isoformat())
        conn.commit()
    _force_quests(hid, ["survey"])
    _events(hid, "survey", 5)
    q = call(Q, sid)["quests"][0]
    r = call(Q + "/claim", sid, id=q["id"])
    u = quests.quest_credits(1)
    assert [(m["days"], m["credits"]) for m in r["milestones"] if "every" in m] == [(7, 5 * u)]   # new streak


def test_variable_targets_and_reward_plan():
    t = {quests.target_of("build_hexes", f"h{i}", "2026-01-01") for i in range(200)}
    assert min(t) >= 2 and max(t) <= 5 and len(t) > 2
    hid, sid, _ = new_player("qtu")
    codes = {q["code"] for q in call(Q, sid)["quests"]}
    assert codes <= set(quests.POOL)
    plan = call(Q, sid)["rewardPlan"]
    u = quests.quest_credits(1)
    assert "daily" not in plan and plan["milestones"][0] == {"every": 7, "credits": 5 * u}


def test_one_missed_day_keeps_the_streak_two_end_it():
    hid, _, _ = new_player("qrest")
    today = econ.utcnow().date()
    with main.get_db() as conn:
        # qualifying: today, (gap 1 day), 2 days ago, 3 days ago, (gap 2 days), 6 days ago
        for back in (0, 2, 3, 6):
            d = (today - datetime.timedelta(days=back)).isoformat()
            conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                         "VALUES(?,?,?,?,?,?)", (hid, d, "survey", d, d, d))
        conn.commit()
        assert quests.streak_ending(conn, hid, today.isoformat()) == 3     # day 6 is cut off by the 2-day gap
        assert quests.current_streak(conn, hid) == 3


def test_quests_of_an_older_list_are_dealt_again():
    hid, sid, _ = new_player("qstale")
    _force_quests(hid, ["factory", "mine", "survey"])       # 'factory' and 'mine' are from the 1.2.3 list
    r = call(Q, sid)
    assert r["err"] == 0 and len(r["quests"]) == quests.DAILY_COUNT
    assert all(q["code"] in quests.POOL for q in r["quests"])
