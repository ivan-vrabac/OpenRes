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


def test_the_whole_day_counts_not_only_after_opening_the_list():
    hid, sid, _ = new_player("qc")
    _events(hid, "survey", 1)
    with main.get_db() as conn:                  # one from yesterday must not count
        conn.execute("UPDATE game_events SET ts=? WHERE hid=? AND type='survey'",
                     ((econ.utcnow() - datetime.timedelta(days=1)).isoformat(), hid))
        conn.commit()
    _events(hid, "survey", 1)
    _force_quests(hid, ["survey", "trade", "place_campus"])
    with main.get_db() as conn:
        conn.execute("UPDATE daily_quests SET target=3 WHERE hid=? AND code='survey'", (hid,))
        conn.commit()
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["survey"]["progress"] == 1


def test_the_sweep_deals_everyone_once_a_day_and_forgets_unclaimed_days():
    a = new_player("qdeal")[0]
    asleep = new_player("qsleep")[0]
    old = (econ.utcnow() - datetime.timedelta(days=quests.KEEP_DAYS + 1)).strftime("%Y-%m-%d")
    day = econ.utcnow().strftime("%Y-%m-%d")
    with main.get_db() as conn:
        conn.execute("INSERT OR IGNORE INTO player_activity(hid, day) VALUES(?,?)", (a, day))
        conn.execute("DELETE FROM player_activity WHERE hid=?", (asleep,))
        conn.execute("DELETE FROM daily_quests WHERE hid=?", (a,))
        conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at) VALUES(?,?,'survey','x','x')", (a, old))
        conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                     "VALUES(?,?,'trade','x','x','x')", (a, "2020-01-01"))
        conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at) VALUES(?,?,'survey','x','x')", (a, "2020-01-01"))
        conn.commit()
        assert quests.deal_all(conn) >= 1
        assert not conn.execute("SELECT 1 FROM daily_quests WHERE hid=? AND day=?", (asleep, day)).fetchone()   # asleep: no writes
        assert conn.execute("SELECT COUNT(*) FROM daily_quests WHERE hid=? AND day=?", (a, day)).fetchone()[0] == quests.DAILY_COUNT
        assert quests.deal_all(conn) == 0
        quests.compact(conn)
        assert not conn.execute("SELECT 1 FROM daily_quests WHERE hid=? AND day=?", (a, old)).fetchone()
        assert conn.execute("SELECT COUNT(*) FROM daily_quests WHERE hid=? AND day='2020-01-01'", (a,)).fetchone()[0] == 2


def test_only_doable_quests_without_a_campus():
    hid = new_player("qnoc")[0]
    with main.get_db() as conn:
        assert set(quests.available(conn, hid, econ.utcnow())) == {"survey", "trade", "place_campus"}
        conn.rollback()


def test_undoable_quests_are_swapped_and_done_ones_stay():
    hid, sid, _ = new_player("qswap")
    _force_quests(hid, ["plant", "visit", "educate"])
    assert {q["code"] for q in call(Q, sid)["quests"]} == {"survey", "trade", "place_campus"}
    from test_company import BASE
    at = (BASE[0] - 2.31, BASE[1] + 1.4)
    assert call("/api/v3/campus/place", sid, lat=at[0], lng=at[1], plat=at[0], plng=at[1])["err"] == 0
    qs = {q["code"]: q for q in call(Q, sid)["quests"]}
    assert qs["place_campus"]["claimable"]              # placing it counts, and the quest stays


def test_titles_read_right():
    assert quests.title_of("survey", 1) == "Make 1 government survey"
    assert quests.title_of("build_hexes", 2) == "Lease 2 new hexes"
    assert not any("(s)" in quests.title_of(c, t) for c in quests.POOL for t in (1, 2))


