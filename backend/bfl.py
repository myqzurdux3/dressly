"""Black Forest Labs image-generation client (image-based).

The outfit is composed from the **actual photos** the user uploaded — the
model (person) picture plus each selected cloth's picture — passed to bfl as
reference images (``input_image``, ``input_image_2``, ...). No descriptive
text prompt is generated from cloth names; only the user's optional prompt is
sent (bfl accepts an empty prompt for the FLUX 2 family).

Cloth-photo enhancement uses the three-tier FLUX 2 multi-image cascade, cheap
to expensive:

  flex (flux-2-klein-4b) -> pro (flux-2-pro) -> max (flux-2-max)

Outfit generation slots FLUX Virtual Try-On (VTO) into that cascade after flex:

  flex -> vto (flux-tools/vto-v2) -> pro -> max

A fresh render starts at flex; VTO is the next step up (the "try a better model"
button). VTO REQUIRES both a person image and a garment image, so it's dropped
entirely when no model photo is present. See ``generate_outfit``.

On a real-call failure the cascade auto-advances to the next tier so a
transient bad result or wrong slug doesn't break the flow. When the last tier
also fails, ``BflError`` is raised carrying every per-tier error so the route
can surface it and the UI can offer a "report to support" action.

When no ``BFL_API_KEY`` is configured (env or config default), we fall back to
a self-contained DRY_RUN placeholder so local dev still works end to end.

bfl is asynchronous: POST returns ``{"id", "polling_url"}``; poll the
``polling_url`` until ``status == "Ready"``, then ``result.sample`` is the
image URL. ``_resolve_image_url`` also tolerates direct-result shapes in case
bfl adds a sync endpoint.
"""

import base64
import io
import json
import os
import tempfile
import time
import urllib.error
import urllib.request
import math
from pathlib import Path
from typing import List, Optional

from PIL import Image, ImageDraw, ImageFont

from config import (
    BFL_AUTH_HEADER,
    BFL_AUTH_SCHEME,
    BFL_BASE_URL,
    BFL_CONNECT_TIMEOUT_S,
    BFL_IMAGE_MAX_PX,
    BFL_VTO_IMAGE_MAX_PX,
    BFL_VTO_PROMPT_UPSAMPLING,
    BFL_MODEL_FLEX,
    BFL_MODEL_MAX,
    BFL_MODEL_PRO,
    BFL_MODEL_VTO,
    BFL_POLL_INTERVAL_S,
    BFL_POLL_TIMEOUT_S,
    BFL_SAFETY_TOLERANCE,
    BFL_UPLOAD_TIMEOUT_S,
)

# Environment-only; no key in source. Empty => DRY_RUN placeholder images.
DEFAULT_API_KEY = os.environ.get("BFL_API_KEY", "").strip()

# How many input images each model actually accepts, from the endpoints' own
# OpenAPI schemas: the klein models expose input_image .. input_image_4, while
# pro / max / flex expose eight.
# https://docs.bfl.ml/api-reference/models/generate-or-edit-an-image-with-flux2-[klein]-4b
#
# This used to be a flat {"flex": 8, "pro": 8, "max": 8}, keyed on the app's own
# tier names — but the app's cheapest tier is configured as flux-2-klein-4b,
# which takes four. Sending it a fifth reference image is a request the model
# has no field for, so an outfit with several garments in separate-image mode
# failed at the first tier and fell through to the expensive ones.
_SLUG_MAX_IMAGES = {
    "flux-2-klein-4b": 4,
    "flux-2-klein-9b": 4,
    "flux-2-klein-9b-preview": 4,
    "flux-2-pro": 8,
    "flux-2-pro-preview": 8,
    "flux-2-max": 8,
    "flux-2-flex": 8,
}
# Unknown slug: assume the smaller cap. Sending too few images is a poorer
# reference; sending too many is a rejected request.
_DEFAULT_MAX_IMAGES = 4


def max_images_for(slug: str) -> int:
    """How many reference images this model slug accepts."""
    name = (slug or "").strip().lower().lstrip("/")
    if name in _SLUG_MAX_IMAGES:
        return _SLUG_MAX_IMAGES[name]
    # A slug nobody listed: klein is the family with the small cap.
    return 4 if "klein" in name else _DEFAULT_MAX_IMAGES

