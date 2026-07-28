"""Structured audit trail — a queryable record of what users do.

Complements the request log (every HTTP call, in data/logs/) with semantic,
business-level events (login, cloth created, outfit generated, ...) stored in
the ``audit_log`` table and also emitted to the logger. Best-effort: a logging
failure never breaks the request.
"""
import logging
from typing import Optional

from db import get_conn

log = logging.getLogger("dressly.audit")


def record(user: Optional[dict], action: str, detail: str = "", ip: str = "") -> None:
    uid = (user or {}).get("id")
    email = (user or {}).get("email")
    try:
        with get_conn() as conn:
            conn.execute(
                "INSERT INTO audit_log (user_id, email, action, detail, ip) "
                "VALUES (?, ?, ?, ?, ?)",
                (uid, email, action, detail, ip),
            )
    except Exception as e:  # pragma: no cover - never break the request
        log.warning("audit insert failed: %s", e)
    log.info("%s by %s%s", action, email or "anon",
             f" — {detail}" if detail else "")
