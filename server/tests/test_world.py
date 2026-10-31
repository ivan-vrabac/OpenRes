"""OpenRes 0.3 world map: deterministic, sensible land shares, rarer tiers cover less, items only on
their own land, fast enough for survey pictures."""
import time

import numpy as np

import world as w

rng = np.random.default_rng(7)
LAT = 45.8 + rng.uniform(-0.5, 0.5, 20_000)
LNG = 15.97 + rng.uniform(-0.7, 0.7, 20_000)


def test_same_point_same_answer():
    assert w.at(45.8131, 15.9775) == w.at(45.8131, 15.9775)
    assert w.at(-33.86, 151.21)["land"] in w.LAND_CODES          # works anywhere, also south/east


def test_land_shares():
    lc = w.land_code(LAT, LNG)
    shares = {k: float((lc == c).mean()) for k, c in w.LAND_CODES.items()}
    assert 0.12 < shares["mineral"] < 0.25 and 0.2 < shares["forest"] < 0.4
    assert 0.2 < shares["farmland"] < 0.4 and 0.12 < shares["pasture"] < 0.3


def test_rarer_tiers_cover_less_and_fields_are_smooth():
    cover = {it: float((w.quality(it, LAT, LNG) > 0).mean()) for it in ("stone", "iron_ore", "gold_ore", "uranium_ore", "coltan")}
    assert cover["stone"] > cover["iron_ore"] > cover["gold_ore"] > cover["uranium_ore"] > cover["coltan"] > 0
    # like 1.2.3: neighbouring 4 m pixels differ only a little (no hard edges)
    v, *_ = w.survey_grid("iron_ore", 45.81, 15.98, 1000)
    d = abs(v[:, 1:].astype(int) - v[:, :-1].astype(int))
    assert d.max() <= 6


def test_survey_picture_is_fast():
    t = time.time()
    v, _lat, _lng, step, n = w.survey_grid("iron_ore", 45.8, 15.97, 5_000)
    assert v.shape == (n, n) and n <= 511 and step > 4 and time.time() - t < 2.0
    v, _lat, _lng, step, n = w.survey_grid("iron_ore", 45.8, 15.97, 1_000)
    assert step == 4 and n == 501
    assert 0 <= int(w.sun(0, 0)) <= 100 and w.sun(0, 0) > w.sun(70, 0)


def test_nothing_on_water_and_farms_anywhere_on_land():
    sea, lake, town = (43.5, 15.5), (45.65, 10.68), (45.81, 15.98)
    assert not w.is_land(*sea) and not w.is_land(*lake) and w.is_land(*town)
    assert w.at(*sea) == {"land": "water", "items": {}, "sun": 0, "wind": 0}
    assert int(w.quality("iron_ore", *sea)) == 0 and int(w.sun(*sea)) == 0
    # crops, animals and fish farms: 50-100 anywhere on land (a gentle heatmap), nothing on water
    for it in ("wheat", "milk", "carp"):
        assert 50 <= int(w.quality(it, *town)) <= 100
    assert int(w.quality("wheat", *lake)) == 0
    import numpy as np
    la, lo = np.meshgrid(np.linspace(45.7, 45.9, 40), np.linspace(15.9, 16.1, 40))
    v = w.quality("wheat", la, lo)
    land = v > 0
    assert v[land].min() >= 50 and v[land].max() <= 100 and v[land].max() - v[land].min() >= 20
