"""Image generation through OpenRouter's Images API.

One synchronous call: ``POST {OPENROUTER_BASE_URL}/images`` with the model id,
the prompt and the reference photos as ``input_references`` (base64 data URIs
are accepted). The reply carries the picture as ``data[0].b64_json`` and what
it cost, in USD, as ``usage.cost``.

Docs: https://openrouter.ai/docs/features/multimodal/image-generation
"""

from __future__ import annotations

import base64
import json
import urllib.error
import urllib.request
from typing import List, Optional, Tuple

from config import (
    OPENROUTER_API_KEY,
    OPENROUTER_BASE_URL,
    OPENROUTER_MAX_IMAGES,
    OPENROUTER_MODEL,
    OPENROUTER_TIMEOUT_S,
)

# Ratios every image model on OpenRouter understands (providers clamp to
# their own subset). The outfit canvas is picked from these by closeness.
_RATIOS = {
    "1:1": 1.0, "4:5": 0.8, "3:4": 0.75, "2:3": 2 / 3, "9:16": 9 / 16,
    "5:4": 1.25, "4:3": 4 / 3, "3:2": 1.5, "16:9": 16 / 9,
}


class OpenRouterError(RuntimeError):
    pass


def available() -> bool:
    return bool(OPENROUTER_API_KEY)


def model() -> str:
    return OPENROUTER_MODEL


def aspect_ratio_for(width: int, height: int) -> str:
    target = width / height if height else 1.0
    return min(_RATIOS, key=lambda k: abs(_RATIOS[k] - target))


def build_body(model_id: str, prompt: str, image_data_uris: List[str],
               width: int, height: int) -> dict:
    body: dict = {
        "model": model_id,
        "prompt": prompt or "",
        "aspect_ratio": aspect_ratio_for(width, height),
        "n": 1,
    }
    refs = image_data_uris[:OPENROUTER_MAX_IMAGES]
    if refs:
        body["input_references"] = [
            {"type": "image_url", "image_url": {"url": uri}} for uri in refs
        ]
    return body


def parse_reply(reply: dict) -> Tuple[bytes, Optional[float]]:
    """(image bytes, cost in USD or None) from an Images API reply.

    Every failure — a malformed reply, bad base64, a download that breaks —
    surfaces as OpenRouterError so callers have exactly one thing to catch."""
    if not isinstance(reply, dict):
        raise OpenRouterError(f"reply is not a JSON object: {reply!r}"[:400])
    data = reply.get("data") or []
    if not data:
        err = reply.get("error")
        raise OpenRouterError(f"no image in reply: {err or reply}"[:400])
    first = data[0] if isinstance(data, list) else None
    if not isinstance(first, dict):
        raise OpenRouterError(f"malformed image entry: {data!r}"[:400])
    b64 = first.get("b64_json")
    if b64:
        try:
            raw = base64.b64decode(b64)
        except (ValueError, TypeError) as e:  # binascii.Error is a ValueError
            raise OpenRouterError(f"reply image is not valid base64: {e}") from e
    elif first.get("url"):
        try:
            with urllib.request.urlopen(first["url"],
                                        timeout=OPENROUTER_TIMEOUT_S) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            raise OpenRouterError(f"image download: HTTP {e.code}") from e
        except urllib.error.URLError as e:
            raise OpenRouterError(f"image download: {e.reason}") from e
        except (OSError, ValueError) as e:  # timeouts, resets, bad URL
            raise OpenRouterError(f"image download: {e}") from e
    else:
        raise OpenRouterError("reply image has neither b64_json nor url")
    cost = (reply.get("usage") or {}).get("cost")
    return raw, float(cost) if isinstance(cost, (int, float)) else None


def generate(prompt: str, image_data_uris: List[str], *, width: int,
             height: int, model_id: Optional[str] = None
             ) -> Tuple[bytes, str, Optional[float]]:
    """Render one image. Returns (bytes, model id, cost USD or None)."""
    if not available():
        raise OpenRouterError("OPENROUTER_API_KEY is not set")
    mid = model_id or OPENROUTER_MODEL
    body = build_body(mid, prompt, image_data_uris, width, height)
    req = urllib.request.Request(
        f"{OPENROUTER_BASE_URL}/images",
        data=json.dumps(body).encode(),
        method="POST",
        headers={
            "Authorization": f"Bearer {OPENROUTER_API_KEY}",
            "Content-Type": "application/json",
            "X-Title": "Dressly",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=OPENROUTER_TIMEOUT_S) as resp:
            reply = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:400]
        raise OpenRouterError(f"{mid}: HTTP {e.code} {detail}") from e
    except urllib.error.URLError as e:
        raise OpenRouterError(f"{mid}: {e.reason}") from e
    except (OSError, ValueError) as e:
        # OSError: a timeout or reset while reading the body (not a URLError).
        # ValueError: the body is not JSON (JSONDecodeError, UnicodeDecodeError).
        raise OpenRouterError(f"{mid}: unreadable reply: {e}") from e
    raw, cost = parse_reply(reply)
    return raw, mid, cost