TIER_ORDER = ("flex", "pro", "max")
TIER_SLUGS = {
    "flex": BFL_MODEL_FLEX,
    "pro": BFL_MODEL_PRO,
    "max": BFL_MODEL_MAX,
}

# Derived from what each tier is actually pointed at, so re-pointing a tier at
# another model in the environment moves its cap with it.
TIER_MAX_IMAGES = {tier: max_images_for(slug) for tier, slug in TIER_SLUGS.items()}

# Outfit cascade: flex first (fast FLUX render), then VTO try-on (needs a
# person), then the higher FLUX tiers.
#
# Why VTO is not first, checked 2026-07 against their published prices:
# BFL lists no price line for try-on at all, but both vto-v1 and vto-v2 take
# `Flux2KleinTryonInputs`, documented as "Input model for FLUX.2 Klein VTO
# endpoint" — try-on runs on Klein and is billed by megapixel like the rest of
# the FLUX.2 family. flex here IS flux-2-klein-4b, the cheapest entry in that
# table (from $0.014), and vto-v2 renders up to 4 MP where klein-4b's first
# megapixel is the flat floor. So try-on cannot come out under the cheapest
# Klein call, and the cheap-first order stands.
# https://docs.bfl.ml/quick_start/pricing
# https://docs.bfl.ml/api-reference/models/virtual-try-on-v2
#
# The per-request truth is in the response's `cost` field, which is recorded —
# so if this ever stops holding, the admin credits screen will show it rather
# than this comment having to be believed.
VTO_TIER = "vto"
OUTFIT_TIER_ORDER = ("flex", VTO_TIER, "pro", "max")
# A safe static prompt if the caller passes none (per the VTO prompting guide).
DEFAULT_VTO_PROMPT = (
    "The person of image 1, maintaining exactly their face and pose, "
    "wearing the garments of image 2."
)

OUT_W = 1024
OUT_H = 1024


class BflError(RuntimeError):
    pass


class BflModerated(BflError):
    """The provider refused the image itself.

    A verdict, not a hiccup: the same picture through a bigger model gets the
    same answer, so the cascade stops instead of paying for two more refusals.
    """


# From their documented StatusResponse enum. "Failed" is NOT in it — it was
# being handled here while these two were not.
MODERATED_STATUSES = ("Request Moderated", "Content Moderated")


def api_key() -> str:
    return os.environ.get("BFL_API_KEY", "").strip() or DEFAULT_API_KEY


def _fit_dims(ar: float) -> tuple[int, int]:
    """Width/height for aspect ratio ``ar`` (=w/h) at ~1 MP, each side rounded to
    a multiple of 32 and clamped to a sane range (FLUX requirement)."""
    area = OUT_W * OUT_H
    h = (area / max(0.1, ar)) ** 0.5
    w = h * ar

    def _r(x: float) -> int:
        return max(512, min(1536, int(round(x / 32)) * 32))

    return _r(w), _r(h)


def _outfit_output_dims(person_path: Optional[str]) -> tuple[int, int]:
    """Output size for an outfit render. FLUX pro/max HONOUR the requested
    width/height, so the old square 1024×1024 squished a full-body outfit into a
    square (flex/VTO instead follow the input aspect, which is why only pro/max
    looked wrong). Match the model photo's aspect when there is one; otherwise use
    a portrait default, since outfits are head-to-toe."""
    if person_path and Path(person_path).exists():
        try:
            with Image.open(person_path) as im:
                w, h = im.size
            if w > 0 and h > 0:
                return _fit_dims(w / h)
        except Exception:
            pass
    return _fit_dims(3 / 4)  # portrait default (full-body outfit)


