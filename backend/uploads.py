"""Bounded reading of multipart uploads.

Every upload route used to do `data = await upload.read()`: the whole body
landed in RAM with no ceiling, no count limit and no check that it was an
image. `/auth/signup` is open, so that was reachable by anyone, and three
uvicorn workers share one machine — a single request could get them OOM-killed.

The rule here: refuse early (413) instead of buffering, and cap the number of
parts as well as the size of each one.
"""

import io
import os

from fastapi import HTTPException, UploadFile, status
from PIL import Image

# One photo. 64 MB is many times a 12-megapixel JPEG (~6 MB) or a lossless PNG
# export from a phone — generous on purpose, since the owner is the only user.
MAX_UPLOAD_BYTES = int(os.environ.get("CLOTHESAPP_UPLOAD_MAX_BYTES", 64 * 1024 * 1024))

# Parts per request. A garment takes front + back + extras; a model takes two
# or three. Thirty leaves room for a multi-angle shoot; the point is only that
# the list is not unbounded.
MAX_UPLOAD_FILES = int(os.environ.get("CLOTHESAPP_UPLOAD_MAX_FILES", "30"))

# What actually protects the box: every part of a request is buffered in RAM
# before anything is written, so the per-file cap alone would allow
# MAX_UPLOAD_FILES x MAX_UPLOAD_BYTES (~2 GB) in one request on a machine
# running three workers. This bounds the whole request instead.
MAX_UPLOAD_TOTAL_BYTES = int(
    os.environ.get("CLOTHESAPP_UPLOAD_MAX_TOTAL_BYTES", 256 * 1024 * 1024))

_CHUNK = 1 << 20  # 1 MB


def check_count(uploads) -> None:
    """Reject a request carrying more parts than we are willing to process."""
    if len(uploads) > MAX_UPLOAD_FILES:
        raise HTTPException(
            status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            f"Too many images (max {MAX_UPLOAD_FILES})",
        )


class UploadBudget:
    """Running total for one request, so several parts cannot add up to a box.

    Pass the same instance to every read_capped call of a request; it refuses
    (413) as soon as the parts read so far exceed MAX_UPLOAD_TOTAL_BYTES.
    """

    def __init__(self, total_bytes: int = 0):
        self.limit = total_bytes or MAX_UPLOAD_TOTAL_BYTES
        self.used = 0

    def take(self, n: int) -> None:
        self.used += n
        if self.used > self.limit:
            raise HTTPException(
                status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                f"Upload too large in total (max {self.limit // (1024 * 1024)} MB "
                "per request)",
            )


async def read_capped(upload: UploadFile, *, max_bytes: int = 0,
                      budget: "UploadBudget | None" = None) -> bytes:
    """Read one upload, aborting as soon as it exceeds `max_bytes`.

    Reads in chunks so an oversized body is refused after ~1 MB rather than
    after the whole thing has been buffered. The default is looked up at call
    time, not bound at import, so the limit can be changed (and tested)
    without rebuilding the callers — same rule as the rate limits in
    ratelimit.py.
    """
    max_bytes = max_bytes or MAX_UPLOAD_BYTES
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await upload.read(_CHUNK)
        if not chunk:
            break
        total += len(chunk)
        if budget is not None:
            budget.take(len(chunk))
        if total > max_bytes:
            raise HTTPException(
                status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
                f"Image too large (max {max_bytes // (1024 * 1024)} MB)",
            )
        chunks.append(chunk)
    return b"".join(chunks)


def verify_image(data: bytes) -> None:
    """Reject anything PIL cannot open as an image.

    `Image.verify()` parses the header without decoding the pixels, so a
    decompression bomb is caught by Image.MAX_IMAGE_PIXELS (set in config)
    rather than by allocating it.
    """
    try:
        with Image.open(io.BytesIO(data)) as im:
            im.verify()
    except Exception as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "Not a valid image") from e
