"""Signed URLs for the image mounts.

`/images/...` and `/generated/...` are served by a static mount with no auth,
and a good share of the paths are guessable — `/images/3/front_0.jpg`, with a
sequential cloth id. On a LAN that is harmless. On a public address it means
anyone can walk the whole wardrobe.

Rather than put a bearer token on every image request (which the platform image
caches cannot send, and which would defeat caching entirely), each URL carries a
short signature the server issued:

    /images/3/front_0.jpg?v=<mtime>&e=<expiry>&s=<signature>

The signature covers the path and the expiry, keyed by the same secret that
signs JWTs. Anyone can still *use* a URL they were given — that is the point,
the image cache re-fetches it — but nobody can invent one for a path they were
never shown, and every URL stops working after `IMAGE_URL_TTL_S`.

Turned off in dev by default so local work needs no ceremony; forced on when
CLOTHESAPP_ENV is not "dev".
"""
import base64
import hashlib
import hmac
import os
import time

import config

# How long a signed URL stays valid. Long enough that the app's disk cache is
# still useful, short enough that a leaked URL is not forever.
IMAGE_URL_TTL_S = int(os.environ.get("CLOTHESAPP_IMAGE_URL_TTL_S", "604800"))

# The expiry is rounded to this grid so that repeated requests for the same file
# produce the SAME url.
#
# This matters more than it looks. Image caches key on the URL, so an expiry of
# "now + TTL" — recomputed on every listing — yielded a different signature every
# second: the client re-downloaded the entire wardrobe each time the screen was
# opened, and its disk cache never hit once. Rounding to a day means the URL is
# byte-identical all day and the cache works, while the signature still expires.
IMAGE_URL_BUCKET_S = int(os.environ.get("CLOTHESAPP_IMAGE_URL_BUCKET_S", "86400"))

# Clock skew allowance between the signer and the checker (same process today,
# but a proxy or a second host could differ).
_SKEW_S = 60


def enabled() -> bool:
    """Signing is mandatory outside dev; in dev it is opt-in."""
    raw = os.environ.get("CLOTHESAPP_SIGN_IMAGE_URLS", "").strip().lower()
    if raw in ("1", "true", "yes"):
        return True
    if raw in ("0", "false", "no"):
        return False
    return not config.IS_DEV


def _signature(rel_path: str, expires: int) -> str:
    msg = f"{rel_path}|{expires}".encode("utf-8")
    digest = hmac.new(config.SECRET_KEY.encode("utf-8"), msg,
                      hashlib.sha256).digest()
    # 16 bytes is 128 bits of tag — far beyond guessing, and keeps URLs short.
    return base64.urlsafe_b64encode(digest[:16]).decode("ascii").rstrip("=")


def expiry_for(now: float) -> int:
    """Next expiry on the rounding grid, at least IMAGE_URL_TTL_S away.

    Stable for the whole bucket, so every request in that window signs the same
    URL and the client's image cache can actually hit.
    """
    bucket = max(1, IMAGE_URL_BUCKET_S)
    buckets_ahead = -(-IMAGE_URL_TTL_S // bucket)      # ceil division
    return (int(now // bucket) + buckets_ahead + 1) * bucket


def sign_query(rel_path: str, now: float | None = None) -> str:
    """Query fragment (`e=...&s=...`) authorising `rel_path`, or '' when off.

    `rel_path` is the path as it appears in the URL after the mount prefix,
    e.g. `3/front_0.jpg` — never the filesystem path.
    """
    if not enabled():
        return ""
    expires = expiry_for(now if now is not None else time.time())
    return f"e={expires}&s={_signature(rel_path, expires)}"


def verify(rel_path: str, expires: str | None, signature: str | None,
           now: float | None = None) -> bool:
    """Check a request's `e`/`s` against `rel_path`."""
    if not enabled():
        return True
    if not expires or not signature:
        return False
    try:
        expires_at = int(expires)
    except (TypeError, ValueError):
        return False
    current = now if now is not None else time.time()
    if expires_at + _SKEW_S < current:
        return False
    # Constant-time: a plain == leaks how much of the tag matched.
    return hmac.compare_digest(_signature(rel_path, expires_at), signature)


def parse_query(query: bytes | str) -> tuple[str | None, str | None]:
    """Pull `e` and `s` out of a raw query string."""
    from urllib.parse import parse_qs

    if isinstance(query, bytes):
        query = query.decode("latin-1")
    parsed = parse_qs(query, keep_blank_values=True)
    e = parsed.get("e", [None])[0]
    s = parsed.get("s", [None])[0]
    return e, s
