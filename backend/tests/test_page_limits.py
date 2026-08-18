"""Listing endpoints are bounded — generously, but bounded.

`limit` used to be whatever the client sent: a million rows was a valid ask,
and `limit=0` silently meant "an empty page" instead of "no limit". The ceiling
is deliberately far above real use (5000 rows against a ~300-garment wardrobe):
it exists to stop a looping client, not to ration the owner.
"""

import config
from db import clamp_page
from tests.conftest import create_cloth


def test_the_ceiling_is_generous():
    assert config.MAX_PAGE_SIZE >= 2000


def test_an_absurd_limit_is_clamped_not_refused():
    lim, off = clamp_page(10**9, 0)
    assert lim == config.MAX_PAGE_SIZE


def test_zero_means_unset_not_empty():
    """A page of zero rows is never what a caller wants."""
    assert clamp_page(0, 0)[0] == config.MAX_PAGE_SIZE


def test_a_negative_offset_cannot_reach_sqlite():
    assert clamp_page(10, -5) == (10, 0)


def test_a_normal_page_passes_through():
    assert clamp_page(24, 48) == (24, 48)


def test_listing_clothes_still_pages_normally(client, auth):
    for i in range(5):
        create_cloth(client, auth, name=f"item {i}")

    all_of_them = client.get("/clothes", headers=auth).json()
    assert len(all_of_them) == 5, "omitting limit still returns everything"

    page = client.get("/clothes?limit=2&offset=0", headers=auth).json()
    assert len(page) == 2
    second = client.get("/clothes?limit=2&offset=2", headers=auth).json()
    assert {c["id"] for c in page}.isdisjoint({c["id"] for c in second})


def test_an_absurd_limit_over_http_returns_the_wardrobe(client, auth):
    create_cloth(client, auth, name="only one")
    r = client.get("/clothes?limit=999999999", headers=auth)
    assert r.status_code == 200
    assert len(r.json()) == 1


def test_listing_outfits_is_bounded_too(client, auth):
    r = client.get("/outfits?limit=999999999", headers=auth)
    assert r.status_code == 200
