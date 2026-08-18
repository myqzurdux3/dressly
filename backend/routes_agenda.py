import json
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

from auth import get_current_user
from db import get_conn
from routes_outfits import (
    _hydrate as _hydrate_outfit,
    _hydrate_many as _hydrate_outfits_many,
    _mark_clothes_worn,
)

router = APIRouter(prefix="/agenda", tags=["agenda"])


def _hydrate_entries(conn, rows) -> list:
    """Batch-hydrate agenda rows: fetch all referenced outfits at once (instead
    of one-outfit-with-its-own-cloth/model-queries per entry)."""
    if not rows:
        return []
    outfit_ids = [r["outfit_id"] for r in rows if r["outfit_id"] is not None]
    outfit_by_id = {}
    if outfit_ids:
        ph = ",".join("?" * len(outfit_ids))
        o_rows = conn.execute(
            f"SELECT * FROM outfits WHERE id IN ({ph})", outfit_ids
        ).fetchall()
        for o in _hydrate_outfits_many(conn, o_rows):
            outfit_by_id[o["id"]] = o
    out = []
    for r in rows:
        out.append({
            "id": r["id"],
            "day": r["day"],
            "outfit_id": r["outfit_id"],
            "title": r["title"],
            "note": r["note"],
            "worn": bool(r["worn"]),
            "created_at": r["created_at"],
            "outfit": outfit_by_id.get(r["outfit_id"]),
        })
    return out


class AgendaCreate(BaseModel):
    day: str  # 'YYYY-MM-DD'
    outfit_id: Optional[int] = None
    title: str = ""
    note: str = ""


class AgendaWornRequest(BaseModel):
    worn: Optional[bool] = None  # None = mark worn (True)


def _hydrate_entry(conn, row) -> dict:
    outfit = None
    if row["outfit_id"] is not None:
        o = conn.execute(
            "SELECT * FROM outfits WHERE id = ?", (row["outfit_id"],)
        ).fetchone()
        if o is not None:
            outfit = _hydrate_outfit(conn, o)
    return {
        "id": row["id"],
        "day": row["day"],
        "outfit_id": row["outfit_id"],
        "title": row["title"],
        "note": row["note"],
        "worn": bool(row["worn"]),
        "created_at": row["created_at"],
        "outfit": outfit,
    }


@router.get("")
def list_agenda(
    user=Depends(get_current_user),
    start: Optional[str] = None,
    end: Optional[str] = None,
):
    """Planned outfits, oldest day first. Optionally bounded by [start, end]
    (inclusive, 'YYYY-MM-DD')."""
    where = ["user_id = ?"]
    args: list = [user["id"]]
    if start:
        where.append("day >= ?")
        args.append(start)
    if end:
        where.append("day <= ?")
        args.append(end)
    sql = (
        "SELECT * FROM agenda WHERE "
        + " AND ".join(where)
        + " ORDER BY day ASC, id ASC"
    )
    with get_conn() as conn:
        rows = conn.execute(sql, args).fetchall()
        return _hydrate_entries(conn, rows)


@router.post("")
def create_agenda(req: AgendaCreate, user=Depends(get_current_user)):
    from agenda_store import valid_day

    day = (req.day or "").strip()
    if not day:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "A day is required")
    day = valid_day(day)
    with get_conn() as conn:
        if req.outfit_id is not None:
            owned = conn.execute(
                "SELECT 1 FROM outfits WHERE id = ? AND user_id = ?",
                (req.outfit_id, user["id"]),
            ).fetchone()
            if not owned:
                raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        cur = conn.execute(
            "INSERT INTO agenda (user_id, day, outfit_id, title, note) "
            "VALUES (?, ?, ?, ?, ?)",
            (user["id"], day, req.outfit_id, req.title.strip(), req.note.strip()),
        )
        row = conn.execute("SELECT * FROM agenda WHERE id = ?", (cur.lastrowid,)).fetchone()
        return _hydrate_entry(conn, row)


@router.post("/{entry_id}/worn")
def mark_worn(entry_id: int, req: AgendaWornRequest, user=Depends(get_current_user)):
    """Confirm (or un-confirm) that the planned outfit was actually worn. When
    confirming, stamp last_worn_at on the outfit's clothes with the agenda day."""
    worn = True if req.worn is None else bool(req.worn)
    with get_conn() as conn:
        row = conn.execute(
            "SELECT * FROM agenda WHERE id = ? AND user_id = ?", (entry_id, user["id"])
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Agenda entry not found")
        conn.execute("UPDATE agenda SET worn = ? WHERE id = ?", (1 if worn else 0, entry_id))
        marked = 0
        if worn and row["outfit_id"] is not None:
            o = conn.execute(
                "SELECT cloth_ids FROM outfits WHERE id = ? AND user_id = ?",
                (row["outfit_id"], user["id"]),
            ).fetchone()
            if o is not None:
                cloth_ids = json.loads(o["cloth_ids"] or "[]")
                marked = _mark_clothes_worn(conn, cloth_ids, user["id"], row["day"])
        updated = conn.execute("SELECT * FROM agenda WHERE id = ?", (entry_id,)).fetchone()
        out = _hydrate_entry(conn, updated)
    out["clothes_marked"] = marked
    return out


@router.delete("/{entry_id}")
def delete_agenda(entry_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        cur = conn.execute(
            "DELETE FROM agenda WHERE id = ? AND user_id = ?", (entry_id, user["id"])
        )
        if cur.rowcount == 0:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Agenda entry not found")
    return {"ok": True}
