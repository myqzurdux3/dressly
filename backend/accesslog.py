"""Access logging that measures the whole request, body included.

A Starlette/FastAPI `@app.middleware("http")` wraps the *handler*, so its timer
stops when the response object is returned — before a single byte of the body
has gone out. For JSON that is close enough. For a file response it is
meaningless: the image is streamed afterwards, so the log said "200 OK in 6 ms"
about a transfer the client was still waiting on.

This is raw ASGI middleware instead. It wraps `send`, so it can record when the
response *started* and when its last body chunk was handed to the transport,
and count the bytes.

Output goes to its own file (`data/logs/access.log`) so image traffic does not
drown the application log, in a format meant to be read by eye and by
`scripts/analyze_log.py`:

    2026-07-29 21:04:11 GET  200   1843ms   19.4KB  /thumb/images/400/3/front_0_cutout.webp  1.2.3.4
                                    ^^^^^^ total, including sending the body
"""
import logging
import os
import time
from logging.handlers import RotatingFileHandler

log = logging.getLogger("dressly.access")

# Requests slower than this are also copied to the main log, where they are
# visible without opening a second file.
SLOW_MS = int(os.environ.get("CLOTHESAPP_SLOW_MS", "1000"))

# Set to 0 to log only the slow ones.
LOG_EVERYTHING = os.environ.get("CLOTHESAPP_ACCESS_LOG", "1") != "0"


def configure(logs_dir) -> None:
    """Send access lines to their own rotating file."""
    if log.handlers:
        return
    handler = RotatingFileHandler(
        logs_dir / "access.log", maxBytes=20_000_000, backupCount=3,
        encoding="utf-8",
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(message)s",
                                           datefmt="%Y-%m-%d %H:%M:%S"))
    log.addHandler(handler)
    log.setLevel(logging.INFO)
    # Its own file only: without this every line is repeated in dressly.log.
    log.propagate = False


def _client(scope) -> str:
    c = scope.get("client")
    return c[0] if c else "-"


def _human_bytes(n: int) -> str:
    if n < 1024:
        return f"{n}B"
    if n < 1024 * 1024:
        return f"{n / 1024:.1f}KB"
    return f"{n / 1024 / 1024:.1f}MB"


class AccessLogMiddleware:
    """Times each request from arrival to the last byte of its body."""

    def __init__(self, app, app_log=None):
        self.app = app
        self.app_log = app_log or logging.getLogger("dressly.request")

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        start = time.perf_counter()
        state = {"status": 0, "bytes": 0, "first_byte_ms": None,
                 "last_byte_ms": None}

        async def send_wrapper(message):
            if message["type"] == "http.response.start":
                state["status"] = message["status"]
                state["first_byte_ms"] = (time.perf_counter() - start) * 1000
            elif message["type"] == "http.response.body":
                state["bytes"] += len(message.get("body", b""))
                if not message.get("more_body", False):
                    state["last_byte_ms"] = (time.perf_counter() - start) * 1000
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        finally:
            returned = (time.perf_counter() - start) * 1000
            # Stop at the last byte, not when the ASGI call returns. Starlette
            # runs BackgroundTasks after the body is sent but inside that call,
            # so timing the call made a 145 ms endpoint that kicks off a 15 s AI
            # generation read as "2.1KB, transfer 15748ms" — a slow network,
            # which it was not. Reported separately below instead.
            total = state["last_byte_ms"]
            if total is None:      # no body sent (disconnect, websocket upgrade)
                total = returned
            state["background_ms"] = returned - total
            self._record(scope, state, total)

    def _record(self, scope, state, total_ms):
        method = scope.get("method", "?")
        path = scope.get("path", "?")
        query = scope.get("query_string", b"").decode("latin-1")
        # Signatures and cache-busters make every line unreadable; the version
        # is the only part worth keeping, and only to spot a stale one.
        if query:
            keep = [p for p in query.split("&") if p.startswith("v=")]
            path += ("?" + "&".join(keep)) if keep else ""

        ttfb = state["first_byte_ms"]
        line = (f"{method:6} {state['status']:3} {total_ms:7.0f}ms "
                f"{_human_bytes(state['bytes']):>9} {path} {_client(scope)}")
        if ttfb is not None and total_ms - ttfb > 50:
            # Worth separating: a slow handler and a slow transfer have nothing
            # to do with each other.
            line += f" (handler {ttfb:.0f}ms, transfer {total_ms - ttfb:.0f}ms)"
        background_ms = state.get("background_ms") or 0
        if background_ms > 50:
            # Work that ran after the client already had its answer. It costs the
            # server, but nobody waited for it — counting it as request time is
            # how a 15 s AI generation looked like a 15 s download.
            line += f" (+{background_ms:.0f}ms background, client not waiting)"

        if LOG_EVERYTHING:
            log.info(line)
        if total_ms >= SLOW_MS:
            self.app_log.warning("SLOW %s", line)
