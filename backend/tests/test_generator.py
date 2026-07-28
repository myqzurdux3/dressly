import json

import generator
from conftest import create_cloth, make_png


def test_role_of():
    assert generator.role_of("tshirt") == "top"
    assert generator.role_of("jeans") == "bottom"
    assert generator.role_of("sneakers") == "feet"
    assert generator.role_of("dress") == "onepiece"
    assert generator.role_of("unknown") == "other"


def test_dedupe_slots_removes_same_slot_items():
    # shorts + jogging are both the "bottom" slot -> only the first survives;
    # a base top + mid layer + outer, and distinct accessories, all stay.
    items = [
        {"id": 1, "role": "bottom", "category": "shorts"},
        {"id": 2, "role": "bottom", "category": "jogging"},   # dup slot -> dropped
        {"id": 3, "role": "top", "category": "tshirt"},
        {"id": 4, "role": "top", "category": "hoodie"},        # mid slot -> kept (layer)
        {"id": 5, "role": "accessory", "category": "hat"},
        {"id": 6, "role": "accessory", "category": "cap"},     # headwear dup -> dropped
        {"id": 7, "role": "accessory", "category": "socks"},   # distinct slot -> kept
        {"id": 8, "role": "feet", "category": "shoes"},
    ]
    kept = {c["id"] for c in generator._dedupe_slots(items)}
    assert kept == {1, 3, 4, 5, 7, 8}


def test_dedupe_slots_dress_blocks_separate_bottom():
    items = [
        {"id": 1, "role": "onepiece", "category": "dress"},   # fills top+mid+bottom
        {"id": 2, "role": "bottom", "category": "jeans"},      # blocked by dress
        {"id": 3, "role": "feet", "category": "shoes"},
    ]
    kept = {c["id"] for c in generator._dedupe_slots(items)}
    assert kept == {1, 3}


def test_pick_one_per_role_dedupes():
    items = [
        {"id": 1, "role": "top"},
        {"id": 2, "role": "top"},
        {"id": 3, "role": "bottom"},
    ]
    picked = generator._pick_one_per_role(items)
    roles = [p["role"] for p in picked]
    assert roles == ["top", "bottom"]  # first top kept, second dropped


def test_hot_and_cold_generation_includes_socks(client, auth):
    # A wardrobe covering both hot and cold weather, plus a competing accessory
    # (cap) and a pair of socks.
    create_cloth(client, auth, name="Tee", category="tshirt")     # hot top
    create_cloth(client, auth, name="Hoodie", category="hoodie")  # cold top
    create_cloth(client, auth, name="Shorts", category="shorts")  # hot bottom
    create_cloth(client, auth, name="Jeans", category="jeans")    # cold bottom
    create_cloth(client, auth, name="Sneakers", category="sneakers")
    create_cloth(client, auth, name="Cap", category="cap")        # rival accessory
    create_cloth(client, auth, name="Socks", category="socks")

    for weather in ("hot", "cold"):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "random", "weather": weather, "count": 1})
        assert r.status_code == 200, r.text
        cats = {c["category"] for c in r.json()["selections"][0]}
        assert "socks" in cats, f"{weather} outfit is missing socks: {cats}"


def test_hot_cold_category_defaults_include_socks(client, auth):
    # Mirrors the app's hot/cold buttons, which pre-select category chips
    # (tshirt/shorts/shoes/socks). The category path must pick the socks.
    create_cloth(client, auth, name="Tee", category="tshirt")
    create_cloth(client, auth, name="Shorts", category="shorts")
    create_cloth(client, auth, name="Sneakers", category="sneakers")
    create_cloth(client, auth, name="Socks", category="socks")

    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "weather": "hot", "count": 1,
                          "categories": ["tshirt", "shorts", "shoes", "socks"]})
    assert r.status_code == 200, r.text
    cats = {c["category"] for c in r.json()["selections"][0]}
    assert "socks" in cats


