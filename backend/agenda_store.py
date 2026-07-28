"""Small agenda helper shared by the clothes / outfits / agenda routes.

Kept import-free of the route modules so it can be used from any of them
without creating an import cycle.
"""
from typing import Optional


def upsert_worn(conn, user_id: int, day: str, outfit_id: Optional[int] = None,
                title: str = "") -> int:
    """Ensure a *worn* agenda entry exists for (user, day, outfit/title). If a
    matching entry already exists, just flag it worn; otherwise insert one.
    Returns the entry id.

    Wearing a cloth or an outfit is logged here so the agenda doubles as a
    'what I actually wore' history, not only a plan for the future.
    """
    if outfit_id is not None:
        row = conn.execute(
            "SELECT id FROM agenda WHERE user_id = ? AND day = ? AND outfit_id = ?",
            (user_id, day, outfit_id),
        ).fetchone()
    else:
        row = conn.execute(
            "SELECT id FROM agenda WHERE user_id = ? AND day = ? "
            "AND outfit_id IS NULL AND title = ?",
            (user_id, day, title),
        ).fetchone()
    if row:
        conn.execute("UPDATE agenda SET worn = 1 WHERE id = ?", (row["id"],))
        return row["id"]
    cur = conn.execute(
        "INSERT INTO agenda (user_id, day, outfit_id, title, worn) VALUES (?, ?, ?, ?, 1)",
        (user_id, day, outfit_id, title),
    )
    return cur.lastrowid
