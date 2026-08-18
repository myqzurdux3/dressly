"""The README's `POST /clothes` example, replayed.

Documentation that has never been run is a guess. This is the exact payload
printed in backend/README.md; if the API changes shape, this fails and the
example gets fixed with it.
"""

import json

from tests.conftest import make_png


def test_the_readme_post_clothes_example_works(client, auth):
    r = client.post(
        "/clothes",
        headers=auth,
        data={
            "name": "Black oversized hoodie",
            "brand": "Nike",
            "cut": "oversize",
            "category": "hoodie",
            "colors": json.dumps([
                {"color": "Black", "dominance": "full"},
                {"color": "White", "dominance": "little"},
            ]),
            "tags": json.dumps(["street", "basket"]),
        },
        files=[
            ("images", ("front.jpg", make_png(), "image/png")),
            ("images", ("back.jpg", make_png(), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    cloth = r.json()
    # Names are stored lower-case on purpose (_norm_name), like brands are
    # stored upper-case. The README example now says so.
    assert cloth["name"] == "black oversized hoodie"
    assert cloth["brand"] == "NIKE"          # normalised on write
    assert cloth["cut"] == "oversize"
    assert cloth["category"] == "hoodie"
    assert [c["color"] for c in cloth["colors"]] == ["Black", "White"]
    assert cloth["custom_tags"] == ["street", "basket"]
    assert len(cloth["images"]) == 2


def test_accessories_need_only_one_photo_as_documented(client, auth):
    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Runners", "category": "sneakers"},
        files=[("images", ("only.jpg", make_png(), "image/png"))],
    )
    assert r.status_code == 200, r.text


def test_a_garment_still_needs_two(client, auth):
    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Tee", "category": "tshirt"},
        files=[("images", ("only.jpg", make_png(), "image/png"))],
    )
    assert r.status_code == 400
