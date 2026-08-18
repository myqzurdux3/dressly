"""Two fields that decide behaviour elsewhere and were stored verbatim.

`day` is compared as TEXT against date('now', ?), and `category` is matched by
generator.role_of against exact lower-case strings. An unvalidated value in
either one changes what the app does without any error surfacing.
"""

import pytest

from tests.conftest import create_cloth, make_png


def _clothes_payload(category):
    return (
        {"name": "Thing", "category": category},
        [
            ("images", ("f.png", make_png(), "image/png")),
            ("images", ("b.png", make_png(), "image/png")),
        ],
    )


@pytest.mark.parametrize("bad", ["hier", "2026-13-99", "12/08/2026", "today"])
def test_wear_refuses_a_non_iso_day(client, auth, bad):
    c = create_cloth(client, auth)
    r = client.post(f"/clothes/{c['id']}/wear", headers=auth, json={"day": bad})
    assert r.status_code == 400, f"{bad!r} was accepted"


def test_wear_still_accepts_an_iso_day_and_today(client, auth):
    c = create_cloth(client, auth)
    assert client.post(f"/clothes/{c['id']}/wear", headers=auth,
                       json={"day": "2026-08-17"}).status_code == 200
    assert client.post(f"/clothes/{c['id']}/wear", headers=auth,
                       json={}).status_code == 200


def test_agenda_refuses_a_non_iso_day(client, auth):
    r = client.post("/agenda", headers=auth, json={"day": "banana", "title": "x"})
    assert r.status_code == 400


def test_category_case_does_not_change_the_photo_rule(client, auth):
    """"Sneakers" must behave like "sneakers": one photo is enough."""
    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Kicks", "category": "Sneakers"},
        files=[("images", ("f.png", make_png(), "image/png"))],
    )
    assert r.status_code == 200, r.text
    assert r.json()["category"] == "sneakers"


def test_category_case_is_normalised_on_update(client, auth):
    c = create_cloth(client, auth, category="tshirt")
    r = client.put(f"/clothes/{c['id']}", headers=auth,
                     data={"category": "JEANS"})
    assert r.status_code == 200, r.text
    assert r.json()["category"] == "jeans"


def test_moving_to_a_no_cut_category_clears_a_stale_cut(client, auth):
    """The cut is derived from the category, so changing one re-derives it."""
    c = create_cloth(client, auth, category="tshirt")
    assert c["cut"] == "normal"

    r = client.put(f"/clothes/{c['id']}", headers=auth,
                     data={"category": "sneakers"})
    assert r.status_code == 200, r.text
    assert r.json()["cut"] == "", "shoes have no garment cut"
