"""OpenRes 0.3 game data stays consistent (prices for everything, no recipe losing money, Campus
materials fit the storage the Campus asks for)."""
import gamedata as g


def test_game_data_is_consistent():
    assert g.check() == []


def test_survey_never_dearer_per_area_for_bigger_radius():
    per_area = [g.survey_tax(r) / (r / 100) ** 2 for r in (100, 300, 1_000, 2_000, 5_000)]
    assert per_area == sorted(per_area, reverse=True)


def test_supervisors_queue_and_efficiency():
    assert g.queue_slots(1) == 1 and g.queue_slots(10) == 2 and g.queue_slots(50) == 6
    assert g.efficiency(6.9) == 1.0 and g.efficiency(7) == 0.9 and g.efficiency(100) == 0.3
    assert g.campus_stage(1) == "Temporary camp" and g.campus_stage(50) == "Corporate campus"