def test_every_quest_counts_from_the_real_action():
    from test_company import BASE, find, put, set_lease
    import gamedata as g
    near = (BASE[0] + 1.17, BASE[1] - 0.83)
    hid, sid, _ = new_player("qall", credits=10 ** 12)
    call("/api/v3/state", sid)
    with main.get_db() as conn:
        conn.execute("UPDATE players SET credits=? WHERE hID=?", (10 ** 12, hid))
        conn.commit()

    def count(code):
        with main.get_db() as conn:
            return quests.progress(conn, {"code": code, "hid": hid, "day": econ.utcnow().strftime("%Y-%m-%d"), "target": 99})

    assert call("/api/v3/campus/place", sid, lat=near[0], lng=near[1], plat=near[0], plng=near[1])["err"] == 0
    assert count("place_campus") == 1
    assert call("/api/v3/campus/visit", sid, lat=near[0], lng=near[1])["err"] == 0
    assert count("visit") == 1
    assert call("/api/v3/survey", sid, lat=near[0], lng=near[1], radius=100)["err"] == 0
    assert count("survey") == 1
    a = find("wood", near=(near[0] + 0.01, near[1]))
    r = call("/api/v3/hex/build", sid, lat=a[0], lng=a[1], plat=a[0], plng=a[1], op="logging_camp", item="wood")
    assert r["err"] == 0 and count("build_hexes") == 1
    set_lease(r["id"], 60)
    assert call("/api/v3/hex/renew", sid, ids=str(r["id"]))["err"] == 0
    assert count("renew") == 1
    assert call("/api/v3/plants/build", sid, key="sawmill")["err"] == 0
    assert call("/api/v3/plants/upgrade", sid, key="sawmill")["err"] == 0
    assert count("plant") == 2
    put(hid, "books", 10)
    with main.get_db() as conn:
        sup = conn.execute("SELECT id FROM co_supervisors WHERE hid=? LIMIT 1", (hid,)).fetchone()[0]
    assert call("/api/v3/education/start", sid, sup=sup)["err"] == 0
    assert count("educate") == 1


def test_a_sale_to_the_system_from_storage_is_a_trade():
    from test_market import player, put
    hid, sid = player("qstore")
    put(hid, "wood", 10)
    before = credits(hid)
    r = call("/api/v3/sell", sid, item="wood", qty=10)
    assert r["err"] == 0 and r["system"] == 10
    with main.get_db() as conn:
        assert econ.count_events(conn, hid, "market_trade", "2000") == 1
        assert conn.execute("SELECT COUNT(*) FROM market_trades WHERE seller_hid=? AND kind='system_sell'", (hid,)).fetchone()[0] == 1
        assert conn.execute("SELECT credits FROM ledger WHERE hid=? AND kind='system_sell'", (hid,)).fetchone()[0] == credits(hid) - before
    assert r["credits"] == credits(hid) - before


def test_a_sale_that_fails_halfway_changes_nothing_and_tells_nobody(monkeypatch):
    import gamedata as g
    from test_market import M, have, player, put
    buyer, b_sid = player("qrb", cr=10 ** 9)
    seller, s_sid = player("qrs")
    item = "clay"
    assert call(M + "order", b_sid, item=item, qty=5, price=g.PRICES[item] * 1.1)["err"] == 0
    put(seller, item, 10)
    stock, cash, escrow = have(seller, item), credits(seller), credits(buyer)
    told, real_emit, seen = [], econ.emit, []
    monkeypatch.setattr(main.SYSTEM_HELPERS, "notify", lambda *a, **k: told.append(a))

    def emit(conn, type_, *a, **k):
        if type_ == "market_trade":
            seen.append(1)
            if len(seen) == 3:                  # the order is filled (2 events), then the system sale fails
                raise RuntimeError("power cut")
        return real_emit(conn, type_, *a, **k)

    monkeypatch.setattr(econ, "emit", emit)
    try:
        call("/api/v3/sell", s_sid, item=item, qty=10)
        raised = False
    except RuntimeError:
        raised = True
    assert raised and len(seen) == 3
    monkeypatch.setattr(econ, "emit", real_emit)
    assert have(seller, item) == stock and credits(seller) == cash and credits(buyer) == escrow
    assert have(buyer, item) == 0 and told == []
    with main.get_db() as conn:
        assert conn.execute("SELECT qty_open, status FROM market_orders WHERE hid=? AND item=?", (buyer, item)).fetchone()[0] == 5
        assert econ.count_events(conn, seller, "market_trade", "2000") == 0
    # and the same sale works afterwards, the buyer told once
    assert call("/api/v3/sell", s_sid, item=item, qty=10)["sold"] == 10
    assert have(seller, item) == 0 and len(told) == 1


