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

# --- rate limits ----------------------------------------------------------
# Outfit generation and AI enhance are billed per call by bfl.ai, so a stuck
# client must not be able to loop on them. Counted per user, in-process.
# Set a limit to 0 to disable that bucket.
#
# Deliberately high: the owner is the only user, so these exist to stop a
# runaway loop (a retry storm, a stuck client polling generate), not to ration
# a legitimate afternoon of trying outfits. Anything a human does by hand stays
# far below them.
GENERATION_RATE_LIMIT = int(os.environ.get("CLOTHESAPP_GEN_RATE_LIMIT", "600"))
GENERATION_RATE_WINDOW_S = int(os.environ.get("CLOTHESAPP_GEN_RATE_WINDOW_S", "3600"))
ENHANCE_RATE_LIMIT = int(os.environ.get("CLOTHESAPP_ENHANCE_RATE_LIMIT", "600"))
ENHANCE_RATE_WINDOW_S = int(os.environ.get("CLOTHESAPP_ENHANCE_RATE_WINDOW_S", "3600"))

# Sign-in and sign-up, counted per IP because there is no user yet. Without
# these, a password can be guessed as fast as the network allows.
# Two budgets: one on attempts (generous, catches scripted floods) and a
# tighter one on *failures* (catches a word-list run without punishing someone
# mistyping their own password).
AUTH_RATE_LIMIT = int(os.environ.get("CLOTHESAPP_AUTH_RATE_LIMIT", "30"))
AUTH_RATE_WINDOW_S = int(os.environ.get("CLOTHESAPP_AUTH_RATE_WINDOW_S", "900"))
AUTH_FAIL_RATE_LIMIT = int(os.environ.get("CLOTHESAPP_AUTH_FAIL_LIMIT", "10"))
AUTH_FAIL_WINDOW_S = int(os.environ.get("CLOTHESAPP_AUTH_FAIL_WINDOW_S", "900"))

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
# Slotted into the outfit cascade after flex and skipped when no model is
# available. The slug is the endpoint path under BFL_BASE_URL.
#
# v2 since 2026-07: identical request shape to v1, with reference and output
# resolution supported up to 4 MP instead of ~1 MP. Same body, same response —
# nothing but the path changes.
# https://docs.bfl.ml/api-reference/models/virtual-try-on-v2
BFL_MODEL_VTO = os.environ.get("BFL_MODEL_VTO", "flux-tools/vto-v2")
BFL_POLL_TIMEOUT_S = int(os.environ.get("BFL_POLL_TIMEOUT_S", "60"))
BFL_POLL_INTERVAL_S = float(os.environ.get("BFL_POLL_INTERVAL_S", "2"))
# Connect/read timeout per HTTP call. A dead/wrong endpoint should fail fast
# (this is what surfaces as "timed out" when BFL_BASE_URL can't be reached).
BFL_CONNECT_TIMEOUT_S = float(os.environ.get("BFL_CONNECT_TIMEOUT_S", "12"))
# Submit (POST) includes uploading base64 images, so it gets a longer budget
# than a plain poll GET.
# One POST carrying the base64 reference images. 60 s is already generous for
# the ~1-2 MB that is (BFL_IMAGE_MAX_PX caps each side at 1024), and the figure
# has to stay under the budgets below — see the chain in ENHANCE_TIMEOUT_S.
BFL_UPLOAD_TIMEOUT_S = float(os.environ.get("BFL_UPLOAD_TIMEOUT_S", "60"))
# Downscale reference images to this max dimension before base64-encoding, to
# keep uploads fast and the user's input_mp cost down.
BFL_IMAGE_MAX_PX = int(os.environ.get("BFL_IMAGE_MAX_PX", "1024"))
# How tolerant the provider's input/output moderation is, 0 (strictest) to 5.
# Their default is 2 and that is kept — raising it is a policy decision for
# whoever runs the server, not a default to change quietly. It is the lever for
# the case where an ordinary photo of a garment keeps coming back refused.
# https://docs.bfl.ml/api-reference/models/virtual-try-on-v2
BFL_SAFETY_TOLERANCE = max(0, min(5, int(
    os.environ.get("BFL_SAFETY_TOLERANCE", "2"))))