def test_hot_pairs_shoes_when_theme_leaves_only_socks(client, auth):
    # single-color would pick BLACK (3 items) and keep the black socks but drop
    # the WHITE shoes -> "only socks". A hot outfit must never leave socks
    # without shoes: a pair is added from the wardrobe.
    def _c(name, cat, color):
        return create_cloth(client, auth, name=name, category=cat,
                            colors=[{"color": color, "dominance": "full"}])
    _c("Black tee", "tshirt", "Black")
    _c("Black shorts", "shorts", "Black")
    _c("Black socks", "socks", "Black")
    _c("White shoes", "shoes", "White")
    for _ in range(12):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "single-color", "weather": "hot", "count": 1})
        assert r.status_code == 200, r.text
        cats = {c["category"] for c in r.json()["selections"][0]}
        if "socks" in cats:  # whenever socks are in, shoes must be too
            assert "shoes" in cats, cats


def test_socks_not_forced_when_no_socks_owned(client, auth):
    # No socks in the wardrobe -> generation still succeeds (no crash / no force).
    create_cloth(client, auth, name="Tee", category="tshirt")
    create_cloth(client, auth, name="Shorts", category="shorts")
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "weather": "hot", "count": 1})
    assert r.status_code == 200, r.text
    cats = {c["category"] for c in r.json()["selections"][0]}
    assert "socks" not in cats


def test_hot_forces_socks_with_shoes_even_when_categories_omit_them(client, auth):
    # The "cap but no socks" bug: a hot outfit with a cap + shoes but with socks
    # left out of the category list still ended up sockless. Socks pair with shoes
    # for hot/cold, so they must be added from the wardrobe regardless.
    create_cloth(client, auth, name="Tee", category="tshirt")
    create_cloth(client, auth, name="Shorts", category="shorts")
    create_cloth(client, auth, name="Shoes", category="shoes")
    create_cloth(client, auth, name="Cap", category="cap")
    create_cloth(client, auth, name="Socks", category="socks")
    for _ in range(6):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "random", "weather": "hot", "count": 1,
                              "categories": ["tshirt", "shorts", "shoes", "cap"]})
        assert r.status_code == 200, r.text
        cats = {c["category"] for c in r.json()["selections"][0]}
        assert "socks" in cats, cats  # shoes present -> socks guaranteed


def test_hot_no_socks_when_no_shoes_in_outfit(client, auth):
    # Socks are only forced alongside shoes. A hot outfit restricted to a top +
    # bottom (no feet) must not sprout socks out of nowhere.
    create_cloth(client, auth, name="Tee", category="tshirt")
    create_cloth(client, auth, name="Shorts", category="shorts")
    create_cloth(client, auth, name="Socks", category="socks")
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "weather": "hot", "count": 1,
                          "categories": ["tshirt", "shorts"]})
    assert r.status_code == 200, r.text
    cats = {c["category"] for c in r.json()["selections"][0]}
    assert "socks" not in cats, cats


def test_least_worn_prefers_never_worn(client, auth):
    # Two tops: one worn recently, one never worn; plus a bottom.
    worn = create_cloth(client, auth, name="Worn Tee", category="tshirt")
    never = create_cloth(client, auth, name="Fresh Tee", category="tshirt")
    create_cloth(client, auth, name="Jeans", category="jeans")
    client.post(f"/clothes/{worn['id']}/wear", headers=auth, json={"day": "2026-06-06"})

    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "least-worn", "count": 1})
    assert r.status_code == 200
    names = {c["name"] for c in r.json()["selections"][0]}
    # The never-worn top must be chosen over the recently-worn one.
    assert "fresh tee" in names
    assert "worn tee" not in names


