"""Rejecting a background must never delete the photo it was cut from.

`cutout_path` is an ALIAS of `original_path` in three reachable states:
  - a model image (models deliberately skip background removal),
  - a garment whose cut-out is still 'processing',
  - any image already rejected once (the reject itself sets the alias back).

`reject_image` used to unlink `cutout_path` unconditionally, so in those states
it deleted the user's only copy of the photo.
"""

from pathlib import Path

from tests.conftest import create_cloth, make_png


def _image_row(client, auth, cloth_id):
    return client.get(f"/clothes/{cloth_id}", headers=auth).json()["images"][0]


def test_second_reject_keeps_the_original(client, auth):
    c = create_cloth(client, auth)
    img = _image_row(client, auth, c["id"])
    original = Path(img["original_path"]) if "original_path" in img else None

    # The API does not expose paths; read them from the DB the server uses.
    from db import get_conn

    with get_conn() as conn:
        row = conn.execute(
            "SELECT original_path, cutout_path FROM cloth_images WHERE id = ?",
            (img["id"],),
        ).fetchone()
    original = Path(row["original_path"])
    assert original.exists()

    url = f"/clothes/{c['id']}/images/{img['id']}/reject"
    assert client.post(url, headers=auth).status_code == 200
    assert original.exists(), "first reject destroyed the original photo"

    # After the first reject cutout_path == original_path, so a second reject
    # is the destructive one.
    assert client.post(url, headers=auth).status_code == 200
    assert original.exists(), "second reject destroyed the original photo"

    # And the image is still servable.
    again = _image_row(client, auth, c["id"])
    assert again["cutout_url"]


def test_reject_model_image_keeps_the_original(client, auth):
    r = client.post(
        "/models",
        headers=auth,
        data={"name": "Alex", "roles": ["front", "back"]},
        files=[
            ("images", ("a.png", make_png((10, 20, 30)), "image/png")),
            ("images", ("b.png", make_png((40, 50, 60)), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    model = r.json()
    img = model["images"][0]

    from db import get_conn

    with get_conn() as conn:
        row = conn.execute(
            "SELECT original_path, cutout_path FROM model_images WHERE id = ?",
            (img["id"],),
        ).fetchone()
    # Models store the original as their own cut-out: the alias that made the
    # unlink destructive.
    assert row["cutout_path"] == row["original_path"]
    original = Path(row["original_path"])
    assert original.exists()

    r = client.post(
        f"/models/{model['id']}/images/{img['id']}/reject", headers=auth
    )
    assert r.status_code == 200, r.text
    assert original.exists(), "rejecting a model image destroyed its only photo"
