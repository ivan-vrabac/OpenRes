#!/usr/bin/env python3
"""Plays the OpenRes 0.3 economy (server/gamedata.py) for two years, hour by hour, and prints when
a player reaches each milestone. Two profiles: an active player (plays daily, builds 20 hexes a day,
visits the Campus weekly) and a casual one (every other day, 5 hexes, Campus every two weeks).

The model: raw output is sold at system prices; materials (books, bricks, steel, ...) are bought at
system prices + 10 %; factories are upgraded while a level pays back within PAYBACK_DAYS and their
total input stays below the player's own raw output. Spending order each day: new hexes, Campus
level (if affordable), Central Storage (if the Campus needs it), education queue, factories.

    python tools/simulate.py [--days 730] [--seed 1]
"""
from __future__ import annotations

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "server"))
import gamedata as g  # noqa: E402

BUY_MARKUP = 1.10
PAYBACK_DAYS = 30
START_CREDITS = 300_000
# chance that a surveyed area offers a deposit of the best tier you've unlocked (else one lower)
TIER_FIND = {1: 1.0, 2: 0.6, 3: 0.3, 4: 0.15, 5: 0.05}
PROFILES = {
    "active": dict(hexes_per_day=20, play_every=1, visit_every=7, surveys_per_play=2),
    "casual": dict(hexes_per_day=5, play_every=2, visit_every=14, surveys_per_play=1),
}


