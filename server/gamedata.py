"""OpenRes 0.3 game data: items, land, operations, factories, Campus, supervisors, survey, leases.

Everything the economy needs lives here as plain data plus a few formulas. Prices are derived,
never typed in: a raw item's price comes from what its hex should earn per hour; a product's price
from its inputs (plus energy) and the factory's margin. Run tools/simulate.py to see how the
numbers play out over two years.

Items have text keys ("iron_ore", "books"). Quantities are whole units, except electricity
(stored in Wh, recipes written in kWh) and Tantalum-180m (milligrams).
"""
from __future__ import annotations


# ── Raw items: where they come from and how fast ───────────────────────────────────────────────
# Income tiers: what a hex earns per hour at 100 % quality without a supervisor.
TIER_INCOME = {1: 600, 2: 1_500, 3: 4_000, 4: 10_000, 5: 25_000}
# Campus level that unlocks building hexes of each tier.
TIER_UNLOCK = {1: 1, 2: 5, 3: 15, 4: 25, 5: 35}

LANDS = {
    "mineral": "Mineral deposit",
    "forest": "Forest",
    "farmland": "Farmland",
    "pasture": "Pasture",
    "any": "Any land",
    "water": "Sea, lakes and big rivers",
}

# operation key -> (name, land, {item: (tier, units per hour at 100 %)}, unlock Campus level or None)
OPERATIONS = {
    "mine": ("Mine", "mineral", {
        "stone": (1, 120), "sand": (1, 120), "clay": (1, 100), "limestone": (1, 100), "coal": (1, 80),
        "iron_ore": (2, 60), "copper_ore": (2, 50), "bauxite": (2, 50),
        "gold_ore": (3, 10), "lithium_ore": (3, 20),
        "uranium_ore": (4, 5),
        "coltan": (5, 2),
    }, None),
    "oil_well": ("Oil well", "mineral", {"crude_oil": (2, 40)}, None),
    "logging_camp": ("Logging camp", "forest", {"wood": (1, 100)}, None),
    # farms, ranches and fish farms go anywhere on land, always at full quality (owner 2026-10-26:
    # "livestock/agriculture does not care about heatmaps")
    "farm": ("Farm", "any", {
        "wheat": (1, 150), "potatoes": (1, 150), "corn": (1, 150), "tomatoes": (1, 120),
        "sugar_beet": (1, 120), "apples": (2, 100), "grapes": (2, 80), "cotton": (2, 80),
    }, None),
    "ranch": ("Ranch", "any", {
        "milk": (1, 100), "eggs": (1, 120), "wool": (2, 40), "honey": (2, 30),
        "beef": (2, 30), "pork": (2, 40), "chicken_meat": (2, 50),
    }, None),
    "fish_farm": ("Fish farm", "any", {"carp": (2, 40), "trout": (2, 30)}, None),
    "fishing_port": ("Fishing port", "water", {"sardines": (2, 60), "cod": (3, 30), "tuna": (3, 20)}, None),
    "solar_farm": ("Solar farm", "any", {"electricity": (2, None)}, None),
    "wind_farm": ("Wind farm", "any", {"electricity": (2, None)}, None),
}

ITEM_NAMES = {
    "stone": "Stone", "sand": "Sand", "clay": "Clay", "limestone": "Limestone", "coal": "Coal",
    "iron_ore": "Iron ore", "copper_ore": "Copper ore", "bauxite": "Bauxite", "gold_ore": "Gold ore",
    "lithium_ore": "Lithium ore", "uranium_ore": "Uranium ore", "coltan": "Coltan", "crude_oil": "Crude oil",
    "wood": "Wood", "wheat": "Wheat", "potatoes": "Potatoes", "corn": "Corn", "tomatoes": "Tomatoes",
    "sugar_beet": "Sugar beet", "apples": "Apples", "grapes": "Grapes", "cotton": "Cotton",
    "milk": "Milk", "eggs": "Eggs", "wool": "Wool", "honey": "Honey", "beef": "Beef", "pork": "Pork",
    "chicken_meat": "Chicken meat", "carp": "Carp", "trout": "Trout", "sardines": "Sardines", "cod": "Cod",
    "tuna": "Tuna", "electricity": "Electricity",
    "lumber": "Lumber", "wood_pellets": "Wood pellets", "paper": "Paper", "books": "Books",
    "furniture": "Furniture", "bricks": "Bricks", "cement": "Cement", "concrete": "Concrete", "glass": "Glass",
    "steel": "Steel", "aluminium": "Aluminium", "copper_wire": "Copper wire", "plastics": "Plastics",
    "flour": "Flour", "sugar": "Sugar", "dairy_products": "Dairy products", "meat_products": "Meat products",
    "fish_products": "Fish products", "grocery_packs": "Grocery packs", "juice": "Juice", "meals": "Meals",
    "fabric": "Fabric", "clothing": "Clothing", "sweets": "Sweets", "fuel_rods": "Fuel rods",
    "silicon": "Silicon", "wafers": "Wafers", "microchips": "Microchips", "batteries": "Batteries",
    "phones": "Phones", "laptops": "Laptops", "computers": "Computers", "servers": "Servers",
    "supercomputers": "Supercomputers", "medical_devices": "Medical devices", "tantalum": "Tantalum",
    "ta180m": "Tantalum-180m",
}
UNTRADABLE = {"ta180m"}                 # strategic: produced, never sold
ENERGY = "electricity"                  # stored in Wh; recipes below say kWh

