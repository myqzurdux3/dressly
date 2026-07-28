import os
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
# Data dir is env-overridable: tests can point at a throwaway DB without ever
# touching the real one (which is the only `backend/data/` on this machine).
_DATA_DIR_ENV = os.environ.get("CLOTHESAPP_DATA_DIR", "").strip()
DATA_DIR = Path(_DATA_DIR_ENV) if _DATA_DIR_ENV else BASE_DIR / "data"
IMAGES_DIR = DATA_DIR / "images"
OUTFITS_DIR = DATA_DIR / "outfits"
LOGS_DIR = DATA_DIR / "logs"
# Content-addressed store backing the per-cloth image files. Identical uploads
# (the same photo added to two clothes) share one inode via a hard link, so the
# bytes are stored once. Deliberately NOT under IMAGES_DIR — that directory is
# mounted as public static files and blobs must not be listable there.
BLOBS_DIR = DATA_DIR / "blobs"
# Uploads are encoded here first, then moved into place once the DB row exists.
# Same filesystem as IMAGES_DIR so the move is an atomic rename, not a copy.
STAGING_DIR = DATA_DIR / "staging"
# Derived, disposable resize cache for the grid thumbnails. Safe to delete.
THUMBS_DIR = DATA_DIR / "thumbs"
DATA_DIR.mkdir(parents=True, exist_ok=True)
IMAGES_DIR.mkdir(parents=True, exist_ok=True)
OUTFITS_DIR.mkdir(parents=True, exist_ok=True)
LOGS_DIR.mkdir(parents=True, exist_ok=True)
BLOBS_DIR.mkdir(parents=True, exist_ok=True)
STAGING_DIR.mkdir(parents=True, exist_ok=True)
THUMBS_DIR.mkdir(parents=True, exist_ok=True)

# Absolute, stable path so the DB is the same file regardless of cwd.
DB_PATH = str(DATA_DIR / "data.db")

# Deployment mode. "dev" keeps the permissive local defaults below; anything
# else ("prod", "staging", ...) is treated as a real deployment and the unsafe
# defaults become hard startup errors instead of silent footguns.
ENV = os.environ.get("CLOTHESAPP_ENV", "dev").strip().lower()
IS_DEV = ENV == "dev"

# Secret used to sign JWTs. MUST be overridden via CLOTHESAPP_SECRET outside
# dev — with the shipped default anyone can forge an admin token.
_DEV_SECRET = "dev-secret-change-me"
SECRET_KEY = os.environ.get("CLOTHESAPP_SECRET", "").strip() or _DEV_SECRET
JWT_ALG = "HS256"
JWT_TTL_HOURS = 24 * 30  # 30 days

# CORS — Flutter web/dev clients. "*" is fine for local dev only.
ALLOW_ORIGINS = [
    o.strip() for o in os.environ.get("CLOTHESAPP_CORS", "*").split(",") if o.strip()
]


class ConfigError(RuntimeError):
    """Raised at import time when a production deployment is misconfigured."""


def _check_production_config() -> None:
    """Fail fast rather than boot a deployment that is trivially compromised.

    Only enforced when CLOTHESAPP_ENV != "dev", so local runs and the test
    suite keep working with no environment set up at all.
    """
    if IS_DEV:
        return
    problems = []
    if SECRET_KEY == _DEV_SECRET:
        problems.append(
            "CLOTHESAPP_SECRET is unset (still the shipped dev value) — JWTs "
            "signed with it are forgeable by anyone reading the source."
        )
    elif len(SECRET_KEY.encode("utf-8")) < 32:
        problems.append(
            f"CLOTHESAPP_SECRET is only {len(SECRET_KEY.encode('utf-8'))} bytes; "
            "HS256 needs at least 32. Generate one with "
            "`python -c \"import secrets; print(secrets.token_urlsafe(48))\"`."
        )
    if "*" in ALLOW_ORIGINS:
        problems.append(
            "CLOTHESAPP_CORS is '*' — set it to the explicit comma-separated "
            "list of origins the app is served from."
        )
    if problems:
        raise ConfigError(
            f"Refusing to start with CLOTHESAPP_ENV={ENV!r}:\n  - "
            + "\n  - ".join(problems)
        )


_check_production_config()

# rembg model. "u2net" is the default and a good general-purpose choice.
REMBG_MODEL = os.environ.get("CLOTHESAPP_REMBG_MODEL", "u2net")

# --- rate limits ----------------------------------------------------------
# Outfit generation and AI enhance are billed per call by bfl.ai, so a stuck
# client must not be able to loop on them. Counted per user, in-process.
# Set a limit to 0 to disable that bucket.
GENERATION_RATE_LIMIT = int(os.environ.get("CLOTHESAPP_GEN_RATE_LIMIT", "30"))
GENERATION_RATE_WINDOW_S = int(os.environ.get("CLOTHESAPP_GEN_RATE_WINDOW_S", "3600"))
ENHANCE_RATE_LIMIT = int(os.environ.get("CLOTHESAPP_ENHANCE_RATE_LIMIT", "40"))
ENHANCE_RATE_WINDOW_S = int(os.environ.get("CLOTHESAPP_ENHANCE_RATE_WINDOW_S", "3600"))