def test_selling_the_same_goods_at_once_sells_them_once():
    from test_market import have, player, put
    hid, sid = player("qrace")
    put(hid, "wood", 10)
    before = credits(hid)
    out = []
    ts = [threading.Thread(target=lambda: out.append(call("/api/v3/sell", sid, item="wood", qty=10))) for _ in range(6)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    good = [r for r in out if r["err"] == 0]
    assert len(good) == 1 and have(hid, "wood") == 0 and credits(hid) - before == good[0]["credits"]


def test_old_quest_days_shrink_to_one_row_and_streaks_stay():
    hid = new_player("qcomp")[0]
    now = econ.utcnow().replace(hour=12)
    with main.get_db() as conn:
        for back in range(0, 70):
            day = (now - datetime.timedelta(days=back)).strftime("%Y-%m-%d")
            for c in ("survey", "trade", "visit"):
                conn.execute("INSERT INTO daily_quests(hid, day, code, assigned_at, expires_at, claimed_at) "
                             "VALUES(?,?,?,'x','x','x')", (hid, day, c))
        half = (now - datetime.timedelta(days=65)).strftime("%Y-%m-%d")           # a day only partly done
        conn.execute("UPDATE daily_quests SET claimed_at=NULL WHERE hid=? AND day=? AND code='visit'", (hid, half))
        conn.commit()
        today = now.strftime("%Y-%m-%d")
        before = quests.streak_ending(conn, hid, today)
        quests.compact(conn, now)
        per_day = dict(conn.execute("SELECT day, COUNT(*) FROM daily_quests WHERE hid=? GROUP BY day", (hid,)).fetchall())
        assert per_day[half] == 1 and per_day[today] == 3
        assert per_day[(now - datetime.timedelta(days=61)).strftime("%Y-%m-%d")] == 1
        assert per_day[(now - datetime.timedelta(days=59)).strftime("%Y-%m-%d")] == 3
        assert quests.streak_ending(conn, hid, today) == before               # the half day still doesn't count


def test_old_activity_goes_but_the_leaderboard_days_stay():
    from systems import legal
    hid = new_player("qact")[0]
    now = econ.utcnow()
    with main.get_db() as conn:
        for back in (0, 100, 109, 111, 300):
            conn.execute("INSERT OR IGNORE INTO player_activity(hid, day) VALUES(?,?)",
                         (hid, (now - datetime.timedelta(days=back)).strftime("%Y-%m-%d")))
        conn.commit()
        legal.prune_history(conn, now)
        assert conn.execute("SELECT COUNT(*) FROM player_activity WHERE hid=?", (hid,)).fetchone()[0] == 3


def test_the_survey_achievement_outlives_the_event_log():
    from systems import achievements, legal
    from test_company import setup_hq
    hid, sid = setup_hq("qsurv", at=(45.47, 16.41))
    assert call("/api/v3/survey", sid, lat=45.47, lng=16.41, radius=100)["err"] == 0
    with main.get_db() as conn:
        conn.execute("UPDATE game_events SET ts='2020-01-01T00:00:00' WHERE hid=? AND type='survey'", (hid,))
        conn.commit()
        legal.prune_history(conn)
        assert econ.count_events(conn, hid, "survey", "2000") == 0
        assert achievements.metrics(conn, main.SYSTEM_HELPERS, hid)["surveys"] == 1


def test_old_ledger_and_events_go_in_batches():
    from systems import legal
    hid = new_player("qprune")[0]
    now = econ.utcnow()
    old = (now - datetime.timedelta(days=200)).isoformat()
    with main.get_db() as conn:
        conn.execute("DELETE FROM ledger")
        conn.execute("DELETE FROM game_events")
        for i in range(25):
            conn.execute("INSERT INTO ledger(ts, hid, kind, credits) VALUES(?,?,'test',1)", (old, hid))
            conn.execute("INSERT INTO game_events(ts, type, hid, data) VALUES(?,?,?,'{}')", (old, "survey" if i < 3 else "hex_built", hid))
        conn.execute("INSERT INTO ledger(ts, hid, kind, credits) VALUES(?,?,'test',1)", (now.isoformat(), hid))
        conn.execute("INSERT INTO game_events(ts, type, hid, data) VALUES(?,'hex_built',?,'{}')", (now.isoformat(), hid))
        conn.commit()
        assert legal.prune(conn, "ledger", (now - datetime.timedelta(days=90)).isoformat(), batch=10) == 25
        legal.prune_history(conn, now)
        assert conn.execute("SELECT COUNT(*) FROM ledger").fetchone()[0] == 1
        assert [r[0] for r in conn.execute("SELECT type FROM game_events")] == ["hex_built"]


def test_a_trade_counts_for_both_sides():
    from test_market import M, player, put
    buyer, b_sid = player("qbuy", cr=10 ** 9)
    seller, s_sid = player("qsel")
    import gamedata as g
    item = "wood"
    assert call(M + "order", b_sid, item=item, qty=10, price=g.PRICES[item] * 1.1)["err"] == 0
    put(seller, item, 10)
    assert call("/api/v3/sell", s_sid, item=item, qty=10)["err"] == 0
    with main.get_db() as conn:
        n = {who: econ.count_events(conn, who, "market_trade", "2000") for who in (buyer, seller)}
    assert n == {buyer: 1, seller: 1}


def test_a_renew_quest_asks_for_no_more_than_can_be_renewed():
    from test_company import BASE
    hid = new_player("qcap")[0]
    now = econ.utcnow().replace(hour=12)
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_state(hid, campus_level, campus_lat, campus_lng) VALUES(?,1,?,?) "
                     "ON CONFLICT(hid) DO UPDATE SET campus_level=1", (hid, BASE[0], BASE[1]))
        conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, item, quality, built_at, lease_until) "
                     "VALUES(?,1,1,'farm','wheat',50,?,?)", (hid, now.isoformat(), (now + datetime.timedelta(days=60)).isoformat()))
        assert quests.renewable(conn, hid, now) == 1
        assert quests.fit_target(conn, hid, "renew", 3, now) == 1
        assert quests.fit_target(conn, hid, "educate", 2, now) == 1          # one queue slot at Campus 1
        conn.rollback()


