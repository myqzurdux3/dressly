"""Every route that writes a cut-out must write it in the current format.

Each of these used to hardcode `.png`, which is how single 7 MB cut-outs ended
up on disk after a crop or a redo-bg. The encoder picks its format from the
destination suffix, so a stale suffix silently reverts the optimisation.
"""
from pathlib import Path

from PIL import Image

import db
from tests.conftest import create_cloth, make_png


def _image_row(image_id):
    with db.get_conn() as conn:
        return dict(conn.execute(
            "SELECT original_path, cutout_path, bg_accepted FROM cloth_images "
            "WHERE id = ?", (image_id,),
        ).fetchone())


def _format_of(path) -> str:
    with Image.open(path) as im:
        return im.format


def test_upload_writes_a_webp_cutout(client, auth):
    c = create_cloth(client, auth)
    row = _image_row(c["images"][0]["id"])
    assert row["cutout_path"].endswith(".webp")


def test_redo_bg_writes_a_webp_cutout(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    r = client.post(
        f"/clothes/{c['id']}/images/{img['id']}/redo-bg",
        headers=auth, json={"tolerance": "high"},
    )
    assert r.status_code == 200, r.text
    row = _image_row(img["id"])
    assert row["cutout_path"].endswith(".webp"), row["cutout_path"]
    assert Path(row["cutout_path"]).is_file()


def test_transform_writes_a_suffix_matching_its_content(client, auth):
    """A crop of an accepted image keeps alpha -> WebP, and the file must really
    be WebP: a JPEG behind a .png name breaks content-type sniffing downstream."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    r = client.post(
        f"/clothes/{c['id']}/images/{img['id']}/transform",
        headers=auth, json={"rotate": 90},
    )
    assert r.status_code == 200, r.text
    row = _image_row(img["id"])
    assert row["cutout_path"].endswith(".webp"), row["cutout_path"]
    assert _format_of(row["cutout_path"]) == "WEBP"
    assert _format_of(row["original_path"]) == "JPEG"


def test_transform_of_a_rejected_image_writes_a_real_jpeg(client, auth):
    """With the background rejected there is no alpha to keep, so the cut-out
    slot holds a JPEG — and must be named like one."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    assert client.post(
        f"/clothes/{c['id']}/images/{img['id']}/reject",
        headers=auth, json={},
    ).status_code == 200
    r = client.post(
        f"/clothes/{c['id']}/images/{img['id']}/transform",
        headers=auth, json={"rotate": 180},
    )
    assert r.status_code == 200, r.text
    row = _image_row(img["id"])
    assert row["cutout_path"].endswith(".jpg"), row["cutout_path"]
    assert _format_of(row["cutout_path"]) == "JPEG"


def test_accept_after_reject_regenerates_at_the_canonical_path(client, auth):
    """reject aliases the cut-out to the original; accept must rebuild it at the
    same canonical name every time, or the app's URL-keyed cache goes stale."""
    c = create_cloth(client, auth)
    img = c["images"][0]

    def cutout_path():
        return _image_row(img["id"])["cutout_path"]

    client.post(f"/clothes/{c['id']}/images/{img['id']}/accept", headers=auth)
    first = cutout_path()
    client.post(f"/clothes/{c['id']}/images/{img['id']}/reject",
                headers=auth, json={})
    client.post(f"/clothes/{c['id']}/images/{img['id']}/accept", headers=auth)
    second = cutout_path()

    assert first == second
    assert second.endswith(".webp")
    assert Path(second).is_file()


def test_accept_does_not_hold_the_write_lock(client, auth, monkeypatch):
    """Same guarantee as the upload path: ONNX inference must not run inside the
    transaction, or concurrent writers get 'database is locked'."""
    import sqlite3

    import routes_clothes

    c = create_cloth(client, auth)
    img = c["images"][0]
    # Force the regeneration branch.
    client.post(f"/clothes/{c['id']}/images/{img['id']}/reject",
                headers=auth, json={})

    probe = {"ok": None, "error": None}
    original = routes_clothes.remove_background

    def spy(src, dst, tolerance="medium"):
        try:
            conn = sqlite3.connect(db.DB_PATH, timeout=1)
            try:
                conn.execute("PRAGMA busy_timeout = 1000")
                conn.execute(
                    "INSERT INTO audit_log (action, detail) VALUES (?, ?)",
                    ("probe.write", "written mid-accept"),
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
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/accept", headers=auth)
    assert r.status_code == 200, r.text
    assert probe["ok"] is True, f"write lock held during accept: {probe['error']}"


def test_added_image_also_gets_a_webp_cutout(client, auth):
    c = create_cloth(client, auth)
    r = client.post(
        f"/clothes/{c['id']}/images", headers=auth, data={"role": "extra"},
        files={"image": ("e.png", make_png((0, 200, 0)), "image/png")},
    )
    assert r.status_code == 200, r.text
    extra = [i for i in r.json()["images"] if i["role"] == "extra"][-1]
    row = _image_row(extra["id"])
    assert row["cutout_path"].endswith(".webp")
