#!/usr/bin/env python3
"""The fresh world for the 0.2.3 launch: every company starts again from nothing, accounts stay.

Kept: accounts and sign-in (players' names, ids and countries, auth, Google identities, public ids),
legal acceptance, bans, reports, contact messages, devices, notification settings and tokens,
server secrets. Everything else -- hexes, Campus, stock, plants, market, quests, news, achievements,
the old 1.2.3 game -- is emptied, and credits, XP and level go back to the start (a company gets
its start credits the first time it opens the game).

The 1.2.3 tables nothing uses any more are dropped.

A backup of the whole database is written next to it first (SQLite backup API). Without --yes it
only shows what would be emptied.

    python tools/fresh_world.py /data/game.db          # what would happen
    python tools/fresh_world.py /data/game.db --yes    # backup, then the fresh world
"""
from __future__ import annotations

import datetime
import os
import sqlite3
import sys

KEEP = {
    "players", "player_auth", "auth_identities", "player_public", "legal_acceptance", "player_bans",
    "reports", "contact_messages", "player_devices", "notif_prefs", "notif_kinds", "fcm_tokens",
    "server_secrets", "scheduler", "sqlite_sequence",
}
# the 1.2.3 game: no code reads or makes these any more
OLD = {
    "artifact_levels", "artifact_recoveries", "attacks", "auction_bids", "auctions", "cargo_auto_tries",
    "cargo_crates", "cargo_pickups", "cargo_stock", "casino_dividends", "casino_state", "chat_messages",
    "contacts", "earthquakes", "external_repairs", "factories", "filter_strikes", "hq", "hq_deposits",
    "incident_clock", "incidents", "jackpot", "loans", "luxury_items", "luxury_points", "market_req",
    "mine_defence", "mines", "mkt_orders", "mkt_trades", "news_counters", "news_items", "news_privacy",
    "price_days", "private_messages", "warehouse", "wh_carry",
}


def main(argv) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    path, really = argv[1], "--yes" in argv
    conn = sqlite3.connect(path)
    tables = [r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
    wipe = [(t, conn.execute(f'SELECT COUNT(*) FROM "{t}"').fetchone()[0]) for t in tables if t not in KEEP | OLD]
    drop = [t for t in tables if t in OLD]
    players = conn.execute("SELECT COUNT(*) FROM players").fetchone()[0]
    print(f"{players} companies keep their accounts; emptied: "
          + (", ".join(f"{t} ({n})" for t, n in wipe if n) or "nothing") + f"; {len(drop)} old tables dropped")
    if not really:
        print("Nothing changed (add --yes).")
        return 0
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d_%H%M%S")
    backup = os.path.join(os.path.dirname(os.path.abspath(path)), f"backup_pre_fresh_world_{stamp}.db")
    with sqlite3.connect(backup) as dst:
        conn.backup(dst)
    print(f"backup: {backup}")
    with conn:
        for t, _ in wipe:
            conn.execute(f'DELETE FROM "{t}"')
        for t in drop:
            conn.execute(f'DROP TABLE "{t}"')
        if "edu" in [r[1] for r in conn.execute("PRAGMA table_info(co_hexes)")]:
            conn.execute("ALTER TABLE co_hexes DROP COLUMN edu")
        conn.execute("UPDATE players SET credits=0, xp=0, level=1")
        conn.execute("UPDATE scheduler SET last_run=0 WHERE name='news_cursor'")   # game_events start again
    conn.execute("VACUUM")
    print("fresh world ready")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