# ── Factories (inside the Campus) ──────────────────────────────────────────────────────────────────
# key -> (name, unlock Campus level, margin, [recipes]); recipe = (inputs, (output, qty), hours, kWh)
# A level-L factory runs L batches in parallel. The first recipe of a product sets its price.
FACTORIES = {
    # energy
    "coal_power": ("Coal power plant", 2, 0.20, [({"coal": 10}, (ENERGY, 25), 1, 0)]),
    "pellet_power": ("Pellet power plant", 4, 0.20, [({"wood_pellets": 10}, (ENERGY, 30), 1, 0)]),
    "uranium_enrichment": ("Uranium enrichment", 26, 0.35, [({"uranium_ore": 2}, ("fuel_rods", 1), 4, 500)]),
    "nuclear_power": ("Nuclear power plant", 28, 0.25, [({"fuel_rods": 1}, (ENERGY, 3_000), 4, 0)]),
    # wood
    "sawmill": ("Sawmill", 1, 0.30, [({"wood": 10}, ("lumber", 8), 1, 5)]),
    "pellet_plant": ("Pellet plant", 3, 0.25, [({"wood": 10}, ("wood_pellets", 10), 1, 2)]),
    "paper_mill": ("Paper mill", 4, 0.35, [({"wood": 20}, ("paper", 10), 1, 20)]),
    "printing_house": ("Printing house", 5, 0.40, [({"paper": 10}, ("books", 2), 1, 5)]),
    "furniture_factory": ("Furniture factory", 12, 0.45, [({"lumber": 10, "steel": 2}, ("furniture", 2), 2, 10)]),
    # construction
    "brick_works": ("Brick works", 2, 0.30, [({"clay": 20, "coal": 2}, ("bricks", 20), 1, 10)]),
    "cement_plant": ("Cement plant", 6, 0.30, [({"limestone": 20, "coal": 5}, ("cement", 15), 1, 30)]),
    "concrete_plant": ("Concrete plant", 8, 0.30, [({"cement": 5, "sand": 10, "stone": 10}, ("concrete", 20), 1, 10)]),
    "glass_works": ("Glass works", 7, 0.35, [({"sand": 20, "coal": 3}, ("glass", 10), 1, 40)]),
    "steel_works": ("Steel works", 9, 0.35, [({"iron_ore": 10, "coal": 5}, ("steel", 5), 1, 50)]),
    "aluminium_smelter": ("Aluminium smelter", 14, 0.40, [({"bauxite": 10}, ("aluminium", 4), 2, 200)]),
    "wire_mill": ("Wire mill", 11, 0.35, [({"copper_ore": 10}, ("copper_wire", 8), 1, 30)]),
    "plastics_plant": ("Plastics plant", 13, 0.40, [({"crude_oil": 10}, ("plastics", 8), 1, 40)]),
    # food
    "flour_mill": ("Flour mill", 3, 0.30, [({"wheat": 20}, ("flour", 15), 1, 5)]),
    "sugar_refinery": ("Sugar refinery", 6, 0.30, [({"sugar_beet": 20}, ("sugar", 5), 1, 10)]),
    "food_processing": ("Food processing plant", 5, 0.35, [
        ({"milk": 20}, ("dairy_products", 10), 1, 5),
        ({"beef": 10}, ("meat_products", 10), 1, 10),
        ({"pork": 12}, ("meat_products", 10), 1, 10),
        ({"chicken_meat": 15}, ("meat_products", 10), 1, 10),
        ({"carp": 10}, ("fish_products", 8), 1, 5),
        ({"trout": 8}, ("fish_products", 8), 1, 5),
    ]),
    "grocery_packing": ("Grocery packing", 8, 0.35, [({"potatoes": 10, "tomatoes": 10, "apples": 5}, ("grocery_packs", 5), 1, 5)]),
    "juice_plant": ("Juice plant", 9, 0.35, [({"apples": 10}, ("juice", 8), 1, 10), ({"grapes": 10}, ("juice", 8), 1, 10)]),
    "textile_mill": ("Textile mill", 10, 0.35, [({"cotton": 10}, ("fabric", 8), 1, 20), ({"wool": 5}, ("fabric", 8), 1, 20)]),
    "restaurant_kitchen": ("Restaurant kitchen", 15, 0.50, [({"meat_products": 2, "flour": 4, "tomatoes": 4, "dairy_products": 2}, ("meals", 5), 1, 10)]),
    "clothing_factory": ("Clothing factory", 16, 0.45, [({"fabric": 10}, ("clothing", 4), 2, 20)]),
    "confectionery": ("Confectionery", 18, 0.45, [({"sugar": 5, "flour": 5, "honey": 2, "eggs": 5}, ("sweets", 5), 1, 10)]),
    # electronics
    "silicon_refinery": ("Silicon refinery", 18, 0.40, [({"sand": 20}, ("silicon", 5), 2, 300)]),
    "wafer_fab": ("Wafer fab", 20, 0.45, [({"silicon": 5}, ("wafers", 4), 2, 200)]),
    "battery_plant": ("Battery plant", 20, 0.45, [({"lithium_ore": 5, "aluminium": 2}, ("batteries", 10), 2, 100)]),
    "chip_fab": ("Chip fab", 22, 0.50, [({"wafers": 4, "gold_ore": 1, "copper_wire": 4}, ("microchips", 20), 3, 500)]),
    "electronics_assembly": ("Electronics assembly", 24, 0.45, [
        ({"microchips": 3, "batteries": 1, "glass": 1, "plastics": 1, "aluminium": 1}, ("phones", 1), 1, 5),
        ({"microchips": 6, "batteries": 2, "glass": 2, "plastics": 3, "aluminium": 3}, ("laptops", 1), 2, 10),
        ({"microchips": 8, "plastics": 4, "steel": 4, "copper_wire": 4}, ("computers", 1), 2, 15),
    ]),
    "server_plant": ("Server plant", 30, 0.45, [({"computers": 4, "copper_wire": 10, "steel": 10}, ("servers", 1), 4, 1_000)]),
    "supercomputer_center": ("Supercomputer center", 34, 0.50, [({"servers": 10, "microchips": 100}, ("supercomputers", 1), 12, 20_000)]),
    "medical_lab": ("Medical lab", 38, 0.50, [({"supercomputers": 1, "microchips": 200, "plastics": 200, "steel": 100, "glass": 100}, ("medical_devices", 50), 12, 5_000)]),
    # top tier
    "tantalum_refinery": ("Tantalum refinery", 36, 0.45, [({"coltan": 10}, ("tantalum", 1), 4, 2_000)]),
    "isotope_lab": ("Isotope lab", 40, 0.60, [({"tantalum": 10, "supercomputers": 1}, ("ta180m", 5), 24, 500_000)]),
}