# --- Admin alerting -------------------------------------------------------
# When a user reports a bad background removal or a bad/failed generation, the
# event is always stored in the DB (notifications / outfit_reports) AND pushed
# in real time through whichever channel below is configured. All are optional;
# with none set the alert is just logged to the server console.
#
# Admin allowlist: emails that may read the manager-only endpoints
# (/notifications, /notifications/reports). Comma-separated. A user is also an
# admin if their DB row has is_admin=1.
ADMIN_EMAILS = {
    e.strip().lower()
    for e in os.environ.get("DRESSLY_ADMIN_EMAILS", "").split(",")
    if e.strip()
}

# Simplest: a Slack/Discord-compatible incoming webhook (no mail server). If
# set, alerts are POSTed as {"text": ...}.
ADMIN_WEBHOOK_URL = os.environ.get("DRESSLY_ADMIN_WEBHOOK", "").strip()
# Email (SMTP). Set host + admin address (+ credentials if the server needs them).
ADMIN_EMAIL = os.environ.get("DRESSLY_ADMIN_EMAIL", "").strip()
SMTP_HOST = os.environ.get("SMTP_HOST", "").strip()
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "").strip()
SMTP_PASSWORD = os.environ.get("SMTP_PASSWORD", "").strip()
SMTP_FROM = os.environ.get("SMTP_FROM", "").strip() or SMTP_USER or ADMIN_EMAIL
SMTP_USE_TLS = os.environ.get("SMTP_USE_TLS", "1") != "0"

# Black Forest Labs (bfl.ai) image generation. The API key is read directly
# from the BFL_API_KEY env var in bfl.py (never hardcoded in source); with no
# key the server runs in DRY_RUN mode and returns placeholder images.
BFL_BASE_URL = os.environ.get("BFL_BASE_URL", "https://api.bfl.ai/v1")
# Cascade order, cheap -> expensive (FLUX 2 family, multi-image). Each slug is
# env-configurable to match the exact endpoints bfl exposes.
#   flex (fast/cheap) -> pro (balanced) -> max (best; fallback when pro fails)
BFL_MODEL_FLEX = os.environ.get("BFL_MODEL_FLEX", "flux-2-klein-4b")
BFL_MODEL_PRO = os.environ.get("BFL_MODEL_PRO", "flux-2-pro")
BFL_MODEL_MAX = os.environ.get("BFL_MODEL_MAX", "flux-2-max")
# FLUX Virtual Try-On (VTO). Highest-quality path for outfit generation, but it
# REQUIRES a person image (the model) — it renders the garment onto that person.
# Prepended to the outfit cascade (vto -> flex -> pro -> max) and skipped when no
# model is available. The slug is the endpoint path under BFL_BASE_URL.
BFL_MODEL_VTO = os.environ.get("BFL_MODEL_VTO", "flux-tools/vto-v1")
# Back-compat alias for the previous mid tier name.
BFL_MODEL_FLUX = os.environ.get("BFL_MODEL_FLUX", BFL_MODEL_PRO)
BFL_POLL_TIMEOUT_S = int(os.environ.get("BFL_POLL_TIMEOUT_S", "60"))
BFL_POLL_INTERVAL_S = float(os.environ.get("BFL_POLL_INTERVAL_S", "2"))
# Connect/read timeout per HTTP call. A dead/wrong endpoint should fail fast
# (this is what surfaces as "timed out" when BFL_BASE_URL can't be reached).
BFL_CONNECT_TIMEOUT_S = float(os.environ.get("BFL_CONNECT_TIMEOUT_S", "12"))
# Submit (POST) includes uploading base64 images, so it gets a longer budget
# than a plain poll GET.
BFL_UPLOAD_TIMEOUT_S = float(os.environ.get("BFL_UPLOAD_TIMEOUT_S", "120"))
# Downscale reference images to this max dimension before base64-encoding, to
# keep uploads fast and the user's input_mp cost down.
BFL_IMAGE_MAX_PX = int(os.environ.get("BFL_IMAGE_MAX_PX", "1024"))
# Try-on (VTO) reference images get a larger cap than the FLUX render tiers: the
# VTO output follows the person image's resolution, so a bigger person/garment
# input yields a higher-detail result. Falls back to BFL_IMAGE_MAX_PX.
BFL_VTO_IMAGE_MAX_PX = int(os.environ.get("BFL_VTO_IMAGE_MAX_PX", "1280"))
# Ask the VTO endpoint to upsample the prompt for extra detail/realism. If the
# configured vto slug rejects this field (400), set BFL_VTO_PROMPT_UPSAMPLING=0
# — the request will then submit without it instead of the cascade skipping VTO.
BFL_VTO_PROMPT_UPSAMPLING = os.environ.get(
    "BFL_VTO_PROMPT_UPSAMPLING", "1").strip().lower() not in ("0", "false", "")
# Auth header bfl expects. bfl.ai historically uses "X-Key"; newer endpoints
# may use "Authorization: Bearer". Set BFL_AUTH_HEADER=Authorization and
# BFL_AUTH_SCHEME=Bearer to switch. When BFL_AUTH_HEADER is "X-Key" the key
# is sent verbatim; otherwise it's sent as "<scheme> <key>".
BFL_AUTH_HEADER = os.environ.get("BFL_AUTH_HEADER", "X-Key")
BFL_AUTH_SCHEME = os.environ.get("BFL_AUTH_SCHEME", "")  # "" or "Bearer"