def test_categories_conflicting_types_return_one(client, auth):
    # The algo's "types to include" may list conflicting bottoms (jeans +
    # trousers + jogging); the outfit must contain exactly ONE bottom.
    create_cloth(client, auth, name="Jeans", category="jeans")
    create_cloth(client, auth, name="Trousers", category="trousers")
    create_cloth(client, auth, name="Jog", category="jogging")
    create_cloth(client, auth, name="Tee", category="tshirt")
    create_cloth(client, auth, name="Shoes", category="sneakers")
    for _ in range(6):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "random", "count": 1,
                              "categories": ["jeans", "trousers", "jogging",
                                             "tshirt", "shoes"]})
        assert r.status_code == 200, r.text
        cats = [c["category"] for c in r.json()["selections"][0]]
        bottoms = [x for x in cats if x in ("jeans", "trousers", "jogging")]
        assert len(bottoms) == 1, cats


def test_categories_distinct_accessories_all_kept(client, auth):
    # hat / socks / bag are distinct slots (not conflicts) — all should appear.
    create_cloth(client, auth, name="Hat", category="hat")
    create_cloth(client, auth, name="Socks", category="socks")
    create_cloth(client, auth, name="Bag", category="bag")
    create_cloth(client, auth, name="Tee", category="tshirt")
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "count": 1,
                          "categories": ["hat", "socks", "bag", "tshirt"]})
    assert r.status_code == 200, r.text
    cats = {c["category"] for c in r.json()["selections"][0]}
    assert {"hat", "socks", "bag"}.issubset(cats)


def _colored(client, auth, name, category, color):
    return create_cloth(client, auth, name=name, category=category,
                        colors=[{"color": color, "dominance": "full"}])


def _multicolor(client, auth, name, category, colors):
    # colors: list of (color, dominance) tuples.
    return create_cloth(client, auth, name=name, category=category,
                        colors=[{"color": c, "dominance": d} for c, d in colors])


def test_pick_by_color_returns_only_that_color(client, auth):
    _colored(client, auth, "White tee", "tshirt", "White")
    _colored(client, auth, "Black tee", "tshirt", "Black")
    _colored(client, auth, "White jean", "jeans", "White")
    _colored(client, auth, "Black jean", "jeans", "Black")
    for _ in range(6):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "pick-by-color", "color": "White", "count": 1})
        assert r.status_code == 200, r.text
        names = [x["name"] for x in r.json()["selections"][0]]
        assert names and all("white" in n for n in names), names  # never black


def test_single_color_is_weighted_not_always_most_common(client, auth):
    # Mostly black, a bit of white — over many draws the single-color algo
    # should land on BOTH (weighted), not always the most common (black).
    for i in range(4):
        _colored(client, auth, f"Black tee {i}", "tshirt", "Black")
        _colored(client, auth, f"Black jean {i}", "jeans", "Black")
    _colored(client, auth, "White tee", "tshirt", "White")
    _colored(client, auth, "White jean", "jeans", "White")
    seen = set()
    for _ in range(50):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "single-color", "count": 1})
        if r.status_code != 200:
            continue
        names = " ".join(x["name"] for x in r.json()["selections"][0])
        if "white" in names:
            seen.add("white")
        if "black" in names:
            seen.add("black")
    assert seen == {"white", "black"}, seen  # varies, not stuck on black


def test_pick_by_color_honoured_even_with_categories(client, auth):
    # The bug: picking white while categories were set (e.g. a weather preset)
    # returned the wrong colour. The colour filter must win.
    _colored(client, auth, "Green short", "shorts", "Green")
    _colored(client, auth, "White tee", "tshirt", "White")
    _colored(client, auth, "White short", "shorts", "White")
    for _ in range(6):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "pick-by-color", "color": "White", "count": 1,
                              "categories": ["shorts", "tshirt"]})
        assert r.status_code == 200, r.text
        names = [x["name"] for x in r.json()["selections"][0]]
        assert names and all("white" in n for n in names), names  # never green


