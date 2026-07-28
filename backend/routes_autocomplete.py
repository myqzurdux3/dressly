from fastapi import APIRouter, Depends

from auth import get_current_user
from db import get_conn

router = APIRouter(prefix="/autocomplete", tags=["autocomplete"])


@router.get("/brands")
def brands(user=Depends(get_current_user)):
    """Distinct brands across ALL users' clothes (global autocomplete)."""
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT DISTINCT brand FROM clothes "
            "WHERE TRIM(brand) != '' ORDER BY brand COLLATE NOCASE"
        ).fetchall()
    return [r["brand"] for r in rows]


@router.get("/tags")
def tags(user=Depends(get_current_user)):
    """Distinct custom tags across ALL users' clothes (global autocomplete)."""
    out: set[str] = set()
    with get_conn() as conn:
        rows = conn.execute("SELECT custom_tags FROM clothes").fetchall()
    for r in rows:
        try:
            import json

            for t in json.loads(r["custom_tags"] or "[]"):
                if isinstance(t, str) and t.strip():
                    out.add(t)
        except (ValueError, TypeError):
            continue
    return sorted(out, key=str.lower)