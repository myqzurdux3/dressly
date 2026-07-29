"""Shared pytest fixtures.

Isolation + no external I/O:
  * a throwaway data dir is set BEFORE the app modules import config, so the
    real backend/data/ is never touched;
  * BFL is forced into dry-run (no network) — even though the app currently
    ships a hardcoded key, tests must never call the real API;
  * background removal is stubbed with a cheap copy so the suite doesn't need
    the rembg model and stays fast + deterministic;
  * each test gets a fresh SQLite file.
"""
import os
import tempfile

# Must run before importing config/main (they read env at import time).
os.environ.setdefault("CLOTHESAPP_DATA_DIR", tempfile.mkdtemp(prefix="dressly_test_"))
os.environ["BFL_API_KEY"] = ""  # force dry-run

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

import bfl  # noqa: E402
import db  # noqa: E402
import main  # noqa: E402

# Belt-and-suspenders: never reach the real BFL API from tests.
bfl.DEFAULT_API_KEY = ""


@pytest.fixture(autouse=True)
def fresh_rate_limits(fresh_db):
    """Counters now live in the DB, which fresh_db recreates per test, so this
    mainly guards the ordering: it must run AFTER the schema exists."""
    import ratelimit

    ratelimit.reset()
    yield


@pytest.fixture(autouse=True)
def fresh_db(tmp_path, monkeypatch):
    """Point the DB at a fresh per-test file and create the schema."""
    monkeypatch.setattr(db, "DB_PATH", str(tmp_path / "test.db"))
    main.create_tables()
    yield


@pytest.fixture(autouse=True)
def fast_bg(monkeypatch):
    """Replace rembg with a trivial copy so uploads are fast + offline."""
    from PIL import Image

    def fake_remove_background(src, dst, tolerance="medium"):
        Image.open(src).convert("RGBA").save(dst, "PNG")
        return dst

    import routes_clothes

    monkeypatch.setattr(routes_clothes, "remove_background", fake_remove_background)
    yield


@pytest.fixture()
def client():
    return TestClient(main.app)


@pytest.fixture()
def auth(client):
    """A signed-up user's bearer header."""
    r = client.post(
        "/auth/signup", json={"email": "u@test.co", "password": "pw123456"}
    )
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


# --- small helpers reused across tests ---

def make_png(color=(200, 30, 30), size=(32, 32)) -> bytes:
    import io

    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, "PNG")
    return buf.getvalue()


def wait_done(client, auth, outfit_id, tries=200):
    """Poll an outfit until it leaves 'processing' (generation now runs as a
    background task)."""
    import time

    for _ in range(tries):
        o = client.get(f"/outfits/{outfit_id}", headers=auth).json()
        if o.get("status") != "processing":
            return o
        time.sleep(0.02)
    return o


def gen_outfit(client, auth, cloth_ids, **extra):
    body = {"cloth_ids": cloth_ids}
    body.update(extra)
    r = client.post("/outfits/generate", headers=auth, json=body)
    assert r.status_code == 200, r.text
    return wait_done(client, auth, r.json()["id"])


def create_cloth(client, auth, name="Tee", category="tshirt", colors=None):
    import json as _json

    data = {"name": name, "category": category, "cut": "normal"}
    if colors:
        data["colors"] = _json.dumps(colors)
    r = client.post(
        "/clothes",
        headers=auth,
        data=data,
        files=[
            ("images", ("f.png", make_png((200, 0, 0)), "image/png")),
            ("images", ("b.png", make_png((0, 0, 200)), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    return r.json()