def test_deleting_an_account_keeps_the_other_side_of_trades_and_drops_its_id():
    from systems import account
    a = new_player("qdel")[0]
    b = new_player("qkeep")[0]
    with main.get_db() as conn:
        conn.execute("INSERT INTO market_trades(ts, kind, item, qty, price, buyer_hid, seller_hid, tax) "
                     "VALUES('2026-01-01','player','wood',1,1,?,?,0)", (a, b))
        conn.execute("INSERT INTO reports(ts, reporter_hid, target_hid, kind, reason) VALUES('2026-01-01',?,?,'player','x')", (a, b))
        conn.commit()
        with econ.tx(conn):
            account.purge(conn, a)
        assert conn.execute("SELECT buyer_hid FROM market_trades WHERE seller_hid=?", (b,)).fetchone()[0] is None
        assert not conn.execute("SELECT 1 FROM reports WHERE reporter_hid=?", (a,)).fetchone()


def test_the_country_comes_from_cloudflare():
    from helpers import client
    hid, sid, _ = new_player("qcf")

    def country():
        with main.get_db() as conn:
            return conn.execute("SELECT country_code FROM players WHERE hID=?", (hid,)).fetchone()[0]

    assert client.post("/api/v3/me", data={"sid": sid}, headers={"CF-IPCountry": "CA"}).status_code == 200
    assert country() == "ca"
    client.post("/api/v3/me", data={"sid": sid}, headers={"CF-IPCountry": "XX"})      # unknown keeps it
    client.post("/api/v3/me", data={"sid": sid}, headers={"CF-IPCountry": "T1"})      # Tor keeps it
    client.post("/api/v3/me", data={"sid": sid})                                      # no header keeps it
    assert country() == "ca"
    client.post("/api/v3/me", data={"sid": sid}, headers={"CF-IPCountry": "HR"})
    assert country() == "hr"


