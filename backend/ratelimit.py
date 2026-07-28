"""Per-user sliding-window rate limiting for endpoints that cost real money.

Every outfit generation and every AI enhance is a paid call to bfl.ai. Nothing
stopped a stuck client (or a retry loop in the app) from firing them back to
back, and the bill only shows up later.

Scope, stated plainly: the counters live in this process's memory. They reset on
restart and are not shared between workers, so this is a spend guard against
runaway clients — not a security control against a determined attacker. Running
more than one uvicorn worker would need a shared store (Redis) instead.
"""
import logging
import threading
import time
from collections import defaultdict, deque

from fastapi import Depends, HTTPException, status

import config
from auth import get_current_user

log = logging.getLogger(__name__)

_hits: dict = defaultdict(deque)
_lock = threading.Lock()


def _check(key: str, limit: int, window_s: int) -> float:
    """Record a hit. Returns 0 when allowed, else seconds until a slot frees up."""
    now = time.monotonic()
    cutoff = now - window_s
    with _lock:
        q = _hits[key]
        while q and q[0] <= cutoff:
            q.popleft()
        if len(q) >= limit:
            return max(1.0, q[0] + window_s - now)
        q.append(now)
        return 0.0


def reset() -> None:
    """Drop all counters. Used by tests and available for an operator clear."""
    with _lock:
        _hits.clear()


def limiter(bucket: str, limit_attr: str, window_attr: str):
    """Build a dependency enforcing a per-user quota.

    The limits are read from `config` on every request rather than captured at
    import time, so they can be adjusted (and tested) without rebuilding the
    dependency. A limit of 0 disables the bucket.
    """
    def dependency(user=Depends(get_current_user)):
        limit = getattr(config, limit_attr)
        window_s = getattr(config, window_attr)
        if limit <= 0:
            return user
        retry_after = _check(f"{bucket}:{user['id']}", limit, window_s)
        if retry_after:
            log.warning("rate limit hit: user=%s bucket=%s", user["id"], bucket)
            raise HTTPException(
                status.HTTP_429_TOO_MANY_REQUESTS,
                detail=(
                    f"Too many requests — the limit is {limit} per "
                    f"{max(1, window_s // 60)} minutes. Try again shortly."
                ),
                headers={"Retry-After": str(int(retry_after))},
            )
        return user
    return dependency


# Buckets used by the routers. Both front paid bfl.ai calls.
generation_guard = limiter("generate", "GENERATION_RATE_LIMIT",
                           "GENERATION_RATE_WINDOW_S")
enhance_guard = limiter("enhance", "ENHANCE_RATE_LIMIT",
                        "ENHANCE_RATE_WINDOW_S")