def test_pick_by_color_requires_dominant_colour(client, auth):
    # A black jogging with only a LITTLE white must NOT be treated as white; a
    # yellow shirt with a little white must not either. Only dominantly-white
    # clothes qualify.
    _multicolor(client, auth, "Black jog with white trim", "jogging",
                [("Black", "full"), ("White", "little")])
    _multicolor(client, auth, "Yellow tee white logo", "tshirt",
                [("Yellow", "full"), ("White", "little")])
    _multicolor(client, auth, "Real white tee", "tshirt",
                [("White", "full"), ("Green", "little")])
    _colored(client, auth, "Real white jean", "jeans", "White")
    for _ in range(8):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "pick-by-color", "color": "White", "count": 1})
        assert r.status_code == 200, r.text
        names = [x["name"] for x in r.json()["selections"][0]]
        assert names, names
        assert not any("black jog" in n or "yellow tee" in n for n in names), names


def _tagged(client, auth, name, category, tags):
    return client.post(
        "/clothes", headers=auth,
        data={"name": name, "category": category, "cut": "normal",
              "tags": json.dumps(tags)},
        files=[("images", ("f.png", make_png(), "image/png")),
               ("images", ("b.png", make_png(), "image/png"))]).json()


def test_matching_tag_varies_not_always_same_outfit(client, auth):
    # Many clothes share the tag "ete" across roles. The matching-tag algo must
    # produce VARIED outfits, not the exact same one every time.
    for i in range(4):
        _tagged(client, auth, f"Tee{i}", "tshirt", ["ete"])
        _tagged(client, auth, f"Short{i}", "shorts", ["ete"])
        _tagged(client, auth, f"Shoe{i}", "shoes", ["ete"])
    seen = set()
    for _ in range(40):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "matching-tag", "count": 1})
        assert r.status_code == 200, r.text
        seen.add(tuple(sorted(c["id"] for c in r.json()["selections"][0])))
    assert len(seen) > 5, f"matching-tag barely varies: {len(seen)} distinct"


def test_matching_tag_prefers_a_complete_outfit_tag(client, auth):
    # "foot" covers tops + bottoms; "maillot" is a top-only tag with just as many
    # clothes. The algo must NOT keep landing on the top-only tag and return a
    # lone t-shirt — it should favour a tag that yields a bottom too.
    for i in range(6):
        _tagged(client, auth, f"Maillot{i}", "tshirt", ["maillot"])  # top-only tag
    for i in range(3):
        _tagged(client, auth, f"Foot tee{i}", "tshirt", ["foot"])
        _tagged(client, auth, f"Foot short{i}", "shorts", ["foot"])
    for _ in range(20):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "matching-tag", "count": 1})
        assert r.status_code == 200, r.text
        cats = [c["category"] for c in r.json()["selections"][0]]
        assert any(c in ("shorts", "jeans", "trousers", "jogging", "skirt")
                   for c in cats), f"no bottom in matching-tag outfit: {cats}"


def _branded(client, auth, name, category, brand):
    return client.post(
        "/clothes", headers=auth,
        data={"name": name, "category": category, "cut": "normal", "brand": brand},
        files=[("images", ("f.png", make_png(), "image/png")),
               ("images", ("b.png", make_png(), "image/png"))]).json()


def test_fill_gaps_completes_missing_roles_from_any_brand(client, auth):
    # Nike has a top + bottom but NO shoes; Adidas has the shoes.
    _branded(client, auth, "Nike tee", "tshirt", "Nike")
    _branded(client, auth, "Nike jean", "jeans", "Nike")
    _branded(client, auth, "Adidas shoes", "sneakers", "Adidas")
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "same-brand", "count": 1, "fill_gaps": True})
    assert r.status_code == 200, r.text
    roles = {generator.role_of(c["category"]) for c in r.json()["selections"][0]}
    # top/bottom/feet all present — feet is filled from the other brand.
    assert {"top", "bottom", "feet"}.issubset(roles), roles


def test_no_two_of_same_role(client, auth):
    for i in range(3):
        create_cloth(client, auth, name=f"Tee{i}", category="tshirt")
    create_cloth(client, auth, name="Jeans", category="jeans")
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "count": 1})
    sel = r.json()["selections"][0]
    roles = [generator.role_of(c["category"]) for c in sel]
    assert len(roles) == len(set(roles))  # at most one per role
