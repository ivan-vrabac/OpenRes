#!/usr/bin/env python3
"""Server admin commands. Uses the same DB_PATH as the server.

  python admin.py set-password "<company name>" "<new password>"
  python admin.py list-unprotected        accounts without a password (created in legacy mode)
  python admin.py reports                 open player reports (moderation)
  python admin.py ban "<company>" [hours] [reason]       no sign-in at all (no hours = forever)
  python admin.py unban "<company>"

In Docker:  docker compose exec server python admin.py list-unprotected
"""
import os
import sqlite3
import sys

import auth

DB_PATH = os.environ.get("DB_PATH", "/data/game.db")


def main() -> int:
    if len(sys.argv) < 2 or sys.argv[1] not in ("set-password", "list-unprotected", "reports", "ban", "unban"):
        print(__doc__)
        return 2
    conn = sqlite3.connect(DB_PATH)
    auth.init(conn)
    if sys.argv[1] in ("reports", "ban", "unban"):
        return moderation(conn, sys.argv[1], sys.argv[2:])
    if sys.argv[1] == "list-unprotected":
        rows = conn.execute("SELECT p.company_name FROM players p LEFT JOIN player_auth a "
                            "ON a.hid = p.hID WHERE a.hid IS NULL ORDER BY 1").fetchall()
        for (name,) in rows:
            print(name)
        print(f"{len(rows)} account(s) without a password")
        return 0
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    name, password = sys.argv[2].strip().lower(), sys.argv[3]
    problem = auth.password_problem(password)
    if problem:
        print(problem)
        return 1
    row = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (name,)).fetchone()
    if not row:
        print(f"no such company: {name}")
        return 1
    auth.set_password(conn, row[0], password)
    conn.commit()
    print(f"password set for {name}")
    return 0


def moderation(conn, cmd, args) -> int:
    """The moderation page's actions from the command line (the server picks up bans within a minute)."""
    from systems import moderation as M
    conn.row_factory = sqlite3.Row
    if cmd == "reports":
        for r in conn.execute("SELECT r.*, (SELECT company_name FROM players WHERE hID=r.target_hid) AS target, "
                              "(SELECT company_name FROM players WHERE hID=r.reporter_hid) AS reporter "
                              "FROM reports r WHERE status='open' ORDER BY id"):
            print(f"#{r['id']} {r['ts'][:16]} {r['kind']} {r['reason']}: {r['target']} (by {r['reporter']}): "
                  f"{(r['message_text'] or '')[:80]!r}")
        return 0
    if not args:
        print(__doc__)
        return 2
    row = conn.execute("SELECT hID FROM players WHERE lower(company_name)=?", (args[0].strip().lower(),)).fetchone()
    if not row:
        print(f"no such company: {args[0]}")
        return 1
    if cmd == "unban":
        conn.execute("DELETE FROM player_bans WHERE hid=?", (row[0],))
    else:
        hours = args[1] if len(args) > 1 and args[1].replace(".", "").isdigit() else None
        reason = " ".join(args[2:] if hours else args[1:])
        M.set_ban(conn, row[0], "full", hours, reason)
    conn.commit()
    print(f"{cmd}: {args[0]} done")
    return 0


if __name__ == "__main__":
    sys.exit(main())
