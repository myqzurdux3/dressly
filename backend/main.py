import logging
import time
from logging.handlers import RotatingFileHandler

from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
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
from routes_agenda import router as agenda_router
from routes_auth import router as auth_router
from routes_autocomplete import router as autocomplete_router
from routes_clothes import router as clothes_router
from routes_models import router as models_router
from routes_notifications import router as notifications_router
from routes_outfits import router as outfits_router
from routes_stats import router as stats_router
from routes_thumbs import CachedStaticFiles
from routes_thumbs import router as thumbs_router

@asynccontextmanager
async def lifespan(_app: FastAPI):
    """Schema creation + migrations + recovery of anything a previous process
    left half-done. Replaces the deprecated @app.on_event("startup")."""
    create_tables()
    yield


app = FastAPI(title="Dressly API", version="1.0", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=ALLOW_ORIGINS,
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)


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
    # Skip static assets + health to keep the log about user actions.
    path = request.url.path
    noisy = path.startswith(("/images", "/generated")) or path == "/health"
    start = time.monotonic()
    try:
        response = await call_next(request)
    except Exception:
        dur = (time.monotonic() - start) * 1000
        _req_log.exception("%s %s -> 500 %.0fms user=%s",
                           request.method, path, dur, _email_from_request(request))
        raise
    if not noisy:
        dur = (time.monotonic() - start) * 1000
        level = logging.WARNING if response.status_code >= 400 else logging.INFO
        _req_log.log(level, "%s %s -> %s %.0fms user=%s",
                     request.method, path, response.status_code, dur,
                     _email_from_request(request))
    return response


# Static mounts first so path-shaped routes don't get shadowed by the
# `/outfits/...` and `/images/...` routers below. Generated outfit images live
# under /generated (not /outfits) precisely so the /outfits/{id} JSON route
# isn't shadowed.
class _ImmutableStatic(CachedStaticFiles, StaticFiles):
    """StaticFiles that tags responses as immutable (URLs carry ?v=<mtime>)."""


app.mount("/images", _ImmutableStatic(directory=str(IMAGES_DIR)), name="images")
app.mount("/generated", _ImmutableStatic(directory=str(OUTFITS_DIR)), name="generated")

app.include_router(auth_router)
app.include_router(autocomplete_router)
app.include_router(clothes_router)
app.include_router(models_router)
app.include_router(notifications_router)
app.include_router(outfits_router)
app.include_router(agenda_router)
app.include_router(stats_router)
app.include_router(thumbs_router)


@app.get("/health")
def health():
    return {"ok": True}