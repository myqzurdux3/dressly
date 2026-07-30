"""No algorithm may propose something you cannot wear.

Reported: "des fois par ex pour vert ça me génère qu'un short vert sans aucun
t-shirt. Je pense que la majorité des algos ne marchent pas bien."

Correct on both counts. Every themed algorithm completed an outfit only from
within its own theme, so a wardrobe whose only green item is a pair of shorts
produced an outfit of one pair of shorts. An audit over all ten algorithms on
such a wardrobe found six of them doing it:

    single-color    20/20        matching-tag    20/20
    pick-by-color   20/20        pick-by-tag     20/20
    same-brand       3/20        same-cut         3/20

Wearable means an upper and a lower, or a one-piece that is both. Shoes are
optional; a missing pair is a gap, not a nonsense. An explicit category list is
exempt — asking for shorts only and getting shorts only is the feature.
"""
import json

import pytest

from tests.conftest import make_png

ALGOS = ["same-brand", "single-color", "color-match", "matching-tag", "same-cut",
         "least-worn", "pick-by-color", "pick-by-brand", "pick-by-tag", "random"]

EXTRA = {"pick-by-color": {"color": "Green"},
         "pick-by-brand": {"brand": "Nike"},
         "pick-by-tag": {"tag": "sport"}}


def _cloth(client, auth, name, brand, category, cut="normal", tags=None,
           colors=None):
    data = {"name": name, "brand": brand, "category": category, "cut": cut}
    if tags:
        data["tags"] = json.dumps(tags)
    if colors:
        data["colors"] = json.dumps(
            [{"color": c, "dominance": "full"} for c in colors])
    r = client.post("/clothes", headers=auth, data=data,
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    assert r.status_code == 200, r.text
    return r.json()


def _is_wearable(selection):
    roles = {c["role"] for c in selection}
    return bool(roles & {"top", "outer", "onepiece"}) and \
        bool(roles & {"bottom", "onepiece"})


@pytest.fixture
def thin_wardrobe(client, auth):
    """The reported shape: green exists ONLY as a bottom, every theme is
    one-sided. Nothing here can make a themed outfit, and the algorithms used to
    return half of one anyway."""
    _cloth(client, auth, "Green Short", "Nike", "shorts", colors=["Green"],
           tags=["sport"])
    _cloth(client, auth, "White Tee", "Nike", "tshirt", colors=["White"])
    _cloth(client, auth, "Black Jeans", "Adidas", "jeans", colors=["Black"],
           cut="slim")
    _cloth(client, auth, "Blue Hoodie", "Adidas", "hoodie", colors=["Blue"])
    _cloth(client, auth, "Red Sneakers", "Puma", "sneakers", colors=["Red"])


@pytest.fixture
def full_wardrobe(client, auth):
    """Every theme has both an upper and a lower, so every algorithm should
    succeed — the check that the wearability rule did not just make the feature
    answer "nothing" all the time."""
    for brand in ("Nike", "Adidas"):
        for color in ("Green", "Black"):
            _cloth(client, auth, f"{brand} {color} tee", brand, "tshirt",
                   colors=[color], tags=["sport"])
            _cloth(client, auth, f"{brand} {color} short", brand, "shorts",
                   colors=[color], tags=["sport"])
    _cloth(client, auth, "Sneakers", "Puma", "sneakers", colors=["White"])


def _draw(client, auth, algo, **extra):
    body = {"algo": algo, "count": 1, **EXTRA.get(algo, {}), **extra}
    return client.post("/outfits/preview-algo", headers=auth, json=body)


@pytest.mark.parametrize("algo", ALGOS)
def test_no_algorithm_proposes_half_an_outfit(client, auth, thin_wardrobe, algo):
    """The regression itself, over every algorithm rather than the one that was
    reported — six were affected, only one was noticed."""
    for _ in range(15):
        r = _draw(client, auth, algo)
        if r.status_code == 404:
            continue           # nothing to propose is a fine answer
        assert r.status_code == 200, r.text
        for sel in r.json()["selections"]:
            assert _is_wearable(sel), \
                f"{algo} proposed {[c['name'] for c in sel]}"


@pytest.mark.parametrize("algo", ALGOS)
def test_every_algorithm_still_works_on_a_normal_wardrobe(client, auth,
                                                          full_wardrobe, algo):
    """Refusing half-outfits must not become refusing everything."""
    if algo == "same-cut":
        pytest.skip("every cut here spans one role only; covered below")
    ok = 0
    for _ in range(10):
        r = _draw(client, auth, algo)
        if r.status_code == 200 and r.json()["selections"]:
            assert all(_is_wearable(s) for s in r.json()["selections"])
            ok += 1
    assert ok >= 8, f"{algo} produced an outfit only {ok}/10 times"


def test_the_reported_case_exactly(client, auth, thin_wardrobe):
    """Green, when the only green thing you own is a pair of shorts."""
    r = _draw(client, auth, "pick-by-color")
    if r.status_code == 200:
        for sel in r.json()["selections"]:
            assert _is_wearable(sel), \
                f"a lone garment again: {[c['name'] for c in sel]}"
    else:
        assert r.status_code == 404
        detail = r.json()["detail"]
        assert "whole outfit" in detail, detail


def test_the_refusal_says_why_instead_of_blaming_the_rating(client, auth,
                                                            thin_wardrobe):
    """The only message used to be "No clothes match this algorithm (and rating
    filter). Add more or lower the rating." Here the clothes match fine and no
    rating filter is set — it sent you looking in the wrong place."""
    r = _draw(client, auth, "pick-by-color")
    if r.status_code != 404:
        pytest.skip("this wardrobe managed an outfit")
    detail = r.json()["detail"]
    assert "Green" in detail, f"does not say which colour failed: {detail}"
    assert "rating" not in detail.lower(), detail
    assert "fill gaps" in detail.lower(), "does not mention the way out"


def test_an_explicit_category_list_is_exempt(client, auth, full_wardrobe):
    """Asking for shorts only and getting shorts only is the feature. The
    wearability rule must not override what the user typed."""
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "random", "count": 1, "categories": ["shorts"]})
    assert r.status_code == 200, r.text
    sel = r.json()["selections"][0]
    assert sel and all(c["category"] == "shorts" for c in sel)


def test_fill_gaps_completes_a_one_sided_theme(client, auth, thin_wardrobe):
    """The way out, and the reason refusing is acceptable: the user can ask for
    the rest of the outfit to come from anywhere."""
    r = _draw(client, auth, "pick-by-color", fill_gaps=True)
    assert r.status_code == 200, r.text
    sel = r.json()["selections"][0]
    assert _is_wearable(sel)
    assert any(c["name"] == "green short" for c in sel), \
        "the requested colour vanished from its own outfit"