FACTORY_BUILD_HOURS = 24          # a level-1 factory costs about this many hours of its own profit
FACTORY_GROWTH = 1.12             # each further level costs 12 % more
FACTORY_GROWTH_OVERRIDE = {"isotope_lab": 1.40}     # Ta-180m must stay scarce
# Throughput: one factory level processes inputs worth about this much per hour (a level-1
# sawmill handles ~5 forest hexes); factories unlocked later process more.
FACTORY_INPUT_BASE = 3_000
FACTORY_INPUT_GROWTH = 1.12       # per Campus unlock level


# ── Derived prices ─────────────────────────────────────────────────────────────────────────────

def raw_items() -> dict:
    """item -> (operation, tier, units/h) for everything that comes from a hex."""
    out = {}
    for op, (_, _, items, _) in OPERATIONS.items():
        for item, (tier, rate) in items.items():
            if item != ENERGY:
                out.setdefault(item, (op, tier, rate))
    return out


def _derive_prices() -> dict:
    prices = {item: TIER_INCOME[tier] / rate for item, (_, tier, rate) in raw_items().items()}
    # products, in dependency order (a product's first recipe whose inputs are all priced)
    pending = {(f, i): r for f, (_, _, _, recipes) in FACTORIES.items() for i, r in enumerate(recipes)}
    while True:
        progress = False
        for (fkey, i), (inputs, (out, qty), _h, kwh) in list(pending.items()):
            if out in prices and out != ENERGY:
                del pending[(fkey, i)]
                continue
            need = list(inputs) + ([ENERGY] if kwh else [])
            if all(x in prices for x in need):
                cost = sum(prices[x] * q for x, q in inputs.items()) + (prices[ENERGY] * kwh if kwh else 0)
                if out == ENERGY:
                    if ENERGY not in prices:                       # coal power sets the kWh price
                        prices[ENERGY] = cost * (1 + FACTORIES[fkey][2]) / qty
                else:
                    prices[out] = cost * (1 + FACTORIES[fkey][2]) / qty
                del pending[(fkey, i)]
                progress = True
        if not progress:
            break
    return prices


