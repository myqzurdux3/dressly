"""The slot-by-slot composer behind every algorithm (generator._compose)."""
import generator as g


def _c(i, cat, colors=("Black",), score=4, worn=None):
    return {"id": i, "name": f"{cat}{i}", "brand": "", "cut": "normal",
            "category": cat, "tags": [], "score": score, "colors": list(colors),
            "dom_colors": set(colors), "last_worn_at": worn,
            "is_favorite": False, "role": g.role_of(cat)}


def _wardrobe():
    pool, i = [], 0
    for cat, n in (("tshirt", 6), ("hoodie", 3), ("jacket", 2), ("jeans", 3),
                   ("shorts", 3), ("sneakers", 2), ("socks", 2), ("cap", 2)):
        for _ in range(n):
            i += 1
            pool.append(_c(i, cat))
    return pool


def _cats(o):
    return {c["category"] for c in o}


def test_cold_layers_a_tshirt_under_the_hoodie():
    pool = _wardrobe()
    layered = sum(1 for _ in range(200)
                  if {"tshirt", "hoodie"} <= _cats(g._compose(pool, "cold")))
    assert layered > 100, layered


def test_hot_has_no_layers_and_light_bottoms():
    pool = _wardrobe()
    for _ in range(100):
        cats = _cats(g._compose(pool, "hot"))
        assert not cats & {"hoodie", "jacket", "jeans"}, cats
        assert "shorts" in cats and "tshirt" in cats


def test_never_two_items_in_one_slot_and_shoes_come_with_socks():
    pool = _wardrobe()
    for w in ("any", "hot", "cold"):
        for _ in range(100):
            o = g._compose(pool, w)
            slots = [g._slot(c["category"]) for c in o]
            assert len(slots) == len(set(slots)), slots
            assert "feet" in slots and "socks" in slots


def test_a_jacket_over_shorts_is_rare():
    pool = _wardrobe()
    over = sum(1 for _ in range(400)
               if {"shorts", "jacket"} <= _cats(g._compose(pool, "any")))
    assert over < 15, over


def test_strict_colours_never_clash():
    pool = [_c(1, "tshirt", ("Red",)), _c(2, "tshirt", ("White",)),
            _c(3, "jeans", ("Blue",)), _c(4, "jeans", ("Black",)),
            _c(5, "sneakers", ("Blue",)), _c(6, "sneakers", ("White",))]
    for _ in range(200):
        cols = [x for c in g._compose(pool, "hot", strict_colours=True)
                for x in c["colors"]]
        assert not ({"Red", "Blue"} <= set(cols)), cols


def test_least_worn_varies_among_the_unworn():
    pool = [_c(i, "tshirt", worn=None) for i in range(1, 5)]
    pool += [_c(9, "tshirt", worn="2026-11-20"), _c(10, "jeans"), _c(11, "jeans")]
    seen = set()
    for _ in range(100):
        o = g._compose(pool, "hot", stale_first=True)
        tops = [c["id"] for c in o if c["category"] == "tshirt"]
        assert 9 not in tops
        seen.update(tops)
    assert len(seen) >= 3, seen


def test_locked_slot_is_kept_and_dressed_around():
    pool = _wardrobe()
    locked = [_c(99, "hoodie")]
    for _ in range(50):
        o = g._compose(pool, "cold", locked=locked)
        assert o[0]["id"] == 99
        assert sum(1 for c in o if c["category"] == "hoodie") == 1


def test_same_cut_borrows_shoes():
    pool = _wardrobe()
    o = g._algo_same_cut(pool, weather="hot")
    assert any(c["role"] == "feet" for c in o)


def test_cold_always_has_a_warm_layer():
    pool = _wardrobe()
    for _ in range(300):
        cats = _cats(g._compose(pool, "cold"))
        assert cats & {"hoodie", "jacket"}, cats