def generate(
    prompt: str,
    image_paths: List[str],
    start_tier: str = "flex",
    *,
    width: int = OUT_W,
    height: int = OUT_H,
    deadline_s: Optional[float] = None,
) -> tuple[bytes, str, str]:
    """Generate an outfit image from the model + cloth photos.

    ``image_paths`` is ordered: the model (person) photo first, then the
    selected cloth photos. Only as many as the tier accepts are sent; extras
    are dropped (logged via the returned error only on total failure).

    Returns ``(image_bytes, tier_used, model_slug)``. With no API key, returns
    a mock image (tier ``start_tier``, slug ``'mock'``). Raises ``BflError``
    only if every tier fails.
    """
    # Match the output aspect to the model photo (first image) so pro/max don't
    # squish a full-body outfit into a square.
    width, height = _outfit_output_dims(image_paths[0] if image_paths else None)
    if not api_key():
        return _mock_image(prompt, width, height), start_tier, "mock"
    
    if start_tier not in TIER_ORDER:
        start_tier = "flex"
    start_idx = TIER_ORDER.index(start_tier)

    # Pre-prepare the data URIs once (resize + base64) so each tier reuses them.
    prepared = [_prepare_image(p) for p in image_paths if p and Path(p).exists()]

    errors: list[str] = []
    # Each tier can spend the submit budget plus the poll budget before it gives
    # up, so a three-tier cascade can run for minutes with somebody watching a
    # spinner. ``deadline_s`` stops starting new attempts past that point: the
    # caller would rather hear "it failed" than keep waiting.
    started = time.monotonic()
    for tier in TIER_ORDER[start_idx:]:
        if deadline_s is not None and tier != TIER_ORDER[start_idx] \
                and time.monotonic() - started >= deadline_s:
            errors.append(
                f"gave up before {tier}: {deadline_s:.0f}s budget spent")
            break
        slug = TIER_SLUGS[tier]
        try:
            payload = _submit(slug, prompt, prepared, width=width, height=height)
            url = _resolve_image_url(payload, slug)
            return _download(url), tier, slug
        except BflModerated:
            # Every tier moderates the same picture the same way. Advancing the
            # cascade here is three refusals billed instead of one.
            raise
        except BflError as e:
            errors.append(f"{tier}({slug}): {e}")
        except Exception as e:
            errors.append(f"{tier}({slug}): {type(e).__name__}: {e}")

    raise BflError("All generation tiers failed: " + " | ".join(errors))


def next_tier(current: str) -> Optional[str]:
    # FLUX-only cascade (flex -> pro -> max). Used for cloth-photo enhancement,
    # which never involves try-on. Outfits use ``next_outfit_tier``.
    if current not in TIER_ORDER:
        return None
    i = TIER_ORDER.index(current)
    return TIER_ORDER[i + 1] if i + 1 < len(TIER_ORDER) else None


def next_outfit_tier(current: str, can_vto: bool = True) -> Optional[str]:
    """Next tier for the outfit "try a better model" button, walking
    ``flex -> vto -> pro -> max``. VTO is skipped for model-less outfits so
    those step ``flex -> pro -> max``. Returns None past the last tier."""
    order = [t for t in OUTFIT_TIER_ORDER if can_vto or t != VTO_TIER]
    if current not in order:
        return None
    i = order.index(current)
    return order[i + 1] if i + 1 < len(order) else None


def _outfit_cascade(start_tier: str, can_vto: bool) -> list[str]:
    """The list of tiers to try, in order, for one outfit generation.

    The cascade is the suffix of ``flex -> vto -> pro -> max`` starting at
    ``start_tier`` (so an explicit tier — e.g. the "try a better model" button
    stepping to vto/pro/max — is honoured verbatim). Without a person, vto is
    dropped entirely. An unknown tier defaults to flex.
    """
    order = OUTFIT_TIER_ORDER  # (flex, vto, pro, max)
    st = start_tier if start_tier in order else "flex"
    tiers = list(order[order.index(st):])
    if not can_vto:
        tiers = [t for t in tiers if t != VTO_TIER]
    return tiers or list(TIER_ORDER)


