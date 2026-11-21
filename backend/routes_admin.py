"""Admin-only views. Currently: what the paid image API has cost.

Behind require_admin, which is the same guard the notification and audit queues
use. The figures are deliberately split into "what we spent" (ours, always
true) and "what the provider says is left" (only when a balance endpoint is
configured), so nothing on this screen is a guess presented as a fact.
"""
import logging
from typing import Optional

from fastapi import APIRouter, Depends

import apiusage
import bfl
from auth import require_admin

router = APIRouter(prefix="/admin", tags=["admin"])
log = logging.getLogger(__name__)


@router.get("/credits")
def credits(user=Depends(require_admin)):
    spent = apiusage.spent()
    balance = apiusage.provider_balance()
    return {
        "provider": balance,
        "spent": spent,
        # Without a key the server renders placeholders and bills nothing —
        # worth saying outright on a screen about money.
        "dry_run": not bool(bfl.api_key()),
    }


# --- what generations cost, by provider ---------------------------------------

_PERIODS = (("today", "date('now')"),
            ("week", "datetime('now', '-7 days')"),
            ("month", "datetime('now', '-30 days')"),
            ("all", "'0000'"))


def _openrouter_balance() -> Optional[dict]:
    """The OpenRouter account's credits and usage, or None if unreachable."""
    import json
    import urllib.request

    from config import OPENROUTER_API_KEY, OPENROUTER_BASE_URL
    if not OPENROUTER_API_KEY:
        return None
    try:
        req = urllib.request.Request(
            f"{OPENROUTER_BASE_URL}/credits",
            headers={"Authorization": f"Bearer {OPENROUTER_API_KEY}"})
        with urllib.request.urlopen(req, timeout=6) as r:
            data = json.loads(r.read()).get("data") or {}
        total = float(data.get("total_credits") or 0)
        used = float(data.get("total_usage") or 0)
        return {"credits": round(total, 4), "used": round(used, 4),
                "left": round(total - used, 4)}
    except Exception:  # noqa: BLE001 — a missing balance is a worse screen only
        log.warning("OpenRouter balance unavailable", exc_info=True)
        return None


@router.get("/costs")
def costs(user=Depends(require_admin)):
    """Spend in USD per provider and period, and the latest paid calls.

    OpenRouter and BFL come from api_usage (cost in BFL credits, 1 = $0.01,
    as each provider reported it); the stylist from llm_usage (priced from
    token counts when each call was made).
    """
    from db import get_conn
    out: dict = {}
    with get_conn() as conn:
        for key, where in (("openrouter", "tier = 'openrouter'"),
                           ("bfl", "tier != 'openrouter'")):
            periods = {}
            for name, since in _PERIODS:
                r = conn.execute(
                    f"SELECT COUNT(*) AS n, SUM(COALESCE(cost, 0)) AS c "
                    f"FROM api_usage WHERE ok = 1 AND {where} "
                    f"AND created_at >= {since}").fetchone()
                periods[name] = {"count": r["n"] or 0,
                                 "usd": round((r["c"] or 0) / 100, 4)}
            out[key] = periods
        periods = {}
        for name, since in _PERIODS:
            r = conn.execute(
                f"SELECT COUNT(*) AS n, SUM(cost_usd) AS c FROM llm_usage "
                f"WHERE created_at >= {since}").fetchone()
            periods[name] = {"count": r["n"] or 0, "usd": round(r["c"] or 0, 4)}
        out["stylist"] = periods
        by_model = conn.execute(
            "SELECT model, COUNT(*) AS n, SUM(cost_usd) AS c FROM llm_usage "
            "GROUP BY model ORDER BY c DESC").fetchall()
        recent = conn.execute(
            "SELECT created_at, label, usd FROM ("
            " SELECT created_at, slug AS label, COALESCE(cost, 0) / 100.0 AS usd, id, 0 AS src"
            " FROM api_usage WHERE ok = 1"
            " UNION ALL"
            " SELECT created_at, 'stylist:' || model, cost_usd, id, 1 FROM llm_usage"
            ") ORDER BY created_at DESC, id DESC LIMIT 40").fetchall()
    out["stylist_models"] = [{"model": r["model"], "count": r["n"],
                              "usd": round(r["c"] or 0, 4)} for r in by_model]
    out["recent"] = [{"at": r["created_at"], "label": r["label"],
                      "usd": round(r["usd"] or 0, 4)} for r in recent]
    out["openrouter_balance"] = _openrouter_balance()
    return out
