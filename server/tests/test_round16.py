"""Round 16 (owner 2026-10-24): free repair in the boss range, booster limited to its 8 hours,
quest credits that follow the level, artifact prices in billions."""
import datetime

import main
from helpers import credits
from systems import quests

def test_quest_credits_follow_the_campus_level():
    import gamedata as g
    assert quests.quest_credits(30) > quests.quest_credits(10) > quests.quest_credits(1) == quests.QUEST_MIN_CREDITS
    assert quests.quest_credits(20) == round(g.campus_upgrade(20)["credits"] * quests.QUEST_CAMPUS_SHARE, -2)
    assert quests.quest_credits(50) == quests.quest_credits(49)          # no level after the last


def test_quest_reward_grows_every_level_without_jumps():
    r = [quests.quest_credits(lv) for lv in range(1, 16)]
    assert r[0] == quests.QUEST_MIN_CREDITS
    assert all(b > a for a, b in zip(r, r[1:]))                          # never flat
    assert max(b / a for a, b in zip(r, r[1:])) < 1.3                    # never a big jump