def generate_outfit(
    prompt: str,
    image_paths: List[str],
    start_tier: str = VTO_TIER,
    *,
    person_path: Optional[str] = None,
    garment_path: Optional[str] = None,
    vto_prompt: Optional[str] = None,
    width: int = OUT_W,
    height: int = OUT_H,
    deadline_s: Optional[float] = None,
) -> tuple[bytes, str, str]:
    """Generate an outfit image, preferring VTO then cascading through FLUX.

    ``person_path`` + ``garment_path`` are the two VTO inputs (the model photo
    and the merged garment **collage**). VTO only accepts one garment image, so
    ``garment_path`` must always be a single collage even when the FLUX tiers use
    separate images; ``vto_prompt`` is the matching collage-style prompt (falls
    back to ``prompt`` when not given, i.e. in collage mode). When a person is
    present VTO is tried at its slot in the cascade; on failure, or with no
    person, generation falls back to the FLUX tiers over ``image_paths``. Returns
    ``(image_bytes, tier_used, model_slug)``; raises ``BflError`` only if every
    tier fails.
    """
    can_vto = bool(
        person_path and garment_path
        and Path(person_path).exists() and Path(garment_path).exists()
    )
    tiers = _outfit_cascade(start_tier, can_vto)
    # Match the output aspect to the model photo (portrait fallback for outfit-
    # only) so the FLUX pro/max tiers don't render a squished square.
    width, height = _outfit_output_dims(person_path)

    if not api_key():
        return _mock_image(prompt, width, height), tiers[0], "mock"

    prepared = [_prepare_image(p) for p in image_paths if p and Path(p).exists()]
    # Higher JPEG quality + a larger resolution cap for the try-on reference
    # images than the FLUX tiers use — the VTO model transfers the garment
    # directly and its output follows the person resolution, so cleaner, larger
    # inputs give more texture/detail in the result.
    person_b64 = (_encode_jpeg_b64(person_path, quality=95,
                                   max_px=BFL_VTO_IMAGE_MAX_PX)
                  if can_vto else None)
    garment_b64 = (_encode_jpeg_b64(garment_path, quality=95,
                                    max_px=BFL_VTO_IMAGE_MAX_PX)
                   if can_vto else None)

    errors: list[str] = []
    # Same budget rule as generate(): four tiers, each able to spend the submit
    # plus the poll timeout, is roughly eight minutes of somebody watching a
    # spinner. The deadline does not abort a tier already in flight — it stops
    # STARTING another one once the budget is spent.
    started = time.monotonic()
    for tier in tiers:
        if deadline_s is not None and tier != tiers[0] \
                and time.monotonic() - started >= deadline_s:
            errors.append(
                f"gave up before {tier}: {deadline_s:.0f}s budget spent")
            break
        try:
            if tier == VTO_TIER:
                payload = _submit_vto(vto_prompt or prompt, person_b64, garment_b64)
                url = _resolve_image_url(payload, BFL_MODEL_VTO)
                return _download(url), VTO_TIER, BFL_MODEL_VTO
            slug = TIER_SLUGS[tier]
            payload = _submit(slug, prompt, prepared, width=width, height=height)
            url = _resolve_image_url(payload, slug)
            return _download(url), tier, slug
        except BflModerated:
            # Same reasoning as the enhancement cascade: a refusal is a verdict
            # on the picture, and the next tier will bill for the same verdict.
            raise
        except BflError as e:
            errors.append(f"{tier}: {e}")
        except Exception as e:
            errors.append(f"{tier}: {type(e).__name__}: {e}")

    raise BflError("All outfit tiers failed: " + " | ".join(errors))


def make_labeled_collage(items: List[dict], *, max_px: int = 1024) -> Optional[str]:
    """Tile cloth cutouts onto a single reference image, one label per item.

    ``items`` is a list of ``{"path", "label"}`` dicts. They are laid out in a
    square grid in reading order, so the caller's order is what the model sees
    first to last — the callers pass them innermost-worn first.

    (This docstring used to claim the grid was split into TOP / BOTTOM / FEET
    rows by position. It never was: _tile fills a square grid in list order and
    the role only ever appeared in the text label.)

    Returns a temp PNG path, or None if no images.
    """
    if not items:
        return None
    paths = [it["path"] for it in items if it.get("path")]
    labels = [it.get("label", "") for it in items if it.get("path")]
    return _tile(paths, labeled=True, labels=labels, max_px=max_px)


def _tile(image_paths: List[str], *, labeled: bool = False,
          labels: Optional[List[str]] = None, max_px: int = 1024) -> Optional[str]:
    imgs = []
    valid_labels = []
    for i, p in enumerate(image_paths):
        try:
            im = Image.open(p).convert("RGBA")
            imgs.append(im)
            if labels and i < len(labels):
                valid_labels.append(labels[i])
            else:
                valid_labels.append("")
        except Exception:
            continue
    if not imgs:
        return None
    n = len(imgs)
    cols = math.isqrt(n) or 1
    if cols * cols < n:
        cols += 1
    rows = math.ceil(n / cols)
    cell = max_px // max(cols, rows)
    gap = 12
    label_h = 22 if labeled else 0
    canvas_w = cols * cell + (cols + 1) * gap
    canvas_h = rows * (cell + label_h) + (rows + 1) * gap
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (255, 255, 255, 255))
    draw = ImageDraw.Draw(canvas)
    font = None
    for cand in ("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"):
        try:
            font = ImageFont.truetype(cand, 16)
            break
        except Exception:
            continue
    if font is None:
        font = ImageFont.load_default()
    for i, im in enumerate(imgs):
        r, c = divmod(i, cols)
        im_resized = _fit(im, cell, cell)
        x = gap + c * (cell + gap) + (cell - im_resized.width) // 2
        y = gap + r * (cell + label_h + gap)
        canvas.alpha_composite(im_resized, (x, y))
        if labeled and valid_labels[i]:
            draw.text((x + 2, y + cell + 2), valid_labels[i],
                      fill=(40, 40, 40, 255), font=font)
    out = canvas.convert("RGB")
    tmp = tempfile.NamedTemporaryFile(suffix="_collage.png", delete=False)
    out.save(tmp, format="PNG")
    tmp.close()
    return tmp.name


