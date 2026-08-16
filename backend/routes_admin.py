"""Admin-only views. Currently: what the paid image API has cost.

Behind require_admin, which is the same guard the notification and audit queues
use. The figures are deliberately split into "what we spent" (ours, always
true) and "what the provider says is left" (only when a balance endpoint is
configured), so nothing on this screen is a guess presented as a fact.
"""
import logging

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
