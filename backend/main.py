import logging
import time
from logging.handlers import RotatingFileHandler

from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware
from fastapi.staticfiles import StaticFiles

from config import ALLOW_ORIGINS, IMAGES_DIR, LOGS_DIR, OUTFITS_DIR


def _configure_logging() -> None:
    """Console + rotating file logs (5 files × 5 MB) so activity is retained
    across restarts and can be inspected when something goes wrong."""
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s")
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    if not any(isinstance(h, logging.StreamHandler) for h in root.handlers):
        console = logging.StreamHandler()
        console.setFormatter(fmt)
        root.addHandler(console)
    if not any(isinstance(h, RotatingFileHandler) for h in root.handlers):
        fileh = RotatingFileHandler(
            LOGS_DIR / "dressly.log", maxBytes=5_000_000, backupCount=5,
            encoding="utf-8",
        )
        fileh.setFormatter(fmt)
        root.addHandler(fileh)


_configure_logging()
_req_log = logging.getLogger("dressly.request")

from db import create_tables
from routes_admin import router as admin_router
from routes_agenda import router as agenda_router
from routes_auth import router as auth_router
from routes_autocomplete import router as autocomplete_router
from routes_clothes import router as clothes_router
from routes_models import router as models_router
from routes_notifications import router as notifications_router
from routes_outfits import router as outfits_router
from routes_plan import router as plan_router
from routes_share import router as share_router
from routes_stats import router as stats_router
from routes_weather import router as weather_router
import accesslog
from accesslog import AccessLogMiddleware
from routes_thumbs import CachedStaticFiles
from routes_thumbs import router as thumbs_router

@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Schema creation + migrations + recovery of anything a previous process
    left half-done. Replaces the deprecated @app.on_event("startup")."""
    accesslog.configure(LOGS_DIR)
    create_tables()
    # Anything left mid-flight by the previous process. Outfits already had this
    # sweep; enhancements did not, so a restart during one left it 'processing'
    # for good and the app spun on it forever.
    try:
        from config import ENHANCE_TIMEOUT_S
        from db import fail_stale_enhancements, get_conn, reset_orphan_generations
        with get_conn() as conn:
            reset_orphan_generations(conn)
            fail_stale_enhancements(conn, ENHANCE_TIMEOUT_S)
    except Exception as exc:  # noqa: BLE001 - never block startup on recovery
        logging.getLogger(__name__).warning("startup sweep failed: %s", exc)
    # Count every paid image job from here on.
    try:
        import apiusage
        apiusage.install()
    except Exception as exc:  # noqa: BLE001 - metering is not worth a boot failure
        logging.getLogger(__name__).warning("API metering unavailable: %s", exc)
    # Fetch u2net.onnx now if it is missing: 176 MB downloaded inside somebody's
    # first upload looks exactly like a hung request. Never fatal — the server is
    # useful without background removal, and an offline box should still boot.
    try:
        import images
        images.warm_model()
    except Exception as exc:  # noqa: BLE001 - startup must not depend on this
        logging.getLogger(__name__).warning(
            "background-removal model unavailable: %s", exc)
    yield


app = FastAPI(title="Dressly API", version="1.0", lifespan=lifespan)


class JsonGzipMiddleware:
    """Compress the API's JSON, and only that.

    A wardrobe listing is ~1.8 KB per garment of extremely repetitive JSON —
    the same field names and the same URL prefixes over and over — so 200
    clothes is ~350 KB on the wire, sent again every time a screen that needs
    the wardrobe opens. It compresses about 20x on that shape.

    Images are deliberately excluded: WebP and JPEG are already compressed, so
    gzipping them spends CPU on every photo request to save nothing. Routing by
    path rather than by content type keeps the decision out of the response
    hot path, and those three prefixes are exactly the binary mounts.
    """

    _BINARY_PREFIXES = ("/images", "/generated", "/thumb")

    def __init__(self, app, minimum_size: int = 1024):
        self._plain = app
        self._gzip = GZipMiddleware(app, minimum_size=minimum_size)

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http" and \
                not scope["path"].startswith(self._BINARY_PREFIXES):
            await self._gzip(scope, receive, send)
            return
        await self._plain(scope, receive, send)


app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOW_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Added before the access log, which therefore wraps it and reports the bytes
# that actually went out rather than the size before compression.
app.add_middleware(JsonGzipMiddleware)


def _email_from_request(request: Request) -> str:
    """Best-effort user identity for the request log (decode the bearer token)."""
    auth = request.headers.get("authorization", "")
    if not auth.lower().startswith("bearer "):
        return "-"
    try:
        from auth import _decode
        return _decode(auth.split(" ", 1)[1]).get("email", "-")
    except Exception:
        return "-"


@app.middleware("http")
async def log_requests(request: Request, call_next):
    """Application actions, with the user attached.

    Images are left to the access log: there are dozens per screen and they
    would bury everything else. Note this timer stops when the handler returns,
    which for a JSON response is the whole story and for a file response is not
    — see accesslog.py.
    """
    path = request.url.path
    quiet = path.startswith(("/images", "/generated", "/thumb")) or \
        path == "/health"
    start = time.monotonic()
    try:
        response = await call_next(request)
    except Exception:
        dur = (time.monotonic() - start) * 1000
        _req_log.exception("%s %s -> 500 %.0fms user=%s",
                           request.method, path, dur, _email_from_request(request))
        raise
    if not quiet:
        dur = (time.monotonic() - start) * 1000
        level = logging.WARNING if response.status_code >= 400 else logging.INFO
        _req_log.log(level, "%s %s -> %s %.0fms user=%s",
                     request.method, path, response.status_code, dur,
                     _email_from_request(request))
    return response


# Outermost: wraps everything above so its timer covers the response body too.
app.add_middleware(AccessLogMiddleware, app_log=_req_log)


# Static mounts first so path-shaped routes don't get shadowed by the
# `/outfits/...` and `/images/...` routers below. Generated outfit images live
# under /generated (not /outfits) precisely so the /outfits/{id} JSON route
# isn't shadowed.
class _ImagesStatic(CachedStaticFiles, StaticFiles):
    """StaticFiles for /images: immutable caching + signature check."""

    sign_root = "images"


class _GeneratedStatic(CachedStaticFiles, StaticFiles):
    """Same, for the generated outfit renders."""

    sign_root = "generated"


app.mount("/images", _ImagesStatic(directory=str(IMAGES_DIR)), name="images")
app.mount("/generated", _GeneratedStatic(directory=str(OUTFITS_DIR)),
          name="generated")

app.include_router(auth_router)
app.include_router(autocomplete_router)
app.include_router(clothes_router)
app.include_router(models_router)
app.include_router(notifications_router)
app.include_router(share_router)
app.include_router(outfits_router)
app.include_router(plan_router)
app.include_router(agenda_router)
app.include_router(admin_router)
app.include_router(stats_router)
app.include_router(weather_router)
app.include_router(thumbs_router)


@app.get("/health")
def health():
    return {"ok": True}