def _fit(im: Image.Image, max_w: int, max_h: int) -> Image.Image:
    w, h = im.size
    scale = min(max_w / w, max_h / h, 1.0)
    if scale < 1.0:
        im = im.resize((max(1, int(w * scale)), max(1, int(h * scale))))
    return im


def _encode_jpeg_b64(path: str, quality: int = 85, max_px: Optional[int] = None) -> str:
    """Load, downscale to ``max_px`` (default BFL_IMAGE_MAX_PX), re-encode as
    JPEG, return the raw base64 string. Keeps uploads fast and input_mp cheap.
    ``quality`` defaults to 85 (FLUX render tiers); the try-on inputs pass a
    higher value + a larger cap for more garment/skin fidelity."""
    img = Image.open(path)
    img = img.convert("RGB")
    max_px = max(1, max_px or BFL_IMAGE_MAX_PX)
    w, h = img.size
    scale = min(1.0, max_px / max(w, h))
    if scale < 1.0:
        # LANCZOS keeps garment edges/texture crisper on downscale than the
        # default filter — a cheap quality win for the try-on reference images.
        img = img.resize((max(1, int(w * scale)), max(1, int(h * scale))),
                         Image.LANCZOS)
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality, optimize=True)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _prepare_image(path: str) -> str:
    """As ``_encode_jpeg_b64`` but wrapped as a ``data:image/jpeg;base64,...``
    URI, which the FLUX 2 multi-image endpoints accept for ``input_image``."""
    return f"data:image/jpeg;base64,{_encode_jpeg_b64(path)}"


# Set by apiusage at import time. Called once per accepted job so the admin
# screen can say how much of the paid API has been spent. Kept as a hook rather
# than an import so this module stays free of the database.
usage_recorder = None


def _record_usage(slug: str, ok: bool, payload: Optional[dict] = None) -> None:
    """Count one submitted job, with what it cost when the reply says.

    Every FLUX.2 submit answers with `cost` in credits plus `input_mp` /
    `output_mp` (see AsyncResponse in their OpenAPI). Recording it turns the
    admin screen from "how many calls" into "how much", which is the question
    anybody actually has.
    """
    if usage_recorder is None:
        return
    try:
        extra = {}
        if isinstance(payload, dict):
            for key in ("cost", "output_mp"):
                value = payload.get(key)
                if isinstance(value, (int, float)):
                    extra[key] = float(value)
        usage_recorder(slug=slug, tier=slug_to_tier(slug), ok=ok, **extra)
    except Exception:  # noqa: BLE001 - metering must never break a render
        pass


def _submit(slug: str, prompt: str, image_data_uris: List[str], *, width: int, height: int) -> dict:
    # safety_tolerance was never sent, so every call used the provider's
    # default of 2 with no way to loosen it — see BFL_SAFETY_TOLERANCE.
    body: dict = {"prompt": prompt or "", "width": width, "height": height,
                  "safety_tolerance": BFL_SAFETY_TOLERANCE}
    # input_image, input_image_2, ... up to the tier's cap.
    # Keyed on the slug, not on the tier name: the slug is what the request is
    # going to, and it is the thing with a documented limit.
    cap = max_images_for(slug)
    for i, uri in enumerate(image_data_uris[:cap]):
        key = "input_image" if i == 0 else f"input_image_{i + 1}"
        body[key] = uri
    try:
        payload = _post_json(slug, body)
    except Exception:
        # A rejected submit is not a job; a failed one after acceptance is
        # counted when it is accepted, which is the moment that costs.
        _record_usage(slug, ok=False)
        raise
    _record_usage(slug, ok=True, payload=payload)
    return payload


