"""The colour algorithm on synthetic wardrobes (no DB, no HTTP).

The greedy _largest_compatible_set these tests used to pin is gone: nothing
called it any more once the algorithm went through _compose.
"""

import random

import generator as g


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


def test_it_still_returns_an_outfit_end_to_end():
    pool = _pool(30, 99)
    picked = g._algo_color_match(pool)
    assert picked, "the algorithm must still produce an outfit"
    slots = [g._slot(c["category"]) for c in picked]
    assert len(slots) == len(set(slots)), "one garment per slot"


def test_an_empty_or_colourless_wardrobe_does_not_crash():
    assert g._algo_color_match([]) == []
    colourless = [{"id": 1, "colors": [], "role": "top", "category": "tshirt",
                   "name": "a", "brand": "", "score": 3, "cut": "normal",
                   "tags": [], "last_worn_at": None}]
    assert g._algo_color_match(colourless)  # falls back to the random algo