def fmt(x: float) -> str:
    for unit, div in (("T", 1e12), ("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if abs(x) >= div:
            return f"{x / div:.1f}{unit}"
    return f"{x:.0f}"


class Player:
    def __init__(self, profile: dict, rng: random.Random):
        self.p, self.rng = profile, rng
        self.credits = START_CREDITS
        self.campus = 1
        self.storage = 1
        self.hexes: list[list] = []          # [income/h at its quality, tier, built hour, education step or None]
        self.unassigned_edu = []             # education steps of supervisors without a hex
        self.queue: list[tuple] = []         # running/queued educations: (finish hour, hex index)
        self.factories: dict[str, int] = {}
        self.xp = 0.0
        self.ta_mg = 0.0
        self.dm_level = 0
        self.last_visit = 0
        self.streak = 0
        self.milestones: dict[str, int] = {}
        self.spent = {"hex": 0.0, "lease": 0.0, "campus": 0.0, "storage": 0.0, "education": 0.0,
                      "factory": 0.0, "survey": 0.0}

    # ── helpers ──
    def spend(self, what: str, credits: float) -> None:
        self.credits -= credits
        self.spent[what] += credits
        self.xp += credits * g.XP_PER_CREDIT[what]

    def boost(self, step) -> float:
        return 0.0 if step is None else g.EDUCATION[step][1]

    def supervisors_total(self) -> int:
        return self.campus * g.SUPERVISORS_PER_LEVEL

    def eff(self, hour: int) -> float:
        return g.efficiency((hour - self.last_visit) / 24)

    def dm_bonus(self) -> float:
        return 1 + g.DARK_MATTER_BONUS * self.dm_level

    def raw_income(self, hour: int) -> float:
        return sum(h[0] * (1 + self.boost(h[3])) for h in self.hexes) * self.eff(hour) * self.dm_bonus()

    def factory_profit(self, hour: int) -> float:
        total = 0.0
        for f, lv in self.factories.items():
            if f == "isotope_lab":
                continue
            total += max(g.recipe_profit_per_hour(f, i) for i in range(len(g.FACTORIES[f][3]))) * lv
        return total * self.eff(hour) * self.dm_bonus()

    def factory_input(self) -> float:
        return sum(g.recipe_input_per_hour(f) * lv for f, lv in self.factories.items())

    # ── one hour ──
    def tick(self, hour: int) -> None:
        self.credits += self.raw_income(hour) + self.factory_profit(hour)
        lab = self.factories.get("isotope_lab", 0)
        if lab:
            mg_per_h = g.FACTORIES["isotope_lab"][3][0][1][1] * g.factory_scale("isotope_lab") / 24 * lab * self.eff(hour)
            self.credits -= g.recipe_input_per_hour("isotope_lab") * lab
            self.ta_mg += mg_per_h
            self.milestones.setdefault("first 1 g Ta-180m", hour) if self.ta_mg >= 1000 else None
        # finished educations
        for item in [q for q in self.queue if q[0] <= hour]:
            self.queue.remove(item)

    # ── once a day when playing ──
    def play(self, hour: int, day: int) -> None:
        self.streak += 1
        self.credits += g.streak_reward(self.streak)
        if day % self.p["visit_every"] == 0:
            self.last_visit = hour
        for _ in range(self.p["surveys_per_play"]):
            tax = g.survey_tax(g.survey_max_radius(self.campus))
            if self.credits > tax * 20:
                self.spend("survey", tax)
        self.renew_leases(hour)
        self.build_hexes(hour)              # a real player builds first, then levels the Campus
        self.upgrade_hq(hour)
        self.assign_supervisors()
        self.educate(hour)
        self.upgrade_factories()
        assert self.credits > -1e6, f"credits went negative on day {day}: {self.credits:.0f}"
        self.dark_matter()

    def renew_leases(self, hour: int) -> None:
        for h in self.hexes:
            if hour - h[2] >= g.LEASE_DAYS * 24:
                tier_income = g.TIER_INCOME[h[1]]
                self.spend("lease", tier_income * g.LEASE_HOURS)
                h[2] = hour

    def upgrade_hq(self, hour: int) -> None:
        while self.campus < g.CAMPUS_MAX:
            up = g.campus_upgrade(self.campus)
            if self.storage < up["storage"]:
                cost = g.storage_upgrade_cost(self.storage)
                if self.credits < cost * 2:
                    return
                self.spend("storage", cost)
                self.storage += 1
                continue
            mats = sum(g.PRICES[i] * q for i, q in up["materials"].items()) * BUY_MARKUP
            total = up["credits"] + mats
            if self.credits < total * 1.2:
                return
            self.spend("campus", total)
            self.campus += 1
            self.milestones.setdefault(f"Campus {self.campus}", hour)

    def assign_supervisors(self) -> None:
        """Supervisors go to the best hexes (moving them is free)."""
        steps = [h[3] for h in self.hexes if h[3] is not None] + self.unassigned_edu
        steps += [0] * (self.supervisors_total() - len(steps))
        steps.sort(reverse=True)
        for h in self.hexes:
            h[3] = None
        order = sorted(range(len(self.hexes)), key=lambda i: -self.hexes[i][0])
        for n, i in enumerate(order):
            if n >= len(steps):
                break
            self.hexes[i][3] = steps[n]
        self.unassigned_edu = steps[len(order):]

    def educate(self, hour: int) -> None:
        slots = g.queue_slots(self.campus)
        while len(self.queue) < slots:
            # the supervisor whose next step gains the most per credit
            best, best_ratio = None, 0.0
            busy = {q[1] for q in self.queue}
            for i, h in enumerate(self.hexes):
                if h[3] is None or h[3] >= 4 or i in busy:
                    continue
                _, boost, hours, books, credits = g.EDUCATION[h[3] + 1]
                cost = credits + books * g.PRICES["books"] * BUY_MARKUP
                ratio = h[0] * (boost - self.boost(h[3])) / cost
                if ratio > best_ratio:
                    best, best_ratio = (i, hours, cost), ratio
            if best is None or self.credits < best[2] * 1.5:
                break
            i, hours, cost = best
            self.spend("education", cost)
            self.hexes[i][3] += 1
            start = max([q[0] for q in self.queue] + [hour])
            self.queue.append((start + hours, i))
        maxed = sum(1 for h in self.hexes if h[3] == 4) + sum(1 for s in self.unassigned_edu if s == 4)
        if maxed >= g.CAMPUS_MAX * g.SUPERVISORS_PER_LEVEL:
            self.milestones.setdefault("all 500 supervisors educated", hour)

    def build_hexes(self, hour: int) -> None:
        unlocked = [t for t, lv in g.TIER_UNLOCK.items() if self.campus >= lv]
        for _ in range(self.p["hexes_per_day"] * self.p["play_every"]):
            if len(self.hexes) >= g.MAX_HEXES:
                self.milestones.setdefault("10,000 hexes", hour)
                return
            tier = 1
            for t in sorted(unlocked, reverse=True):
                if self.rng.random() < TIER_FIND[t]:
                    tier = t
                    break
            cost = g.TIER_INCOME[tier] * g.HEX_BUILD_HOURS
            if self.credits < cost * 1.5:
                return
            quality = self.rng.uniform(0.5, 0.95)
            self.spend("hex", cost)
            self.hexes.append([g.TIER_INCOME[tier] * quality, tier, hour, None])

    def upgrade_factories(self) -> None:
        raw_value = sum(h[0] for h in self.hexes)
        while True:
            best = None
            for f, (_, unlock, _, recipes) in g.FACTORIES.items():
                if self.campus < unlock or f == "isotope_lab":
                    continue
                lv = self.factories.get(f, 0)
                profit = max(g.recipe_profit_per_hour(f, i) for i in range(len(recipes)))
                cost = g.factory_upgrade_cost(f, lv)
                payback_h = cost / profit
                if payback_h <= PAYBACK_DAYS * 24 and (best is None or payback_h < best[2]):
                    best = (f, cost, payback_h)
            if best is None or self.credits < best[1] * 2:
                break
            if self.factory_input() + g.recipe_input_per_hour(best[0]) > raw_value:
                break
            self.spend("factory", best[1])
            self.factories[best[0]] = self.factories.get(best[0], 0) + 1
        # the isotope lab: build and grow it once supercomputers exist
        if self.campus >= g.FACTORIES["isotope_lab"][1]:
            lv = self.factories.get("isotope_lab", 0)
            cost = g.factory_upgrade_cost("isotope_lab", lv)
            if self.credits > cost * 3 and self.raw_income(0) > g.recipe_input_per_hour("isotope_lab") * (lv + 1) * 3:
                self.spend("factory", cost)
                self.factories["isotope_lab"] = lv + 1

    def dark_matter(self) -> None:
        if "all 500 supervisors educated" not in self.milestones:
            return
        while self.ta_mg >= g.dark_matter_cost_mg(self.dm_level + 1):
            mg = g.dark_matter_cost_mg(self.dm_level + 1)
            self.ta_mg -= mg
            self.xp += mg * g.ta180m_value_mg()
            self.dm_level += 1


def run(profile_name: str, days: int, seed: int) -> Player:
    rng = random.Random(seed)
    pl = Player(PROFILES[profile_name], rng)
    for day in range(days):
        for h in range(24):
            hour = day * 24 + h
            pl.tick(hour)
        if day % pl.p["play_every"] == 0:
            pl.play(day * 24 + 23, day)
        if day in (6, 29, 89, 179, 364, 729):
            pl.milestones[f"day {day + 1}: Campus {pl.campus}, {len(pl.hexes)} hexes, "
                          f"{fmt(pl.raw_income(day * 24) + pl.factory_profit(day * 24))}/h, "
                          f"{fmt(pl.credits)} credits"] = day * 24
    return pl


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=730)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    for name in PROFILES:
        pl = run(name, a.days, a.seed)
        print(f"\n== {name} player ({a.days} days) ==")
        for k, hour in sorted(pl.milestones.items(), key=lambda kv: kv[1]):
            print(f"  day {hour / 24:6.1f}  {k}")
        maxed = sum(1 for h in pl.hexes if h[3] == 4) + sum(1 for s in pl.unassigned_edu if s == 4)
        print(f"  end: Campus {pl.campus}, storage {pl.storage}, {len(pl.hexes)} hexes, supervisors "
              f"{pl.supervisors_total()} ({maxed} maxed), factories {sum(pl.factories.values())} levels, "
              f"Ta-180m {pl.ta_mg:.0f} mg, dark matter level {pl.dm_level}, XP {fmt(pl.xp)}")
        print("  spent: " + ", ".join(f"{k} {fmt(v)}" for k, v in pl.spent.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
