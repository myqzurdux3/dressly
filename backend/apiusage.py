"""How much of the paid image API has been spent.

Two different questions, and the screen shows both because only one of them can
be answered honestly from here:

  * what WE have spent — every job this server submitted, counted as it is
    submitted. Always available, and it is the number that explains a bill;
  * what the PROVIDER says is left, from GET /v1/credits. It answers for the
    account behind the server's API key, which is not necessarily the account
    somebody is signed into elsewhere — so it is labelled as the provider's
    figure, not as "your" balance.

Metering must never break a render, so every entry point here swallows its own
errors. A missing count is a worse screen; a failed generation is a worse app.
"""
import json
import logging
import os
import urllib.error
import urllib.request
from typing import Optional

import bfl
from config import BFL_BASE_URL
from db import get_conn

log = logging.getLogger(__name__)

# The provider's own balance. Documented at
# https://docs.bfl.ml/api-reference/get-the-users-credits — GET /v1/credits,
# authorised by the same API key as everything else, answering {"credits": N}.
# Derived from BFL_BASE_URL so a self-hosted or staging base is followed
# automatically, and still overridable.
DEFAULT_BALANCE_URL = f"{BFL_BASE_URL.rstrip('/')}/credits"
BALANCE_URL = os.environ.get("BFL_BALANCE_URL", "").strip() or DEFAULT_BALANCE_URL
BALANCE_TIMEOUT_S = 6.0

# Their pricing page: "1 credit = $0.01 USD", one rate for every model. Kept as
# a constant rather than hardcoded into a string so a price change is one edit,
# and shown as an approximation because it is their number, not a bill.
# https://docs.bfl.ml/quick_start/pricing
USD_PER_CREDIT = float(os.environ.get("BFL_USD_PER_CREDIT", "0.01"))

# Keys worth trying in whatever JSON a balance endpoint returns, most specific
# first. Guessing a shape is fine; guessing that the endpoint exists is not.
_BALANCE_KEYS = ("credits", "credit", "balance", "remaining", "available")


def record(*, slug: str, tier: str, ok: bool, user_id: Optional[int] = None,
           kind: str = "", cost: Optional[float] = None,
           output_mp: Optional[float] = None) -> None:
    """Count one submitted job, with what the provider said it cost.

    Called from bfl, never by a route directly. ``cost`` is in credits and comes
    straight out of the submit response; it is None for a refused submit and for
    any endpoint that does not report one.
    """
    try:
        with get_conn() as conn:
            conn.execute(
                "INSERT INTO api_usage (user_id, kind, tier, slug, ok, cost, "
                "output_mp) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (user_id, kind or "", tier or "", slug or "", 1 if ok else 0,
                 cost, output_mp),
            )
    except Exception as e:  # noqa: BLE001 - metering is not worth a 500
        log.warning("could not record API usage: %s", e)


def install() -> None:
    """Wire the meter into bfl. Called once at startup."""
    bfl.usage_recorder = record


def spent() -> dict:
    """What this server has submitted: totals, cost, and a breakdown by tier."""
    with get_conn() as conn:
        total = conn.execute(
            "SELECT COUNT(*) AS n, "
            "SUM(CASE WHEN ok = 1 THEN 1 ELSE 0 END) AS accepted, "
            "SUM(CASE WHEN ok = 1 THEN COALESCE(cost, 0) ELSE 0 END) AS credits, "
            "SUM(CASE WHEN ok = 1 AND cost IS NOT NULL THEN 1 ELSE 0 END) AS priced "
            "FROM api_usage").fetchone()
        by_tier = conn.execute(
            "SELECT tier, COUNT(*) AS n, "
            "SUM(COALESCE(cost, 0)) AS credits "
            "FROM api_usage WHERE ok = 1 "
            "GROUP BY tier ORDER BY n DESC").fetchall()
        recent = conn.execute(
            "SELECT COUNT(*) AS n, "
            "SUM(COALESCE(cost, 0)) AS credits FROM api_usage "
            "WHERE ok = 1 AND created_at >= datetime('now', '-30 days')"
        ).fetchone()
        last = conn.execute(
            "SELECT created_at FROM api_usage ORDER BY id DESC LIMIT 1"
        ).fetchone()
    accepted = (total["accepted"] or 0) if total else 0
    credits = float((total["credits"] or 0) if total else 0)
    priced = (total["priced"] or 0) if total else 0
    recent_credits = float((recent["credits"] or 0) if recent else 0)
    return {
        "calls_total": (total["n"] or 0) if total else 0,
        "calls_accepted": accepted,
        "calls_last_30_days": (recent["n"] or 0) if recent else 0,
        # Straight from the provider's replies, not an estimate from a rate card.
        "credits_spent": round(credits, 3),
        "usd_spent": round(credits * USD_PER_CREDIT, 2),
        "credits_last_30_days": round(recent_credits, 3),
        "usd_last_30_days": round(recent_credits * USD_PER_CREDIT, 2),
        # How many of the accepted calls came with a price. Rows written before
        # the provider reported one stay unpriced, and a total that silently
        # omits them would read as "cheaper than it was".
        "priced_calls": priced,
        "unpriced_calls": max(0, accepted - priced),
        "by_tier": {
            r["tier"] or "?": {"calls": r["n"],
                               "credits": round(float(r["credits"] or 0), 3)}
            for r in by_tier
        },
        "last_call_at": last["created_at"] if last else None,
    }


def _extract_balance(payload) -> Optional[float]:
    """Find a number that looks like a remaining balance, at the top level or
    one level down. Returns None when nothing recognisable is there — better no
    figure than a made-up one."""
    if isinstance(payload, (int, float)):
        return float(payload)
    if not isinstance(payload, dict):
        return None
    for key in _BALANCE_KEYS:
        v = payload.get(key)
        if isinstance(v, (int, float)):
            return float(v)
    for v in payload.values():
        if isinstance(v, dict):
            got = _extract_balance(v)
            if got is not None:
                return got
    return None


def provider_balance() -> dict:
    """The provider's own figure, when there is a URL to ask and it answers."""
    if not BALANCE_URL:
        return {"available": False, "reason": "no balance endpoint configured"}
    if not bfl.api_key():
        return {"available": False, "reason": "no API key configured"}
    try:
        req = urllib.request.Request(
            BALANCE_URL, method="GET",
            headers=bfl._auth_headers({"accept": "application/json"}))
        with urllib.request.urlopen(req, timeout=BALANCE_TIMEOUT_S) as resp:
            payload = json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        return {"available": False, "reason": f"provider unreachable: {e}"}
    credits = _extract_balance(payload)
    if credits is None:
        return {"available": False,
                "reason": "the provider's reply carried no recognisable balance"}
    return {
        "available": True,
        "credits": credits,
        # Their published rate, so the screen can say what the balance is worth
        # without anybody doing the arithmetic in their head.
        "usd": round(credits * USD_PER_CREDIT, 2),
        "usd_per_credit": USD_PER_CREDIT,
    }
