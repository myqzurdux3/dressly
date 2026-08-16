"""Share one outfit with somebody who has no account.

A link, not a login. What it exposes is deliberately the smallest thing that
still makes sense to send: the render, and the names of the garments in it.
No email, no wardrobe, no other outfit, and nothing at all about the owner.

Three properties the design turns on:

  * revocable — a row, not a signature, because a link you regret sending has
    to be able to stop working;
  * expiring — thirty days by default, so a forgotten link does not stay open
    for years;
  * self-contained — the image is served through the token itself, so the page
    works without the signed-image scheme the app uses for its own requests.
"""
import html
import logging
import secrets
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import FileResponse, HTMLResponse

from auth import get_current_user
from db import get_conn

router = APIRouter(tags=["share"])
log = logging.getLogger(__name__)

SHARE_TTL_DAYS = 30
# Long enough that guessing one is hopeless; the row is the authorisation.
TOKEN_BYTES = 24


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _expiry() -> str:
    return (_now() + timedelta(days=SHARE_TTL_DAYS)).isoformat(timespec="seconds")


def _is_past(stamp: str) -> bool:
    """Has this expiry passed?

    Timestamps reach this table two ways — written here with a UTC offset, or
    set by SQLite's own ``datetime('now', ...)``, which has none. Comparing the
    two forms directly raises, so a naive one is read as UTC, which is what
    SQLite means by 'now'.
    """
    try:
        when = datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return True   # unreadable: treat as dead rather than as open forever
    if when.tzinfo is None:
        when = when.replace(tzinfo=timezone.utc)
    return when <= _now()


def _live_share(conn, outfit_id: int, user_id: int) -> Optional[dict]:
    row = conn.execute(
        "SELECT token, expires_at FROM outfit_shares "
        "WHERE outfit_id = ? AND user_id = ? AND revoked = 0 "
        "ORDER BY created_at DESC LIMIT 1",
        (outfit_id, user_id),
    ).fetchone()
    if not row:
        return None
    if _is_past(row["expires_at"]):
        return None
    return {"token": row["token"], "expires_at": row["expires_at"]}


def _resolve(token: str) -> dict:
    """The outfit behind a token, or 404. Never says which of "unknown",
    "revoked" or "expired" it was: all three are "this link does not work",
    and distinguishing them would confirm that a token once existed."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT s.token, s.expires_at, s.revoked, o.id AS outfit_id, "
            "       o.generated_path, o.cloth_ids "
            "FROM outfit_shares s JOIN outfits o ON o.id = s.outfit_id "
            "WHERE s.token = ?",
            (token,),
        ).fetchone()
        if not row or row["revoked"]:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Link not found")
        if _is_past(row["expires_at"]):
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Link not found")
        import json

        cloth_ids = json.loads(row["cloth_ids"] or "[]")
        names = []
        if cloth_ids:
            ph = ",".join("?" * len(cloth_ids))
            names = [
                {"name": r["name"], "brand": r["brand"] or "",
                 "category": r["category"] or ""}
                for r in conn.execute(
                    f"SELECT name, brand, category FROM clothes WHERE id IN ({ph})",
                    cloth_ids,
                ).fetchall()
            ]
        return {
            "outfit_id": row["outfit_id"],
            "generated_path": row["generated_path"] or "",
            "cloths": names,
        }


@router.post("/outfits/{outfit_id}/share")
def create_share(outfit_id: int, user=Depends(get_current_user)):
    """Make (or return) the link for this outfit.

    Idempotent while a link is live: pressing share twice hands out the same
    address rather than quietly leaving a second one open.
    """
    with get_conn() as conn:
        row = conn.execute(
            "SELECT generated_path FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        if not (row["generated_path"] or "").strip():
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "This outfit has no image yet — generate it before sharing.")
        existing = _live_share(conn, outfit_id, user["id"])
        if existing:
            return {"path": f"/share/{existing['token']}", **existing}
        token = secrets.token_urlsafe(TOKEN_BYTES)
        expires = _expiry()
        conn.execute(
            "INSERT INTO outfit_shares (token, outfit_id, user_id, expires_at) "
            "VALUES (?, ?, ?, ?)",
            (token, outfit_id, user["id"], expires),
        )
    log.info("outfit %s shared by user %s", outfit_id, user["id"])
    return {"token": token, "expires_at": expires, "path": f"/share/{token}"}


@router.get("/outfits/{outfit_id}/share")
def get_share(outfit_id: int, user=Depends(get_current_user)):
    """The live link for this outfit, if there is one."""
    with get_conn() as conn:
        owned = conn.execute(
            "SELECT 1 FROM outfits WHERE id = ? AND user_id = ?",
            (outfit_id, user["id"]),
        ).fetchone()
        if not owned:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Outfit not found")
        existing = _live_share(conn, outfit_id, user["id"])
    if not existing:
        return {"shared": False}
    return {"shared": True, "path": f"/share/{existing['token']}", **existing}


@router.delete("/outfits/{outfit_id}/share")
def revoke_share(outfit_id: int, user=Depends(get_current_user)):
    """Stop every link to this outfit working. The point of storing rows."""
    with get_conn() as conn:
        cur = conn.execute(
            "UPDATE outfit_shares SET revoked = 1 "
            "WHERE outfit_id = ? AND user_id = ? AND revoked = 0",
            (outfit_id, user["id"]),
        )
    return {"revoked": cur.rowcount}


@router.get("/share/{token}/image")
def shared_image(token: str):
    """The render itself, authorised by the token rather than by a signature —
    the recipient has no account and no signed URL."""
    share = _resolve(token)
    path = Path(share["generated_path"])
    if not path.is_file():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
    return FileResponse(
        path,
        headers={
            # A shared link is not a public catalogue entry.
            "Cache-Control": "private, max-age=3600",
            "X-Robots-Tag": "noindex, nofollow",
        },
    )


@router.get("/share/{token}", response_class=HTMLResponse)
def shared_page(token: str):
    """A plain page, no framework, no tracking, no account required."""
    share = _resolve(token)
    items = "".join(
        f"<li>{html.escape(c['name'])}"
        + (f" <span class='b'>{html.escape(c['brand'])}</span>" if c["brand"] else "")
        + "</li>"
        for c in share["cloths"]
    )
    body = f"""<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>An outfit</title>
<style>
  body {{ margin:0; background:#111; color:#eee; font-family:system-ui,sans-serif;
         display:flex; flex-direction:column; align-items:center; padding:24px; }}
  img {{ max-width:min(92vw, 520px); border-radius:12px; }}
  ul {{ list-style:none; padding:0; margin:20px 0 0; text-align:center; }}
  li {{ padding:4px 0; }}
  .b {{ color:#9aa; font-size:.85em; }}
  footer {{ margin-top:28px; color:#666; font-size:.8em; }}
</style>
</head><body>
<img src="/share/{html.escape(token)}/image" alt="Outfit">
<ul>{items}</ul>
<footer>Shared from Dressly · this link expires</footer>
</body></html>"""
    return HTMLResponse(
        body,
        headers={"X-Robots-Tag": "noindex, nofollow",
                 "Referrer-Policy": "no-referrer"},
    )
