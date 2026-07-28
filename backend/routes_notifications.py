from fastapi import APIRouter, Depends

from auth import require_admin
from db import get_conn
from images import public_url_for

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.get("")
def list_notifications(user=Depends(require_admin)):
    """All unresolved background-removal reports, newest first. The manager
    uses this to see which clothes need manual re-cutting."""
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT n.id, n.user_id, n.cloth_id, n.image_id, n.message,
                   n.resolved, n.created_at,
                   u.email AS reporter_email, c.name AS cloth_name,
                   ci.role AS image_role, ci.original_path, ci.cutout_path
            FROM notifications n
            JOIN users u ON u.id = n.user_id
            JOIN clothes c ON c.id = n.cloth_id
            JOIN cloth_images ci ON ci.id = n.image_id
            ORDER BY n.resolved ASC, n.created_at DESC
            """
        ).fetchall()
    out = []
    for r in rows:
        out.append(
            {
                "id": r["id"],
                "user_id": r["user_id"],
                "reporter_email": r["reporter_email"],
                "cloth_id": r["cloth_id"],
                "cloth_name": r["cloth_name"],
                "image_id": r["image_id"],
                "image_role": r["image_role"],
                "message": r["message"],
                "resolved": bool(r["resolved"]),
                "created_at": r["created_at"],
                "image_url": public_url_for(r["original_path"]),
            }
        )
    return out


@router.get("/reports")
def list_outfit_reports(user=Depends(require_admin)):
    """User-submitted 'bad/failed generation' reports, unresolved first. These
    were previously stored but had no read endpoint — surfaced here so an admin
    can act on them (the same events are also pushed by e-mail/webhook)."""
    with get_conn() as conn:
        rows = conn.execute(
            """
            SELECT r.id, r.user_id, r.outfit_id, r.tier, r.slug, r.message,
                   r.resolved, r.created_at, u.email AS reporter_email,
                   o.status AS outfit_status
            FROM outfit_reports r
            JOIN users u ON u.id = r.user_id
            LEFT JOIN outfits o ON o.id = r.outfit_id
            ORDER BY r.resolved ASC, r.created_at DESC
            """
        ).fetchall()
    return [dict(r) for r in rows]


@router.get("/audit")
def list_audit(user=Depends(require_admin), limit: int = 200,
               action: str = "", email: str = ""):
    """Recent audit-trail entries (who did what), newest first. Optional filters
    by action prefix and reporter email. Admin only."""
    limit = max(1, min(int(limit), 1000))
    where = []
    args: list = []
    if action:
        where.append("action LIKE ?")
        args.append(f"{action}%")
    if email:
        where.append("email = ?")
        args.append(email)
    sql = "SELECT id, user_id, email, action, detail, ip, created_at FROM audit_log"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += " ORDER BY id DESC LIMIT ?"
    args.append(limit)
    with get_conn() as conn:
        return [dict(r) for r in conn.execute(sql, args).fetchall()]


@router.post("/{notif_id}/resolve")
def resolve(notif_id: int, user=Depends(require_admin)):
    with get_conn() as conn:
        cur = conn.execute(
            "UPDATE notifications SET resolved = 1 WHERE id = ?", (notif_id,)
        )
        if cur.rowcount == 0:
            from fastapi import HTTPException, status

            raise HTTPException(status.HTTP_404_NOT_FOUND, "Notification not found")
    return {"ok": True}