PRICES = _derive_prices()            # credits per unit (electricity: per kWh; ta180m: per mg)


def recipe_cost(recipe) -> float:
    inputs, _out, _h, kwh = recipe
    return sum(PRICES[x] * q for x, q in inputs.items()) + PRICES[ENERGY] * kwh


def factory_scale(fkey: str) -> int:
    """Batches a level-1 factory runs at once (its first recipe sets the size)."""
    recipe = FACTORIES[fkey][3][0]
    target = FACTORY_INPUT_BASE * FACTORY_INPUT_GROWTH ** (FACTORIES[fkey][1] - 1)
    return max(1, round(target / (recipe_cost(recipe) / recipe[2])))


def recipe_profit_per_hour(fkey: str, i: int = 0) -> float:
    """Value added per hour by one level of a factory, at system prices."""
    recipe = FACTORIES[fkey][3][i]
    inputs, (out, qty), hours, kwh = recipe
    value = PRICES[out] * qty
    return (value - recipe_cost(recipe)) / hours * factory_scale(fkey)


def recipe_input_per_hour(fkey: str, i: int = 0) -> float:
    """Credits' worth of inputs (and energy) one factory level uses per hour."""
    recipe = FACTORIES[fkey][3][i]
    return recipe_cost(recipe) / recipe[2] * factory_scale(fkey)


def factory_upgrade_cost(fkey: str, level: int) -> int:
    """Credits to go from `level` to level + 1 (level 0 = building it)."""
    base = max(recipe_profit_per_hour(fkey, i) for i in range(len(FACTORIES[fkey][3]))) * FACTORY_BUILD_HOURS
    return int(round(base * FACTORY_GROWTH_OVERRIDE.get(fkey, FACTORY_GROWTH) ** level, -2))


# ── Hexes: build and lease ─────────────────────────────────────────────────────────────────────
HEX_BUILD_HOURS = 96               # a hex costs 4 days of its own output (at 100 % quality)
LEASE_DAYS = 90                    # the most a lease can run; renewing sets it back to 90 days
LEASE_HOURS = 24                   # a full renewal costs one day of the hex's output
LEASE_FULL_PRICE_DAYS = 30         # the renewal price grows with the days used, full from 30 on:
                                   # renewing late gives more days for the same price (owner 2026-10-26)


LEASE_RENEW_MIN_HOURS = 24         # a lease can be renewed only a day after the last renewal
LEASE_CRITICAL_DAYS = 30           # the map shows the countdown only in the last 30 days
LEASE_CANCEL_REFUND = 0.30         # cancelling returns 30 % of the value of the days left
LEASE_BULK_CANCEL_S = 5            # "cancel all": at most one bulk cancel every 5 s


def lease_renew_factor(days_left: float) -> float:
    """Share of the full renewal price, from the days left on the lease."""
    used = max(0.0, LEASE_DAYS - days_left)
    return min(used, LEASE_FULL_PRICE_DAYS) / LEASE_FULL_PRICE_DAYS
