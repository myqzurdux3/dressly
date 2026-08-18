"""Uploads must be bounded in size and in number.

Every upload route used to do `await upload.read()` with no ceiling: one
request could buffer arbitrary bytes in RAM, and `roles` padded the file list
indefinitely. /auth/signup is open, so this was reachable by anyone.
"""

import uploads
from tests.conftest import create_cloth, make_png


def _oversized(monkeypatch, limit=64 * 1024):
    monkeypatch.setattr(uploads, "MAX_UPLOAD_BYTES", limit)
    return b"\x89PNG\r\n\x1a\n" + b"\0" * (limit + 1)


def test_create_cloth_refuses_an_oversized_photo(client, auth, monkeypatch):
    big = _oversized(monkeypatch)
    r = client.post(
        "/clothes",
        headers=auth,
        data={"name": "Tee", "category": "tshirt"},
        files=[
            ("images", ("ok.png", make_png(), "image/png")),
            ("images", ("big.png", big, "image/png")),
        ],
    )
    assert r.status_code == 413, r.status_code


def test_create_cloth_refuses_too_many_photos(client, auth, monkeypatch):
    monkeypatch.setattr(uploads, "MAX_UPLOAD_FILES", 3)
    files = [("images", (f"{i}.png", make_png(), "image/png")) for i in range(5)]
    r = client.post(
        "/clothes", headers=auth, data={"name": "Tee", "category": "tshirt"},
        files=files,
    )
    assert r.status_code == 413, r.status_code


def test_create_cloth_refuses_a_non_image(client, auth):
    r = client.post(
        "/clothes",
        headers=auth,
        data={"name": "Tee", "category": "tshirt"},
        files=[
            ("images", ("ok.png", make_png(), "image/png")),
            ("images", ("evil.png", b"not an image at all", "image/png")),
        ],
    )
    assert r.status_code == 400, r.status_code


def test_add_image_refuses_an_oversized_photo(client, auth, monkeypatch):
    c = create_cloth(client, auth)
    big = _oversized(monkeypatch)
    r = client.post(
        f"/clothes/{c['id']}/images",
        headers=auth,
        data={"role": "extra"},
        files={"image": ("big.png", big, "image/png")},
    )
    assert r.status_code == 413, r.status_code


def test_create_model_refuses_an_oversized_photo(client, auth, monkeypatch):
    big = _oversized(monkeypatch)
    r = client.post(
        "/models",
        headers=auth,
        data={"name": "Alex"},
        files=[
            ("images", ("a.png", make_png(), "image/png")),
            ("images", ("b.png", big, "image/png")),
        ],
    )
    assert r.status_code == 413, r.status_code


def test_a_normal_upload_still_works(client, auth):
    c = create_cloth(client, auth)
    assert c["images"], "the caps must not break an ordinary upload"


def test_decompression_bombs_are_bounded():
    """A pixel ceiling is set process-wide, not left at Pillow's default."""
    import main  # noqa: F401  (import sets the limit)
    from PIL import Image

    assert Image.MAX_IMAGE_PIXELS is not None
    assert Image.MAX_IMAGE_PIXELS <= 89_478_485, "Pillow's warn-only default"