def _submit_vto(prompt: str, person_b64: str, garment_b64: str) -> dict:
    """Submit a FLUX Virtual Try-On job: one person image + one garment image.

    ``person``/``garment`` are raw base64 (the endpoint maps them internally to
    input_image / input_image_2). VTO takes no width/height — the output follows
    the person image's aspect ratio. Returns the async submit payload.
    """
    body = {
        "prompt": prompt or DEFAULT_VTO_PROMPT,
        "person": person_b64,
        "garment": garment_b64,
        "output_format": "png",
        "safety_tolerance": BFL_SAFETY_TOLERANCE,
    }
    if BFL_VTO_PROMPT_UPSAMPLING:
        body["prompt_upsampling"] = True
        try:
            payload = _post_json(BFL_MODEL_VTO, body)
            _record_usage(BFL_MODEL_VTO, ok=True, payload=payload)
            return payload
        except BflError as e:
            # If the slug rejects the quality field (400/422 bad request), retry
            # WITHOUT it rather than let the cascade skip try-on entirely. A
            # rejected submit costs nothing, so it is recorded as such.
            _record_usage(BFL_MODEL_VTO, ok=False)
            if not any(code in str(e) for code in ("HTTP 400", "HTTP 422")):
                raise
            body.pop("prompt_upsampling", None)
    try:
        payload = _post_json(BFL_MODEL_VTO, body)
    except Exception:
        _record_usage(BFL_MODEL_VTO, ok=False)
        raise
    _record_usage(BFL_MODEL_VTO, ok=True, payload=payload)
    return payload


