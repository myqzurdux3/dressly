"""Sliding-window rate limiting, shared across workers.

Two kinds of endpoint need it:

* the ones that cost money — every outfit generation and AI enhance is a paid
  bfl.ai call, and a stuck client must not be able to loop on them;
* the ones that guard credentials — /auth/login and /auth/signup, where the
  limit is what stands between a password and an offline-speed guessing run.

The counters live in SQLite rather than process memory. That is what makes
running more than one uvicorn worker safe: with in-memory counters, N workers
would silently allow N times the quota, and which worker answered would decide
whether a request was blocked.

Cost is one small write per limited request. Login and generation are low
volume by nature, so this is not on any hot path.
"""
import logging
import os
import time

from fastapi import Depends, HTTPException, Request, status

import config
from auth import get_current_user
from db import get_conn

log = logging.getLogger(__name__)

# Rows older than the longest window are dead weight; sweep them occasionally
# rather than on every request.
_CLEANUP_EVERY = 500
_since_cleanup = {"n": 0}


def _cleanup(conn, now: float) -> None:
    _since_cleanup["n"] += 1
    if _since_cleanup["n"] < _CLEANUP_EVERY:
        return
    _since_cleanup["n"] = 0
    longest = max(
        config.GENERATION_RATE_WINDOW_S,
        config.ENHANCE_RATE_WINDOW_S,
        config.AUTH_RATE_WINDOW_S,
    )
    conn.execute("DELETE FROM rate_hits WHERE ts <= ?", (now - longest,))


def _check(key: str, limit: int, window_s: int) -> float:
    """Record a hit. Returns 0 when allowed, else seconds until a slot frees up.

    Wall-clock time, not monotonic: the value is shared between processes, and
    each process has its own monotonic origin.
    """
    now = time.time()
    cutoff = now - window_s
    with get_conn() as conn:
        # The read and the write must not interleave with another worker's, or
        # two requests could both see limit-1 and both be allowed.
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("DELETE FROM rate_hits WHERE key = ? AND ts <= ?",
                     (key, cutoff))
        rows = conn.execute(
            "SELECT ts FROM rate_hits WHERE key = ? ORDER BY ts LIMIT 1", (key,)
        ).fetchall()
        count = conn.execute(
            "SELECT COUNT(*) AS n FROM rate_hits WHERE key = ?", (key,)
        ).fetchone()["n"]
        if count >= limit:
            oldest = rows[0]["ts"] if rows else now
            return max(1.0, oldest + window_s - now)
        conn.execute("INSERT INTO rate_hits (key, ts) VALUES (?, ?)", (key, now))
        _cleanup(conn, now)
    return 0.0


def reset() -> None:
    """Drop all counters. Used by tests and available for an operator clear."""
    _since_cleanup["n"] = 0
    with get_conn() as conn:
        conn.execute("DELETE FROM rate_hits")


def client_ip(request: Request) -> str:
    """Best-effort client address.

    uvicorn is started with --proxy-headers and an explicit trusted-proxy list,
    so request.client.host is already the real client when a reverse proxy is in
    front, and the proxy's own address otherwise. Never trust X-Forwarded-For
    directly here — anyone can send that header.
    """
    return request.client.host if request.client else "unknown"


def _deny(limit: int, window_s: int, retry_after: float, what: str):
    raise HTTPException(
        status.HTTP_429_TOO_MANY_REQUESTS,
        detail=(f"Too many {what}. The limit is {limit} per "
                f"{max(1, window_s // 60)} minutes. Try again shortly."),
        headers={"Retry-After": str(int(retry_after))},
    )


def limiter(bucket: str, limit_attr: str, window_attr: str):
    """Per-user quota for authenticated endpoints.

    The limits are read from `config` on every request rather than captured at
    import time, so they can be adjusted (and tested) without rebuilding the
    dependency. A limit of 0 disables the bucket.
    """
    def dependency(user=Depends(get_current_user)):
        limit = getattr(config, limit_attr)
        window_s = getattr(config, window_attr)
        if limit <= 0:
            return user
        retry_after = _check(f"{bucket}:u{user['id']}", limit, window_s)
        if retry_after:
            log.warning("rate limit hit: user=%s bucket=%s", user["id"], bucket)
            _deny(limit, window_s, retry_after, "requests")
        return user
    return dependency


def ip_limiter(bucket: str, limit_attr: str, window_attr: str, what: str):
    """Per-IP quota for endpoints reached *before* there is a user to key on.

    Sign-up and login are the whole reason this exists: without it, passwords
    can be guessed as fast as the network allows.
    """
    def dependency(request: Request):
        limit = getattr(config, limit_attr)
        window_s = getattr(config, window_attr)
        if limit <= 0:
            return
        ip = client_ip(request)
        retry_after = _check(f"{bucket}:ip{ip}", limit, window_s)
        if retry_after:
            log.warning("rate limit hit: ip=%s bucket=%s", ip, bucket)
            _deny(limit, window_s, retry_after, what)
    return dependency


def note_failed_login(request: Request) -> None:
    """Charge a wrong password against a tighter, separate budget.

    Kept apart from the per-attempt limit so that someone typing their own
    password wrong twice is not locked out at the same threshold as a script
    working through a word list.
    """
    if config.AUTH_FAIL_RATE_LIMIT <= 0:
        return
    ip = client_ip(request)
    retry_after = _check(f"authfail:ip{ip}", config.AUTH_FAIL_RATE_LIMIT,
                         config.AUTH_FAIL_WINDOW_S)
    if retry_after:
        log.warning("failed-login limit hit: ip=%s", ip)
        _deny(config.AUTH_FAIL_RATE_LIMIT, config.AUTH_FAIL_WINDOW_S,
              retry_after, "failed sign-in attempts")


# Buckets used by the routers.
generation_guard = limiter("generate", "GENERATION_RATE_LIMIT",
                           "GENERATION_RATE_WINDOW_S")
enhance_guard = limiter("enhance", "ENHANCE_RATE_LIMIT",
                        "ENHANCE_RATE_WINDOW_S")
auth_guard = ip_limiter("auth", "AUTH_RATE_LIMIT", "AUTH_RATE_WINDOW_S",
                        "sign-in attempts")


def worker_id() -> int:
    """Identifies the process that owns an in-flight background job."""
    return os.getpid()
