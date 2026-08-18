"""The prompt helpers used to run one SELECT per garment, twice per render.

_compose_prompt is called at least twice for a generation (once for FLUX, once
for the try-on prompt), and each of _garment_descriptions, _garment_phrase and
_extra_reference_paths walked the garments one query at a time. On a ten-item
outfit that is dozens of round trips before the first byte is sent anywhere.

These tests count queries rather than time them: the count is what regresses.
"""

import routes_outfits
from db import get_conn
from tests.conftest import create_cloth, make_png


class Counting:
    """A connection wrapper that counts execute() calls."""

    def __init__(self, conn):
        self.conn, self.n = conn, 0

    def execute(self, sql, *a, **k):
        self.n += 1
        return self.conn.execute(sql, *a, **k)


def _wardrobe(client, auth, n=8):
    cats = ["tshirt", "jeans", "hoodie", "jacket", "shorts", "shirt",
            "trousers", "polo"]
    return [create_cloth(client, auth, name=f"item {i}", category=cats[i % len(cats)])["id"]
            for i in range(n)]


def test_descriptions_cost_one_query_whatever_the_outfit_size(client, auth):
    ids = _wardrobe(client, auth)
    with get_conn() as conn:
        counter = Counting(conn)
        out = routes_outfits._garment_descriptions(counter, ids)
    assert len(out) == len(ids)
    assert counter.n == 1, f"{counter.n} queries for {len(ids)} garments"


def test_the_tryon_phrase_costs_one_query(client, auth):
    ids = _wardrobe(client, auth)
    with get_conn() as conn:
        counter = Counting(conn)
        phrase = routes_outfits._garment_phrase(counter, ids)
    assert "the" in phrase
    assert counter.n == 1, f"{counter.n} queries for {len(ids)} garments"


def test_validating_the_request_costs_one_query(client, auth):
    ids = _wardrobe(client, auth)
    req = type("R", (), {"cloth_ids": ids, "model_id": None,
                         "random_model": False})()
    with get_conn() as conn:
        counter = Counting(conn)
        routes_outfits._validate_inputs(counter, req, 1)
    assert counter.n == 1, f"{counter.n} queries for {len(ids)} garments"


def test_marking_worn_costs_two_statements(client, auth):
    ids = _wardrobe(client, auth, 6)
    with get_conn() as conn:
        counter = Counting(conn)
        n = routes_outfits._mark_clothes_worn(counter, ids, 1, "2026-08-18")
    assert n == len(ids)
    assert counter.n == 2, f"{counter.n} statements for {len(ids)} garments"

    # and the history really was written, for every one of them
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT cloth_id FROM cloth_wears WHERE day = '2026-08-18'").fetchall()
    assert {r["cloth_id"] for r in rows} == set(ids)


def test_marking_worn_ignores_somebody_elses_cloth(client, auth):
    """The per-garment UPDATE checked ownership; the batched one must too."""
    mine = _wardrobe(client, auth, 2)
    with get_conn() as conn:
        n = routes_outfits._mark_clothes_worn(conn, mine + [999999], 1, "2026-08-19")
    assert n == 2
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT cloth_id FROM cloth_wears WHERE day = '2026-08-19'").fetchall()
    assert {r["cloth_id"] for r in rows} == set(mine)


def test_extra_angles_cost_two_queries(client, auth):
    """Multi-angle garments (shoes, bags) contribute their extra photos."""
    shoes = client.post(
        "/clothes", headers=auth,
        data={"name": "kicks", "category": "sneakers"},
        files=[("images", ("a.png", make_png(), "image/png")),
               ("images", ("b.png", make_png(), "image/png")),
               ("images", ("c.png", make_png(), "image/png"))],
    ).json()
    tee = create_cloth(client, auth, name="tee", category="tshirt")

    with get_conn() as conn:
        counter = Counting(conn)
        paths = routes_outfits._extra_reference_paths(
            counter, [tee["id"], shoes["id"]], budget=4)
    assert paths, "the extra angles of the shoes should be offered"
    assert counter.n == 2, f"{counter.n} queries"