# Try-on (VTO) reference images get a larger cap than the FLUX render tiers: the
# VTO output follows the person image's resolution, so a bigger person/garment
# input yields a higher-detail result. Falls back to BFL_IMAGE_MAX_PX.
BFL_VTO_IMAGE_MAX_PX = int(os.environ.get("BFL_VTO_IMAGE_MAX_PX", "1280"))
# Ask the VTO endpoint to upsample the prompt for extra detail/realism.
#
# OFF by default now, and the default is the honest one: neither vto-v1 nor
# vto-v2 has a prompt_upsampling field — both take Flux2KleinTryonInputs, whose
# schema is prompt / person / garment / seed / safety_tolerance / output_format
# / webhook_*. Sending it meant every try-on submitted twice: once rejected for
# an unknown field, once accepted. The retry path is kept for a slug that does
# accept it, but nothing is spent probing for it any more.
# https://docs.bfl.ml/api-reference/models/virtual-try-on-v2
BFL_VTO_PROMPT_UPSAMPLING = os.environ.get(
    "BFL_VTO_PROMPT_UPSAMPLING", "0").strip().lower() not in ("0", "false", "")
# Auth header bfl expects. bfl.ai historically uses "X-Key"; newer endpoints
# may use "Authorization: Bearer". Set BFL_AUTH_HEADER=Authorization and
# BFL_AUTH_SCHEME=Bearer to switch. When BFL_AUTH_HEADER is "X-Key" the key
# is sent verbatim; otherwise it's sent as "<scheme> <key>".
BFL_AUTH_HEADER = os.environ.get("BFL_AUTH_HEADER", "X-Key")
BFL_AUTH_SCHEME = os.environ.get("BFL_AUTH_SCHEME", "")  # "" or "Bearer"

# How long an image enhancement may run before it is called failed.
#
# Reported: "j'ai lance l'amelioration d'image pour un short et ca fait 2 mins
# que ca charge". The cascade tries flex, then pro, then max, and each attempt
# can spend the submit budget plus the poll budget — several minutes in total,
# with somebody watching a spinner that has no end. Two guards now: the cascade
# stops starting new tiers past ENHANCE_DEADLINE_S, and any job still marked
# 'processing' after ENHANCE_TIMEOUT_S is reported as failed (which also
# recovers rows whose worker died with a server restart).
# These three have to hold in this order, and they did not:
#
#   one attempt  <= BFL_UPLOAD_TIMEOUT_S + BFL_POLL_TIMEOUT_S   (60 + 60 = 120s)
#   ENHANCE_DEADLINE_S  (90s)  stops the cascade STARTING another tier
#   ENHANCE_TIMEOUT_S  (180s)  declares a job that is no longer running failed
#
# With the old submit budget of 120 s, one legitimate attempt could take 180 s —
# exactly the sweep threshold — so a job still working could be reported as
# stalled while it was mid-flight, and the deadline could never stop a second
# tier because the first alone outlasted it. The sweep must sit above the
# longest honest run, not inside it.
ENHANCE_DEADLINE_S = float(os.environ.get("CLOTHESAPP_ENHANCE_DEADLINE_S", "90"))
ENHANCE_TIMEOUT_S = float(os.environ.get("CLOTHESAPP_ENHANCE_TIMEOUT_S", "180"))


# --- image safety ---------------------------------------------------------
# Pillow only *warns* below ~89 megapixels and raises above ~178. A file in
# that band passes upload and then costs 4 bytes/pixel the moment anything
# converts it to RGBA (thumbnails do) — hundreds of MB of RSS per request.
# ORIGINAL_MAX_PX is 4000, so a legitimate photo is at most ~16 MP; 40 leaves
# room for panoramas without leaving the door open.
MAX_IMAGE_MEGAPIXELS = float(os.environ.get("CLOTHESAPP_MAX_IMAGE_MP", "40"))

# Outfit rendering shares the enhancement reasoning: the deadline stops the
# cascade from STARTING another tier, it never aborts one in flight. Four
# tiers x (upload + poll) is ~8 minutes otherwise, with the app polling a
# spinner the whole time.
GENERATE_DEADLINE_S = float(os.environ.get("CLOTHESAPP_GENERATE_DEADLINE_S", "150"))

# Background removal is ~5 s a photo on the deployment box, and several can
# queue behind each other. Past this, the job is not slow, it is gone: its
# process died and nothing will ever finish it.
CUTOUT_TIMEOUT_S = float(os.environ.get("CLOTHESAPP_CUTOUT_TIMEOUT_S", "600"))

# Page-size ceiling for the list endpoints. Single-user server, so this is not
# rationing: it exists so a bug (or a client looping with limit=1e9) cannot ask
# the server to build one enormous response and hold it in RAM. 5000 rows is
# more than ten times the current wardrobe, and the app never asks for more
# than a screenful at a time.
MAX_PAGE_SIZE = int(os.environ.get("CLOTHESAPP_MAX_PAGE_SIZE", "5000"))
