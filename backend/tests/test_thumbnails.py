"""On-demand thumbnails: correctness, caching, and path safety."""
import io

from PIL import Image

import routes_thumbs
from tests.conftest import create_cloth


def _thumb_path_of(cloth):
    """The /thumb/... URL the API advertises for a cloth's first image."""
    url = cloth["images"][0]["thumb_url"]
    assert url, "no thumb_url returned"
    return url


def test_cloth_response_advertises_a_thumbnail(client, auth):
    c = create_cloth(client, auth)
    url = _thumb_path_of(c)
    assert url.startswith("/thumb/images/400/")
    assert "?v=" in url, "thumbnail URL must be cache-busted like the full image"


def test_thumbnail_is_served_and_downscaled(client, auth):
    c = create_cloth(client, auth)
    r = client.get(_thumb_path_of(c))
    assert r.status_code == 200, r.text
    assert r.headers["content-type"] == "image/webp"
    with Image.open(io.BytesIO(r.content)) as im:
        assert im.width <= 400


def test_thumbnail_is_smaller_than_the_full_image(client, auth):
    """A big source is the case that matters — the fixture's 32px PNG would not
    prove anything, so upload something grid-sized first."""
    buf = io.BytesIO()
    Image.new("RGB", (2000, 2000), (30, 90, 200)).save(buf, "PNG")
    big = buf.getvalue()
    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Big", "category": "tshirt", "cut": "normal"},
        files=[("images", ("f.png", big, "image/png")),
               ("images", ("b.png", big, "image/png"))],
    )
    assert r.status_code == 200, r.text
    c = r.json()
    full = client.get(c["images"][0]["cutout_url"])
    thumb = client.get(c["images"][0]["thumb_url"])
    assert thumb.status_code == 200 and full.status_code == 200
    assert len(thumb.content) < len(full.content)


def test_thumbnail_is_cached_on_disk_and_reused(client, auth):
    from config import THUMBS_DIR

    c = create_cloth(client, auth)
    url = _thumb_path_of(c)
    assert client.get(url).status_code == 200
    cached = list(THUMBS_DIR.rglob("*.webp"))
    assert cached, "nothing was cached"
    mtimes = {p: p.stat().st_mtime_ns for p in cached}
    assert client.get(url).status_code == 200
    assert {p: p.stat().st_mtime_ns for p in cached} == mtimes, "regenerated needlessly"


def test_thumbnail_marked_immutable(client, auth):
    c = create_cloth(client, auth)
    r = client.get(_thumb_path_of(c))
    assert "immutable" in r.headers.get("cache-control", "")


def test_static_images_marked_immutable(client, auth):
    c = create_cloth(client, auth)
    r = client.get(c["images"][0]["cutout_url"])
    assert r.status_code == 200
    assert "immutable" in r.headers.get("cache-control", "")


def test_only_whitelisted_widths_are_generated(client, auth):
    c = create_cloth(client, auth)
    rel = _thumb_path_of(c).split("/400/", 1)[1].split("?")[0]
    assert client.get(f"/thumb/images/400/{rel}").status_code == 200
    # An arbitrary width would let a caller fill the disk with variants.
    assert client.get(f"/thumb/images/377/{rel}").status_code == 400


def test_path_traversal_is_refused(client):
    for attempt in (
        "/thumb/images/400/../../../etc/passwd",
        "/thumb/images/400/..%2f..%2fdata.db",
        "/thumb/images/400/nope/missing.png",
    ):
        r = client.get(attempt)
        assert r.status_code in (307, 400, 404), f"{attempt} -> {r.status_code}"
        assert b"root:" not in r.content


def test_unknown_root_is_refused(client):
    assert client.get("/thumb/blobs/400/ab/whatever.jpg").status_code == 404


def test_safe_source_rejects_escapes(tmp_path, monkeypatch):
    """Unit-level check of the guard, independent of the router's URL parsing."""
    import pytest
    from fastapi import HTTPException

    secret = tmp_path / "secret.txt"
    secret.write_text("nope")
    root = tmp_path / "images"
    root.mkdir()
    monkeypatch.setitem(routes_thumbs._ROOTS, "images", root)
    with pytest.raises(HTTPException):
        routes_thumbs._safe_source("images", "../secret.txt")


def test_stale_thumbnail_is_regenerated_after_the_source_changes(client, auth):
    import os
    import time

    from config import THUMBS_DIR

    c = create_cloth(client, auth)
    url = _thumb_path_of(c)
    assert client.get(url).status_code == 200
    cached = next(iter(THUMBS_DIR.rglob("*.webp")))
    before = cached.stat().st_mtime_ns

    # Touch the source into the future, as a crop/redo-bg rewrite would.
    src = c["images"][0]["cutout_url"].split("?")[0].replace("/images/", "", 1)
    from config import IMAGES_DIR
    real = IMAGES_DIR / src
    future = time.time() + 5
    os.utime(real, (future, future))

    assert client.get(url).status_code == 200
    assert cached.stat().st_mtime_ns != before, "stale thumbnail was served"
