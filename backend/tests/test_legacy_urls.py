"""Renaming cut-outs from PNG to WebP must not break clients holding old URLs.

When the stored files changed extension, every image the app had cached under
its previous URL started returning 404 at once — the whole wardrobe went blank
until the cache was cleared. The static mounts now resolve a request to whatever
sibling file actually exists, so a migration is invisible to clients.
"""
from PIL import Image

from tests.conftest import create_cloth


def _cutout_url(client, auth, cloth):
    """The finished cut-out's URL.

    Re-reads the cloth rather than trusting the create response: uploads now
    answer before the cut-out exists, and until it does cutout_url points at the
    original .jpg. These tests are about the .webp.
    """
    fresh = client.get(f"/clothes/{cloth['id']}", headers=auth).json()
    assert fresh["images"][0]["cutout_status"] == "ready", "cut-out never finished"
    return fresh["images"][0]["cutout_url"].split("?")[0]


def test_current_url_is_served(client, auth):
    c = create_cloth(client, auth)
    url = _cutout_url(client, auth, c)
    assert url.endswith(".webp")
    assert client.get(url).status_code == 200


def test_old_png_url_still_resolves_to_the_webp(client, auth):
    """The exact regression: a client cached `..._cutout.png` before the
    migration and keeps asking for it."""
    c = create_cloth(client, auth)
    webp = _cutout_url(client, auth, c)
    legacy = webp[: -len(".webp")] + ".png"

    r = client.get(legacy)
    assert r.status_code == 200, f"{legacy} should fall back to {webp}"
    assert r.content[:4] in (b"RIFF", b"\x89PNG"), "served bytes are not an image"


def test_thumbnail_route_also_accepts_the_old_extension(client, auth):
    c = create_cloth(client, auth)
    # Same reason as _cutout_url: read it back, or thumb_url still points at the
    # original .jpg and the .webp->.png swap below produces "front_.png".
    fresh = client.get(f"/clothes/{c['id']}", headers=auth).json()
    thumb = fresh["images"][0]["thumb_url"].split("?")[0]
    assert thumb.endswith(".webp"), thumb
    legacy = thumb[: -len(".webp")] + ".png"
    assert client.get(legacy).status_code == 200


def test_a_genuinely_missing_file_is_still_404(client, auth):
    """The fallback must not turn every typo into a 200."""
    create_cloth(client, auth)
    assert client.get("/images/1/does_not_exist_at_all.png").status_code == 404


def test_fallback_does_not_escape_the_images_directory(client, auth):
    create_cloth(client, auth)
    for attempt in ("/images/../config.py", "/images/1/../../../etc/passwd"):
        r = client.get(attempt)
        assert r.status_code in (307, 400, 404), f"{attempt} -> {r.status_code}"
        assert b"SECRET_KEY" not in r.content
        assert b"root:" not in r.content


def test_served_webp_is_a_valid_image(client, auth, tmp_path):
    import io

    c = create_cloth(client, auth)
    r = client.get(_cutout_url(client, auth, c))
    assert r.status_code == 200
    with Image.open(io.BytesIO(r.content)) as im:
        im.load()
        assert im.size[0] > 0


def test_images_are_marked_immutable_through_the_fallback(client, auth):
    c = create_cloth(client, auth)
    legacy = _cutout_url(client, auth, c)[: -len(".webp")] + ".png"
    r = client.get(legacy)
    assert "immutable" in r.headers.get("cache-control", "")