MAX_HEXES = 10_000
SOLAR_KWH_PER_HOUR = TIER_INCOME[2] / PRICES[ENERGY] * 0.8      # a bit below a tier-2 hex
WIND_KWH_PER_HOUR = TIER_INCOME[2] / PRICES[ENERGY] * 0.9


def hex_income(item: str) -> float:
    """Credits per hour of a hex at 100 % quality without a supervisor."""
    if item == ENERGY:
        return TIER_INCOME[2]
    return TIER_INCOME[raw_items()[item][1]]


def hex_build_cost(item: str) -> int:
    return int(round(hex_income(item) * HEX_BUILD_HOURS, -2))


def lease_cost(item: str) -> int:
    return int(round(hex_income(item) * LEASE_HOURS, -2))


# ── Supervisors and education ──────────────────────────────────────────────────────────────────
SUPERVISORS_PER_LEVEL = 10
# step -> (name, output boost, hours, books, credits)
EDUCATION = {
    0: ("Untrained", 0.25, 0, 0, 0),
    1: ("Course", 0.50, 0.5, 10, 20_000),
    2: ("Diploma", 1.00, 3, 50, 200_000),
    3: ("Degree", 1.50, 6, 200, 2_000_000),
    4: ("Master's", 2.00, 12, 1_000, 20_000_000),
}
QUEUE_UNLOCKS = (10, 20, 30, 40, 50)         # one more education queue slot at each of these levels


def queue_slots(campus_level: int) -> int:
    return 1 + sum(1 for lv in QUEUE_UNLOCKS if campus_level >= lv)


# ── Campus: 50 levels in 5 stages ────────────────────────────────────────────────────
CAMPUS_MAX = 50
# what the campus looks like at each stage (tools/draw_campus.py draws every level)
CAMPUS_STAGES = [(1, "Temporary camp"), (6, "Small business premises"), (16, "Industrial yard"),
                 (26, "Industrial park"), (39, "Corporate campus")]
CAMPUS_BASE = 1_500_000
CAMPUS_GROWTH = 1.24
# materials by level bracket: share of the level's credit cost paid in these goods (by value)
CAMPUS_MATERIALS = [
    (1, {"lumber": 0.2, "bricks": 0.2}),
    (11, {"bricks": 0.1, "concrete": 0.2, "glass": 0.1}),
    (21, {"concrete": 0.1, "glass": 0.1, "steel": 0.2}),
    (31, {"steel": 0.15, "aluminium": 0.15, "copper_wire": 0.1}),
    (41, {"steel": 0.1, "microchips": 0.15, "computers": 0.15}),
]


def campus_stage(level: int) -> str:
    """The campus's development stage at `level`."""
    return [name for lv, name in CAMPUS_STAGES if level >= lv][-1]