def test_a_campus_with_no_country_still_gets_a_pin():
    sid = new_player("qpin")[1]
    a, b = new_player("qpina")[0], new_player("qpinb")[0]
    with main.get_db() as conn:
        for hid, lvl, lat in ((a, 5, 53.5), (b, 3, 53.6)):
            conn.execute("INSERT INTO co_state(hid, campus_level, campus_lat, campus_lng) VALUES(?,?,?,-113.7) "
                         "ON CONFLICT(hid) DO UPDATE SET campus_level=excluded.campus_level, "
                         "campus_lat=excluded.campus_lat, campus_lng=excluded.campus_lng", (hid, lvl, lat))
            conn.execute("UPDATE players SET country_code=NULL WHERE hID=?", (hid,))
        conn.commit()
    here = [c for c in call("/api/v3/campuses/top", sid)["campuses"] if abs(c["lng"] + 113.7) < 0.01]
    assert [c["level"] for c in here] == [5]                    # the biggest of its square


def test_concurrent_claims_pay_once():
    hid, sid, _ = new_player("qd", credits=0, level=1)
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_state(hid, campus_level) VALUES(?,1) ON CONFLICT(hid) DO UPDATE SET campus_level=1", (hid,))
        conn.commit()
    _force_quests(hid, ["plant", "survey", "trade"])
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


def test_variable_targets_and_reward_plan():
    t = {quests.target_of("build_hexes", f"h{i}", "2026-01-01") for i in range(200)}
    assert min(t) >= 2 and max(t) <= 5 and len(t) > 2
    hid, sid, _ = new_player("qtu")
    codes = {q["code"] for q in call(Q, sid)["quests"]}
    assert codes <= set(quests.POOL)
    r = call(Q, sid)
    assert r["reward"]["credits"] == quests.quest_credits(1) and "endsAt" in r and "rewardPlan" not in r


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


Q_PATH = "/api/v1/quests"


def test_no_renew_quest_without_a_hex_to_renew():
    from systems import quests as Q
    import econ
    hid = new_player("NoHex")[0]
    with main.get_db() as conn:
        for d in range(40):
            day = econ.utcnow() + datetime.timedelta(days=d)
            assert "renew" not in Q.available(conn, hid, day)
            Q.assign_today(conn, hid, day)
        assert not conn.execute("SELECT 1 FROM daily_quests WHERE hid=? AND code='renew'", (hid,)).fetchone()
        conn.rollback()


