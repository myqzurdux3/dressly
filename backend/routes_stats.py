"""Aggregated per-user stats for the Profile screen: counts, wear coverage,
the most-worn outfit, and the most-worn clothes."""
from fastapi import APIRouter, Depends

from auth import get_current_user
from db import get_conn
from images import public_url_for

router = APIRouter(prefix="/stats", tags=["stats"])


def _cloth_thumb(conn, cloth_id: int) -> str:
    img = conn.execute(
        "SELECT cutout_path, original_path, bg_accepted FROM cloth_images "
        "WHERE cloth_id = ? "
        "ORDER BY CASE role WHEN 'front' THEN 0 ELSE 1 END, sort_order, id LIMIT 1",
        (cloth_id,),
    ).fetchone()
    if not img:
        return ""
    path = (img["original_path"] if img["bg_accepted"] == "rejected"
            else (img["cutout_path"] or img["original_path"]))
    return public_url_for(path)


@router.get("/me")
def my_stats(user=Depends(get_current_user)):
    uid = user["id"]
    with get_conn() as conn:
        def scalar(sql, args=(uid,)):
            return conn.execute(sql, args).fetchone()["n"]

        clothes_count = scalar("SELECT COUNT(*) n FROM clothes WHERE user_id = ?")
        clothes_worn = scalar(
            "SELECT COUNT(*) n FROM clothes WHERE user_id = ? AND last_worn_at IS NOT NULL")
        # Lifetime generations (never decreases on delete) vs current history.
        outfits_generated = scalar(
            "SELECT outfits_generated n FROM users WHERE id = ?")
        outfits_count = scalar(
            "SELECT COUNT(*) n FROM outfits WHERE user_id = ? "
            "AND NOT (view = 'back' AND linked_id IS NOT NULL)")
        favorites_count = scalar(
            "SELECT COUNT(*) n FROM outfits WHERE user_id = ? AND is_favorite = 1")
        outfit_wears_total = scalar(
            "SELECT COUNT(*) n FROM agenda WHERE user_id = ? AND worn = 1")
        cloth_wears_total = scalar(
            "SELECT COUNT(*) n FROM cloth_wears WHERE user_id = ?")

        # Most-worn outfit (by confirmed agenda entries).
        row = conn.execute(
            "SELECT outfit_id, COUNT(*) n FROM agenda "
            "WHERE user_id = ? AND worn = 1 AND outfit_id IS NOT NULL "
            "GROUP BY outfit_id ORDER BY n DESC LIMIT 1",
            (uid,),
        ).fetchone()
        most_worn_outfit = None
        if row and row["outfit_id"]:
            orow = conn.execute(
                "SELECT * FROM outfits WHERE id = ? AND user_id = ?",
                (row["outfit_id"], uid),
            ).fetchone()
            if orow:
                from routes_outfits import _hydrate
                most_worn_outfit = {
                    "outfit": _hydrate(conn, orow),
                    "times_worn": row["n"],
                }

        # Most-worn clothes.
        top = conn.execute(
            "SELECT c.id, c.name, c.brand, COUNT(cw.id) n FROM clothes c "
            "JOIN cloth_wears cw ON cw.cloth_id = c.id "
            "WHERE c.user_id = ? GROUP BY c.id "
            "ORDER BY n DESC, c.name COLLATE NOCASE ASC LIMIT 5",
            (uid,),
        ).fetchall()
        top_clothes = [{
            "id": t["id"], "name": t["name"], "brand": t["brand"] or "",
            "times_worn": t["n"], "thumb_url": _cloth_thumb(conn, t["id"]),
        } for t in top]

    pct = round(100 * clothes_worn / clothes_count) if clothes_count else 0
    return {
        "clothes_count": clothes_count,
        "clothes_worn_count": clothes_worn,
        "clothes_worn_pct": pct,
        "outfits_generated": outfits_generated,
        "outfits_count": outfits_count,
        "favorites_count": favorites_count,
        "outfit_wears_total": outfit_wears_total,
        "cloth_wears_total": cloth_wears_total,
        "most_worn_outfit": most_worn_outfit,
        "top_clothes": top_clothes,
    }
