"""On-demand thumbnails: correctness, caching, and path safety."""
import io
from pathlib import Path

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
    # This image's own cached file. Taking whatever rglob yielded first used to
    # work when one thumbnail existed; pre-warming renders several, and the
    # arbitrary one belonged to another photo.
    rel = url.split("/thumb/images/400/", 1)[1].split("?")[0]
    cached = THUMBS_DIR / "400" / "images" / (rel + ".webp")
    assert cached.is_file(), cached
    before = cached.stat().st_mtime_ns

    # Touch the source into the future, as a crop/redo-bg rewrite would.
    src = c["images"][0]["cutout_url"].split("?")[0].replace("/images/", "", 1)
    from config import IMAGES_DIR
    real = IMAGES_DIR / src
    future = time.time() + 5
    os.utime(real, (future, future))

    assert client.get(url).status_code == 200
    assert cached.stat().st_mtime_ns != before, "stale thumbnail was served"


# --- pre-warming ----------------------------------------------------------
#
# Measured: 99 ms per 400 px thumbnail, 165 ms at 800 px. A cold thirty-garment
# grid was three seconds of encoding inside the requests somebody was waiting
# on. The cut-out job is already off the request path and already holds the
# file, so it renders them there.

def test_the_grid_thumbnails_exist_before_anyone_asks(client, auth):
    from config import THUMBS_DIR

    c = create_cloth(client, auth)
    fresh = client.get(f"/clothes/{c['id']}", headers=auth).json()
    assert fresh["images"][0]["cutout_status"] == "ready"

    cached = {p.name for p in THUMBS_DIR.rglob("*.webp")}
    assert cached, "no thumbnail was pre-rendered"
    # Both the sizes the app requests: 400 in the grids, 800 on the detail view.
    widths = {p.parent.parent.parent.name for p in THUMBS_DIR.rglob("*.webp")}
    assert {"400", "800"} <= widths, widths


def test_a_prewarmed_thumbnail_is_fresh_enough_to_serve(client, auth):
    """The point of pre-warming: by the time a screen asks, the cached file is
    newer than the cut-out it came from, so the request serves it instead of
    encoding it.

    Asserted on mtimes rather than by watching for a re-render, because each
    test starts with a fresh database while the images directory persists for
    the whole run: cloth id 1 is reused, and a leftover thumbnail from an
    earlier test is legitimately stale.
    """
    from config import THUMBS_DIR

    c = create_cloth(client, auth)
    fresh = client.get(f"/clothes/{c['id']}", headers=auth).json()
    cutout = Path(fresh["images"][0]["cutout_url"].split("?")[0]
                  .replace("/images/", "", 1))
    from config import IMAGES_DIR
    source = IMAGES_DIR / cutout
    cached = THUMBS_DIR / "400" / "images" / (cutout.as_posix() + ".webp")

    assert cached.is_file(), f"not pre-rendered: {cached}"
    assert cached.stat().st_mtime_ns >= source.stat().st_mtime_ns, \
        "the pre-rendered thumbnail is already stale against its source"


def test_prewarming_never_breaks_the_cutout(client, auth, monkeypatch):
    """A thumbnail is a nicety; the cut-out is the user's garment."""
    import routes_thumbs

    def boom(*a, **kw):
        raise RuntimeError("no disk space")

    monkeypatch.setattr(routes_thumbs, "_render", boom)
    c = create_cloth(client, auth)
    fresh = client.get(f"/clothes/{c['id']}", headers=auth).json()
    assert [im["cutout_status"] for im in fresh["images"]] == ["ready", "ready"]


def test_a_file_outside_the_images_root_is_ignored(client, auth, tmp_path):
    """prewarm takes a path; one that is not under the images root must not
    write a thumbnail somewhere unexpected."""
    from PIL import Image

    import routes_thumbs

    stray = tmp_path / "stray.webp"
    Image.new("RGBA", (40, 40), (1, 2, 3, 255)).save(stray)
    assert routes_thumbs.prewarm(stray) == 0


def test_prewarming_replaces_a_stale_thumbnail(client, auth):
    """A cut-out is rewritten by redo-bg, by accept-after-reject and by a crop.
    Skipping a thumbnail merely because a file exists at that name would leave
    the stale one — and the slow on-demand re-render — for exactly the cases
    pre-warming exists to cover."""
    import os
    import time

    from config import IMAGES_DIR, THUMBS_DIR
    import routes_thumbs

    c = create_cloth(client, auth)
    fresh = client.get(f"/clothes/{c['id']}", headers=auth).json()
    cutout = Path(fresh["images"][0]["cutout_url"].split("?")[0]
                  .replace("/images/", "", 1))
    source = IMAGES_DIR / cutout
    cached = THUMBS_DIR / "400" / "images" / (cutout.as_posix() + ".webp")
    assert cached.is_file()

    before = cached.stat().st_mtime_ns
    # Rewrite the source, as a redo-bg would. Stamped into the future so the
    # comparison cannot depend on filesystem timestamp resolution.
    future = time.time() + 5
    os.utime(source, (future, future))

    assert routes_thumbs.prewarm(source) >= 1, "the stale thumbnail was kept"
    # Re-rendered: its own timestamp moved. (Not compared against the source,
    # which was deliberately stamped in the future.)
    assert cached.stat().st_mtime_ns > before