def test_a_stuck_renew_quest_becomes_another_quest():
    from systems import quests as Q
    import econ
    hid = new_player("Stuck")[0]
    now = econ.utcnow()
    day = Q._day(now)
    with main.get_db() as conn:
        Q.assign_today(conn, hid, now)
        conn.execute("UPDATE daily_quests SET code='renew' WHERE id=(SELECT MIN(id) FROM daily_quests WHERE hid=? AND day=?)",
                     (hid, day))
        Q.assign_today(conn, hid, now)
        codes = [r[0] for r in conn.execute("SELECT code FROM daily_quests WHERE hid=? AND day=?", (hid, day))]
        assert "renew" not in codes and len(set(codes)) == Q.DAILY_COUNT
        conn.rollback()


def test_renew_quest_needs_a_lease_that_can_be_renewed_today():
    from systems import quests as Q
    hid, sid = new_player("HasHex")[:2]
    now = econ.utcnow().replace(hour=12)
    far = (now + datetime.timedelta(days=89, hours=23)).isoformat()         # renewed a moment ago
    old = (now + datetime.timedelta(days=60)).isoformat()                   # renewable for a long time
    with main.get_db() as conn:
        conn.execute("INSERT INTO co_state(hid, campus_level) VALUES(?,1) ON CONFLICT(hid) DO UPDATE SET campus_level=1", (hid,))
        conn.execute("INSERT INTO co_hexes(hid, lat, lng, op, item, quality, built_at, lease_until) "
                     "VALUES(?,1,1,'farm','wheat',50,?,?)", (hid, now.isoformat(), old))
        assert "renew" in Q.available(conn, hid, now)
        conn.execute("UPDATE co_hexes SET lease_until=? WHERE hid=?", (far, hid))
        assert Q.renewable(conn, hid, now) == 0 and "renew" not in Q.available(conn, hid, now)
        conn.rollback()
    assert "err" in call(Q_PATH, sid)                                       # the quest list itself answers


def test_company_names_real_letters_only():
    import names
    for ok in ("Rough Diamonds", "Šibenik Rudnici", "Čelik d.o.o.", "Москва", "北京矿业", "東京鉱業株式", "한국광업", "Abc" + "d" * 22):
        assert names.name_problem(ok) is None, ok
    for bad in ("\ufdfd\ufdfd\ufdfd", "\U0001242b ab", "\U00012219 ab", "\u2e3b ab", "\ua9c5 ab", "abc \U0001f600", "ab\u202e", "ＡＢＣ",
                "ab", "a" * 26, "Z\u0351\u036b\u0343\u036a alg"):
        assert names.name_problem(bad), repr(bad)
    assert names.name_problem("Rоugh Diamonds") == "Use one alphabet in your company name"   # a Cyrillic o


def test_every_day_has_one_quick_quest():
    """Owner 2026-11-06: one of the day's quests is always quick (renew 1, trade 1 or the Campus visit)."""
    for i in range(12):
        hid, sid, _ = new_player(f"qeasy{i}")
        qs = call(Q, sid)["quests"]
        quick = [q for q in qs if q["code"] in quests.EASY and q["target"] == 1]
        assert len(qs) == quests.DAILY_COUNT and quick, qs


def test_quests_pay_on_their_own_and_have_no_streak():
    """Owner 2026-11-06: quests are a side hustle; the only streak is the daily reward's."""
    hid, sid, _ = new_player("qside")
    _force_quests(hid, ["survey", "trade", "visit"])
    _events(hid, "survey", 3)
    q = next(x for x in call(Q, sid)["quests"] if x["code"] == "survey")
    before = credits(hid)
    r = call(Q + "/claim", sid, id=q["id"])
    assert r["err"] == 0 and r["milestones"] == [] and credits(hid) == before + r["credits"]
    assert call(Q, sid)["streak"] == 0                       # claiming quests doesn't start a streak


def test_new_quest_kinds_count_their_actions():
    hid, sid, _ = new_player("qnew")
    _force_quests(hid, ["appoint", "buy_order", "explore"])
    for t in ("supervisor_appointed", "market_order", "survey_far"):
        _events(hid, t, 3)
    assert all(q["claimable"] for q in call(Q, sid)["quests"])