def _post_json(slug: str, body: dict) -> dict:
    """POST a JSON body to ``{BFL_BASE_URL}/{slug}``, with the same X-Key ->
    Bearer auth fallback used across every bfl endpoint. Returns the parsed JSON
    (typically the async ``{"id", "polling_url"}`` submit response)."""
    data = json.dumps(body).encode()
    url = f"{BFL_BASE_URL}/{slug}"
    headers = _auth_headers({"Content-Type": "application/json"})
    req = urllib.request.Request(url, data=data, method="POST", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=BFL_UPLOAD_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        if e.code in (401, 403) and BFL_AUTH_HEADER.lower() == "x-key":
            try:
                req2 = urllib.request.Request(
                    url, data=data, method="POST",
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {api_key()}"},
                )
                with urllib.request.urlopen(req2, timeout=BFL_UPLOAD_TIMEOUT_S) as resp:
                    return json.loads(resp.read().decode())
            except Exception as e2:
                raise BflError(f"{slug}: HTTP {getattr(e2,'code','?')} {_safe_error_body(e2)[:200]} (after Bearer retry)") from e2
        raise BflError(f"{slug}: HTTP {e.code} {_safe_error_body(e)[:200]} (check BFL_API_KEY / model slug / BFL_AUTH_HEADER)") from e
    except urllib.error.URLError as e:
        reason = getattr(e, "reason", None) or "connection failed"
        raise BflError(
            f"{slug}: cannot reach {url} ({reason}) within {BFL_UPLOAD_TIMEOUT_S}s — check BFL_BASE_URL, DNS, firewall, or reduce BFL_IMAGE_MAX_PX"
        ) from e


def slug_to_tier(slug: str) -> str:
    """Which tier a model slug belongs to, for the usage breakdown.

    VTO is included: it is not in TIER_SLUGS (it is a tool, not a FLUX tier),
    and without this every try-on was filed under "flex" — so the admin screen
    attributed try-on spend to the cheap tier, which is the one number you would
    use to decide whether try-on is worth its place in the cascade.
    """
    if slug == BFL_MODEL_VTO:
        return VTO_TIER
    for tier, s in TIER_SLUGS.items():
        if s == slug:
            return tier
    return "flex"


def _auth_headers(base: dict) -> dict:
    if BFL_AUTH_HEADER.lower() == "x-key":
        base["X-Key"] = api_key()
    elif BFL_AUTH_SCHEME:
        base[BFL_AUTH_HEADER] = f"{BFL_AUTH_SCHEME} {api_key()}"
    else:
        base[BFL_AUTH_HEADER] = api_key()
    return base


def _safe_error_body(e: BaseException) -> str:
    try:
        if hasattr(e, "read"):
            return e.read().decode(errors="replace")
    except Exception:
        pass
    return str(e)


def _resolve_image_url(payload: dict, slug: str) -> str:
    if not isinstance(payload, dict):
        raise BflError(f"{slug}: unexpected response type {type(payload).__name__}")
    # Async task: {"id": ..., "polling_url": ".../get_result?id=..."}.
    if "id" in payload and "result" not in payload and "url" not in payload and "images" not in payload:
        polling_url = payload.get("polling_url")
        if isinstance(polling_url, str) and polling_url:
            return _poll(polling_url, slug)
        return _poll(f"{BFL_BASE_URL}/get_result?id={payload['id']}", slug)
    result = payload.get("result")
    if isinstance(result, dict) and "sample" in result:
        return result["sample"]
    for key in ("url", "sample"):
        v = payload.get(key)
        if isinstance(v, str) and v:
            return v
    if isinstance(result, str) and result:
        return result
    imgs = payload.get("images")
    if isinstance(imgs, list) and imgs and isinstance(imgs[0], dict):
        url = imgs[0].get("url") or imgs[0].get("sample")
        if isinstance(url, str) and url:
            return url
    raise BflError(f"{slug}: could not find image url in response: {payload}")


def _poll(polling_url: str, slug: str) -> str:
    headers = _auth_headers({"accept": "application/json"})
    deadline = time.monotonic() + BFL_POLL_TIMEOUT_S
    last_err: Exception | None = None
    while time.monotonic() < deadline:
        try:
            req = urllib.request.Request(polling_url, method="GET", headers=headers)
            with urllib.request.urlopen(req, timeout=BFL_CONNECT_TIMEOUT_S) as resp:
                payload = json.loads(resp.read().decode())
        except (urllib.error.HTTPError, urllib.error.URLError) as e:
            last_err = e
            time.sleep(BFL_POLL_INTERVAL_S)
            continue
        status = payload.get("status", "")
        if status == "Ready":
            result = payload.get("result")
            if isinstance(result, dict) and "sample" in result:
                return result["sample"]
            if isinstance(result, str):
                return result
            raise BflError(f"{slug} task Ready but no sample url: {payload}")
        if status in MODERATED_STATUSES:
            # Reported: "certains habits n'arrivent juste pas à s'améliorer avec
            # l'IA … avec tous les modèles". This is why. The documented status
            # enum is Pending / Request Moderated / Content Moderated / Ready /
            # Error, and this loop only knew Ready, Error and "Failed" — a
            # status that does not exist. A moderated job therefore matched
            # nothing, so the loop kept polling a verdict that was already final
            # until the budget ran out, and the user was told it had timed out.
            # Every tier then repeated it on the same image, at the same cost.
            # https://docs.bfl.ml/api-reference/utility/get-result
            raise BflModerated(
                f"{slug}: the provider declined this image ({status}). "
                f"Trying a different model will not change that — a clearer, "
                f"plainer photo of the garment might.")
        if status in ("Error", "Failed"):
            raise BflError(f"{slug} task failed: {payload}")
        time.sleep(BFL_POLL_INTERVAL_S)
    raise BflError(
        f"{slug} task did not finish within {BFL_POLL_TIMEOUT_S}s "
        f"(generation itself is fine, just longer than the poll budget) — last={last_err}"
    )


def _download(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=BFL_UPLOAD_TIMEOUT_S) as resp:
        return resp.read()


def _mock_image(prompt: str, width: int, height: int) -> bytes:
    img = Image.new("RGB", (width, height), (24, 28, 36))
    draw = ImageDraw.Draw(img)
    for y in range(height):
        t = y / max(1, height - 1)
        draw.line([(0, y), (width, y)], fill=(int(40 + 40 * t), int(60 + 30 * t), int(110 - 40 * t)))
    font = None
    for candidate in (
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    ):
        try:
            font = ImageFont.truetype(candidate, 28)
        except Exception:
            continue
    label = "Generated outfit (preview)"
    sub = (prompt or "")[:140] + ("…" if len(prompt or "") > 140 else "")
    if font is None:
        font = ImageFont.load_default()
    draw.text((32, height - 96), label, fill=(255, 255, 255), font=font)
    draw.text((32, height - 56), sub, fill=(220, 220, 220), font=font)
    draw.text((32, 24), "MOCK — set BFL_API_KEY for real renders", fill=(255, 213, 79), font=font)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()