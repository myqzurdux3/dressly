"""The colour algorithm, made fast without changing what it picks.

Measured before, on a synthetic wardrobe (3 runs, no DB, no HTTP):

    n=100   14.7 ms      n=300   148.3 ms
    n=200   61.3 ms      n=400   252.6 ms

A preview asks for up to 32 draws, so 300 garments meant up to 4.7 s of pure
CPU in one request. After: 6.6 ms at n=300.

These tests pin the BEHAVIOUR, not the timing (which would be flaky). The
reference implementation below is the original algorithm, kept here so any
future rewrite still has something to be equivalent to.
"""

import random

import generator as g


def _reference_best(with_color):
    """The original O(n^2 * k^2) greedy, verbatim."""
    best = []
    for seed in with_color:
        chosen = [seed]
        colors = list(seed["colors"])
        for c in with_color:
            if c["id"] == seed["id"]:
                continue
            trial = colors + [col for col in c["colors"] if col not in colors]
            if g._colors_compatible(trial):
                chosen.append(c)
                colors = trial
        if len(chosen) > len(best):
            best = chosen
    return best


PALETTE = ["Black", "White", "Grey", "Navy", "Blue", "Red", "Green",
           "Beige", "Brown", "Pink", "Yellow", "Orange"]
CATS = ["tshirt", "shirt", "hoodie", "jacket", "jeans", "trousers",
        "shorts", "sneakers", "shoes", "cap"]


def _pool(n, seed):
    r = random.Random(seed)
    return [{
        "id": i + 1, "name": f"c{i}", "brand": "B",
        "category": CATS[i % len(CATS)],
        "role": g.role_of(CATS[i % len(CATS)]), "score": 3, "cut": "normal",
        "colors": r.sample(PALETTE, r.choice([1, 1, 2, 3])),
        "tags": ["x"], "last_worn_at": None,
    } for i in range(n)]


def test_it_finds_a_set_of_the_same_size_as_the_original():
    """Deduplicating seeds by colour signature must not shrink the answer."""
    for seed in range(12):
        pool = _pool(40, seed)
        fast = g._largest_compatible_set(pool)
        slow = _reference_best(pool)
        assert len(fast) == len(slow), (
            f"seed {seed}: fast picked {len(fast)}, original {len(slow)}")


def test_everything_it_returns_is_mutually_compatible():
    """The point of the algorithm: no clashing pair survives in the set."""
    for seed in range(12):
        chosen = g._largest_compatible_set(_pool(60, seed))
        colors = sorted({c for item in chosen for c in item["colors"]})
        assert g._colors_compatible(colors), colors


def test_a_garment_that_adds_no_new_colour_always_fits():
    pool = [
        {"id": 1, "colors": ["Black", "White"], "role": "top",
         "category": "tshirt", "name": "a", "brand": "", "score": 3,
         "cut": "normal", "tags": [], "last_worn_at": None},
        {"id": 2, "colors": ["Black"], "role": "bottom",
         "category": "jeans", "name": "b", "brand": "", "score": 3,
         "cut": "normal", "tags": [], "last_worn_at": None},
    ]
    assert len(g._largest_compatible_set(pool)) == 2


def test_it_still_returns_an_outfit_end_to_end():
    pool = _pool(30, 99)
    picked = g._algo_color_match(pool)
    assert picked, "the algorithm must still produce an outfit"
    roles = [c["role"] for c in picked]
    assert len(roles) == len(set(roles)), "one garment per role"


def test_an_empty_or_colourless_wardrobe_does_not_crash():
    assert g._algo_color_match([]) == []
    colourless = [{"id": 1, "colors": [], "role": "top", "category": "tshirt",
                   "name": "a", "brand": "", "score": 3, "cut": "normal",
                   "tags": [], "last_worn_at": None}]
    assert g._algo_color_match(colourless)  # falls back to the random algo
