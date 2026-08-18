"""Custom tags are private; brands are a shared vocabulary.

`/autocomplete/tags` used to run `SELECT custom_tags FROM clothes` with no
user_id predicate, so every account read every other account's free-text tags.
"""

import json


def _signup(client, email):
    r = client.post("/auth/signup", json={"email": email, "password": "pw123456"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def _cloth(client, headers, name, brand, tags):
    from tests.conftest import make_png

    r = client.post(
        "/clothes",
        headers=headers,
        data={"name": name, "category": "tshirt", "brand": brand,
              "tags": json.dumps(tags)},
        files=[
            ("images", ("f.png", make_png(), "image/png")),
            ("images", ("b.png", make_png(), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    return r.json()


def test_tags_do_not_leak_between_accounts(client):
    alice = _signup(client, "alice@test.co")
    bob = _signup(client, "bob@test.co")

    _cloth(client, alice, "Tee", "Nike", ["divorce-hearing", "gym"])
    _cloth(client, bob, "Shirt", "Adidas", ["work"])

    bob_tags = client.get("/autocomplete/tags", headers=bob).json()
    assert bob_tags == ["work"], bob_tags
    assert "divorce-hearing" not in bob_tags

    alice_tags = client.get("/autocomplete/tags", headers=alice).json()
    assert sorted(alice_tags) == ["divorce-hearing", "gym"]


def test_brands_stay_shared(client):
    """Brands are deliberately global — real labels, not personal prose."""
    alice = _signup(client, "alice2@test.co")
    bob = _signup(client, "bob2@test.co")
    _cloth(client, alice, "Tee", "Nike", [])

    # brands are normalised to upper case on write
    assert "NIKE" in client.get("/autocomplete/brands", headers=bob).json()