def campus_upgrade(level: int) -> dict:
    """What it takes to go from `level` to level + 1: credits, materials (units), storage level."""
    # the first levels come quickly (a new player should see the Campus grow in the first days)
    ramp = max(0.02, min(1.0, (level / 10) ** 2))
    credits = CAMPUS_BASE * CAMPUS_GROWTH ** (level - 1) * ramp
    shares = [m for start, m in CAMPUS_MATERIALS if level >= start][-1]
    materials = {item: max(1, int(credits * share / PRICES[item])) for item, share in shares.items()}
    return {"credits": int(round(credits, -3)), "materials": materials, "storage": max(1, level // 2)}


# ── Central Storage ────────────────────────────────────────────────────────────────────────────
# One total for everything (owner 2026-10-31: not a limit per item, scarce items shouldn't leave
# room unused): units of all items together; electricity counts per kWh; Tantalum-180m (mg, tiny) is
# kept apart and never counts.
STORAGE_BASE = 250_000            # units in all at level 1
STORAGE_GROWTH = 1.45
STORAGE_COST_BASE = 50_000
STORAGE_COST_GROWTH = 1.30


def storage_capacity(level: int) -> int:
    return int(STORAGE_BASE * STORAGE_GROWTH ** (level - 1))


def storage_upgrade_cost(level: int) -> int:
    return int(round(STORAGE_COST_BASE * STORAGE_COST_GROWTH ** (level - 1), -3))


# ── Weekly inspection ──────────────────────────────────────────────────────────────────────────
INSPECTION_RANGE_M = 200

# ── Moving the Campus (plan section 3: once a month, 24 h, cancellable; plants pause meanwhile) ──
MOVE_EVERY_DAYS = 30
MOVE_HOURS = 24


def efficiency(days_since_visit: float) -> float:
    """1.0 up to 7 days after the last Campus visit, then -10 % per missed week, never below 30 %."""
    missed = max(0, int(days_since_visit // 7))
    return max(0.30, 1.0 - 0.10 * missed)


# ── Government survey ──────────────────────────────────────────────────────────────────────────
SURVEY_BASE_M = 100
SURVEY_BASE_TAX = 1_000            # for 100 m; bigger surveys cost less per area
SURVEY_EXPONENT = 0.9              # < 1: a big survey is cheaper per area than small ones
SURVEY_RADIUS_STEP = 100             # owner 2026-10-31: 100 m per Campus level (100 m at 1, 5 km at 50)


def survey_tax(radius_m: float) -> int:
    area = (radius_m / SURVEY_BASE_M) ** 2
    return int(round(SURVEY_BASE_TAX * area ** SURVEY_EXPONENT, -2))


def survey_wait_minutes(radius_m: float) -> float:
    """No waiting between surveys, only the tax (owner 2026-10-26)."""
    return 0.0


def survey_max_radius(campus_level: int) -> int:
    return SURVEY_RADIUS_STEP * max(1, campus_level)


# ── Dark matter research ───────────────────────────────────────────────────────────────────────
DARK_MATTER_FIRST_MG = 1_000      # 1 g for level 1
DARK_MATTER_GROWTH = 1.25
DARK_MATTER_BONUS = 0.01          # +1 % output on everything per level


def dark_matter_cost_mg(level: int) -> int:
    """Ta-180m (mg) to reach `level` from level - 1."""
    return int(DARK_MATTER_FIRST_MG * DARK_MATTER_GROWTH ** (level - 1))


# ── Login streak ───────────────────────────────────────────────────────────────────────────────
STREAK_REWARD = [(1, 20_000), (7, 60_000), (14, 150_000), (30, 400_000)]   # day reached -> credits a day
# ... and materials (plan: "credits + materials"): books, which supervisor education needs
STREAK_MATERIALS = [(1, {"books": 10}), (7, {"books": 50}), (14, {"books": 150}), (30, {"books": 500})]


def streak_reward(day: int) -> int:
    return [c for d, c in STREAK_REWARD if day >= d][-1]


def streak_materials(day: int) -> dict:
    return [m for d, m in STREAK_MATERIALS if day >= d][-1]


# ── XP: the value of what is permanently consumed ──────────────────────────────────────────────
XP_PER_CREDIT = {"campus": 1.0, "storage": 1.0, "factory": 1.0, "education": 1.0, "hex": 1.0,
                 "lease": 1.0, "survey": 0.25, "dark_matter": 1.0}


def ta180m_value_mg() -> float:
    """What one mg of Ta-180m costs to make (its 'value' for XP; it has no market price)."""
    inputs, (_out, qty), _h, kwh = FACTORIES["isotope_lab"][3][0]
    return recipe_cost(FACTORIES["isotope_lab"][3][0]) / qty


def check() -> list[str]:
    """Consistency problems (used by tests)."""
    problems = []
    for f, (_, _, _, recipes) in FACTORIES.items():
        for recipe in recipes:
            for x in list(recipe[0]) + [recipe[1][0]]:
                if x not in ITEM_NAMES:
                    problems.append(f"{f}: unknown item {x}")
                elif x not in PRICES:
                    problems.append(f"{f}: no price for {x}")
    for item in ITEM_NAMES:
        if item not in PRICES:
            problems.append(f"{item}: no price")
    for lv in range(1, CAMPUS_MAX):
        up = campus_upgrade(lv)
        cap = storage_capacity(up["storage"])
        need = sum(up["materials"].values())
        if need > cap * 0.5:              # half the storage stays free for everything else
            problems.append(f"Campus {lv}: {need:,} units of materials fill more than half of storage "
                            f"level {up['storage']} ({cap:,})")
    if not problems:
        for f, (_, _, _, recipes) in FACTORIES.items():
            for i in range(len(recipes)):
                p = recipe_profit_per_hour(f, i)
                if p <= 0:
                    problems.append(f"{f} recipe {i} loses money ({p:.0f}/h)")
    return problems
