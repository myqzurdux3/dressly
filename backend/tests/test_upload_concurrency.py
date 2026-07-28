"""Uploads must not block the event loop nor hold the SQLite write lock.

Background removal is seconds of ONNX inference. Running it inside an `async def`
handler froze every other request; running it inside the surrounding transaction
made concurrent writers fail with "database is locked". Both are regressions
worth pinning.
"""
import sqlite3
import threading

import pytest

import db
import routes_clothes
from tests.conftest import create_cloth, make_png


@pytest.fixture()
def cloth_with_image(client, auth):
    return create_cloth(client, auth)


def test_heavy_work_runs_off_the_event_loop(client, auth, monkeypatch):
    """The handler is `async def`, so anything CPU-bound it calls directly runs
    on the event loop thread and stalls the whole server."""
    threads = []
    original = routes_clothes.remove_background

    def spy(src, dst, tolerance="medium"):
        threads.append(threading.current_thread())
        return original(src, dst, tolerance)

    monkeypatch.setattr(routes_clothes, "remove_background", spy)
    create_cloth(client, auth)

    assert threads, "background removal never ran"
    main = threading.main_thread()
    assert all(t is not main for t in threads), (
        "background removal ran on the main/event-loop thread"
    )


def test_upload_does_not_hold_the_write_lock(client, auth, monkeypatch):
    """While a photo is being processed, an unrelated writer must still get in.

    The probe uses a 1s timeout: if the upload's transaction were still open,
    SQLite would block for it and raise OperationalError instead.
    """
    probe = {"ok": None, "error": None}
    original = routes_clothes.remove_background

    def spy(src, dst, tolerance="medium"):
        if probe["ok"] is None:  # only probe on the first image
            try:
                conn = sqlite3.connect(db.DB_PATH, timeout=1)
                try:
                    conn.execute("PRAGMA busy_timeout = 1000")
                    conn.execute(
                        "INSERT INTO audit_log (action, detail) VALUES (?, ?)",
                        ("probe.write", "written mid-upload"),
                    )
                    conn.commit()
                    probe["ok"] = True
                finally:
                    conn.close()
            except sqlite3.OperationalError as e:
                probe["ok"] = False
                probe["error"] = str(e)
        return original(src, dst, tolerance)

    monkeypatch.setattr(routes_clothes, "remove_background", spy)
    create_cloth(client, auth)

    assert probe["ok"] is True, f"write lock held during upload: {probe['error']}"


def test_failed_processing_leaves_no_half_created_cloth(client, auth, monkeypatch):
    """If encoding blows up, the wardrobe must not gain a cloth with no photos."""
    def boom(*a, **kw):
        raise RuntimeError("encoder exploded")

    monkeypatch.setattr(routes_clothes, "_stage_uploads", boom)
    before = client.get("/clothes", headers=auth).json()
    with pytest.raises(RuntimeError):
        client.post(
            "/clothes",
            headers=auth,
            data={"name": "Ghost", "category": "tshirt", "cut": "normal"},
            files=[
                ("images", ("f.png", make_png(), "image/png")),
                ("images", ("b.png", make_png((0, 0, 200)), "image/png")),
            ],
        )
    after = client.get("/clothes", headers=auth).json()
    assert len(after) == len(before)


def test_staging_dir_is_cleaned_up(client, auth):
    from config import STAGING_DIR

    create_cloth(client, auth)
    leftovers = [p for p in STAGING_DIR.iterdir()] if STAGING_DIR.exists() else []
    assert leftovers == [], f"staging not cleaned: {leftovers}"


def test_add_image_is_processed_off_the_loop(client, auth, cloth_with_image,
                                             monkeypatch):
    threads = []
    original = routes_clothes.remove_background

    def spy(src, dst, tolerance="medium"):
        threads.append(threading.current_thread())
        return original(src, dst, tolerance)

    monkeypatch.setattr(routes_clothes, "remove_background", spy)
    r = client.post(
        f"/clothes/{cloth_with_image['id']}/images",
        headers=auth,
        data={"role": "extra"},
        files={"image": ("e.png", make_png((0, 200, 0)), "image/png")},
    )
    assert r.status_code == 200, r.text
    assert threads and all(t is not threading.main_thread() for t in threads)


def test_replace_image_keeps_the_row_pointing_at_a_real_file(
        client, auth, cloth_with_image):
    img = cloth_with_image["images"][0]
    r = client.put(
        f"/clothes/{cloth_with_image['id']}/images/{img['id']}",
        headers=auth,
        files={"image": ("new.png", make_png((5, 5, 240)), "image/png")},
    )
    assert r.status_code == 200, r.text
    with db.get_conn() as conn:
        row = conn.execute(
            "SELECT original_path, cutout_path FROM cloth_images WHERE id = ?",
            (img["id"],),
        ).fetchone()
    from pathlib import Path
    assert Path(row["original_path"]).exists()
    assert Path(row["cutout_path"]).exists()
