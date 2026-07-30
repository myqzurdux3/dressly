"""Every themed algorithm keeps its theme, under every combination of options.

Reported twice, and the second time was my fault for fixing only what was
reported:

    "je sélectionne un t-shirt Adidas puis je mets same brand et ça me génère
     que des outfits avec des shorts de marque random"
    "quand je mets un short Adidas, je mets même marque et l'algo me retourne
     un t-shirt Stussy ??!!"

Two different causes. The first was the algorithm ignoring the locked cloth when
choosing its theme. The second was "fill gaps with other clothes" completing a
missing role from the WHOLE wardrobe, theme or no theme — so a brand that owns
no top got one from wherever.

Fixing a report at a time is how the second one survived the first. This walks
the whole matrix instead: every algorithm, locked and not, gap-filling on and
off, in all three weather modes — because each of those is a separate code path
that can add a cloth to the outfit (_complete, _fill_missing_roles,
_ensure_socks, _ensure_feet).

The rule under test: every GARMENT in a themed outfit shares the theme. Shoes,
socks and accessories may be borrowed — no brand is expected to make everything,
and that is what the gap-filling option is for.
"""
import json

import pytest

from tests.conftest import make_png

GARMENT_ROLES = {"top", "bottom", "outer", "onepiece"}

# algo -> what every garment must share
THEMED = {
    "same-brand": "brand",
    "pick-by-brand": "brand",
    "single-color": "color",
    "pick-by-color": "color",
    "matching-tag": "tag",
    "pick-by-tag": "tag",
    "same-cut": "cut",
}
UNTHEMED = ["color-match", "least-worn", "random"]
ARGS = {"pick-by-color": {"color": "Green"},
        "pick-by-brand": {"brand": "Adidas"},
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


@pytest.fixture(scope="function")
def wardrobe(client, auth):
    """Adidas can dress you; Stussy can dress you; Nike makes only footwear.

    The shape that produced the report: a locked Adidas bottom, a wardrobe where
    another brand has plenty of tops, and shoes that belong to neither.
    """
    short = _cloth(client, auth, "Adidas Short", "Adidas", "shorts",
                   colors=["Green"], tags=["sport"], cut="slim")
    _cloth(client, auth, "Adidas Tee", "Adidas", "tshirt",
           colors=["Green"], tags=["sport"], cut="slim")
    for i in range(5):
        _cloth(client, auth, f"Stussy Tee {i}", "Stussy", "tshirt",
               colors=["White"], tags=["chic"], cut="large")
        _cloth(client, auth, f"Stussy Jeans {i}", "Stussy", "jeans",
               colors=["Black"], tags=["chic"], cut="large")
    _cloth(client, auth, "Nike Socks", "Nike", "socks", colors=["White"])
    _cloth(client, auth, "Nike Shoes", "Nike", "sneakers", colors=["White"])
    return {"locked": short["id"],
            "full": {c["id"]: c for c in
                     client.get("/clothes", headers=auth).json()}}


@pytest.fixture(scope="function")
def one_sided_wardrobe(client, auth):
    """Adidas owns a bottom and NOTHING else.

    This is the shape the reported bug needs, and the first version of this file
    missed it: with an Adidas top available, gap-filling never has to cross the
    theme, so a test built on that wardrobe passes whether the bug is there or
    not. Sabotaging the fix had to make a test fail — it did not, which is how
    this fixture came to exist.
    """
    short = _cloth(client, auth, "Adidas Short", "Adidas", "shorts",
                   colors=["Green"], tags=["sport"], cut="slim")
    for i in range(5):
        _cloth(client, auth, f"Stussy Tee {i}", "Stussy", "tshirt",
               colors=["White"], tags=["chic"], cut="large")
        _cloth(client, auth, f"Stussy Jeans {i}", "Stussy", "jeans",
               colors=["Black"], tags=["chic"], cut="large")
    _cloth(client, auth, "Nike Shoes", "Nike", "sneakers", colors=["White"])
    return {"locked": short["id"],
            "full": {c["id"]: c for c in
                     client.get("/clothes", headers=auth).json()}}


def _values(kind, cloth, full):
    row = full[cloth["id"]]
    if kind == "brand":
        return {cloth["brand"]} if cloth["brand"] else set()
    if kind == "cut":
        return {row["cut"]} if row["cut"] else set()
    if kind == "color":
        return {c["color"] for c in row["colors"]}
    return set(row["custom_tags"])


def _theme_holds(kind, garments, full):
    """Every garment shares at least one theme value with all the others."""
    sets = [_values(kind, c, full) for c in garments]
    sets = [s for s in sets if s]
    if len(sets) < 2:
        return True
    return bool(set.intersection(*sets))


@pytest.mark.parametrize("algo", sorted(THEMED))
@pytest.mark.parametrize("fill_gaps", [False, True])
@pytest.mark.parametrize("weather", ["any", "hot", "cold"])
@pytest.mark.parametrize("locked", [False, True])
def test_the_theme_survives_every_option(client, auth, wardrobe, algo,
                                         fill_gaps, weather, locked):
    kind = THEMED[algo]
    body = {"algo": algo, "count": 1, "fill_gaps": fill_gaps,
            "weather": weather,
            "locked_cloth_ids": [wardrobe["locked"]] if locked else [],
            **ARGS.get(algo, {})}

    for _ in range(8):
        r = client.post("/outfits/preview-algo", headers=auth, json=body)
        if r.status_code == 404:
            continue          # no such outfit is an acceptable answer
        assert r.status_code == 200, r.text
        for sel in r.json()["selections"]:
            garments = [c for c in sel if c["role"] in GARMENT_ROLES]
            assert _theme_holds(kind, garments, wardrobe["full"]), (
                f"{algo} (fill_gaps={fill_gaps}, weather={weather}, "
                f"locked={locked}) mixed {kind}: "
                f"{[(c['name'], sorted(_values(kind, c, wardrobe['full']))) for c in garments]}")


@pytest.mark.parametrize("algo", sorted(THEMED))
def test_a_locked_cloth_is_always_in_the_outfit(client, auth, wardrobe, algo):
    """Whatever else happens, the thing the user pinned is there."""
    body = {"algo": algo, "count": 1,
            "locked_cloth_ids": [wardrobe["locked"]], **ARGS.get(algo, {})}
    for _ in range(6):
        r = client.post("/outfits/preview-algo", headers=auth, json=body)
        if r.status_code == 404:
            continue
        for sel in r.json()["selections"]:
            assert wardrobe["locked"] in [c["id"] for c in sel], \
                f"{algo} dropped the locked cloth"


def test_the_exact_report(client, auth, one_sided_wardrobe):
    """A locked Adidas pair of shorts, same brand. Not a Stussy t-shirt."""
    wardrobe = one_sided_wardrobe
    for fill_gaps in (False, True):
        body = {"algo": "same-brand", "count": 1, "fill_gaps": fill_gaps,
                "locked_cloth_ids": [wardrobe["locked"]]}
        for _ in range(10):
            r = client.post("/outfits/preview-algo", headers=auth, json=body)
            if r.status_code == 404:
                continue
            for sel in r.json()["selections"]:
                garments = [c for c in sel if c["role"] in GARMENT_ROLES]
                brands = {c["brand"] for c in garments}
                assert brands == {"ADIDAS"}, \
                    f"fill_gaps={fill_gaps} produced {brands}"


@pytest.mark.parametrize("algo", sorted(THEMED))
@pytest.mark.parametrize("fill_gaps", [False, True])
@pytest.mark.parametrize("weather", ["any", "hot", "cold"])
def test_a_one_sided_theme_is_never_completed_from_outside(
        client, auth, one_sided_wardrobe, algo, fill_gaps, weather):
    """The reported bug, in the wardrobe that actually triggers it.

    Adidas owns only the shorts, so the only way to produce a top is to leave
    the theme. Nothing may: either the outfit is refused, or every garment in it
    is Adidas.
    """
    kind = THEMED[algo]
    body = {"algo": algo, "count": 1, "fill_gaps": fill_gaps,
            "weather": weather,
            "locked_cloth_ids": [one_sided_wardrobe["locked"]],
            **ARGS.get(algo, {})}
    for _ in range(8):
        r = client.post("/outfits/preview-algo", headers=auth, json=body)
        if r.status_code == 404:
            continue
        assert r.status_code == 200, r.text
        for sel in r.json()["selections"]:
            garments = [c for c in sel if c["role"] in GARMENT_ROLES]
            assert _theme_holds(kind, garments, one_sided_wardrobe["full"]), (
                f"{algo} (fill_gaps={fill_gaps}, weather={weather}) completed a "
                f"one-sided theme from outside it: "
                f"{[(c['name'], sorted(_values(kind, c, one_sided_wardrobe['full']))) for c in garments]}")


@pytest.mark.parametrize("algo", UNTHEMED)
def test_the_untried_algorithms_are_left_alone(client, auth, wardrobe, algo):
    """random, least-worn and color-match promise no shared property. The theme
    rule must not quietly restrict them into producing nothing."""
    ok = 0
    for _ in range(10):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": algo, "count": 1, "fill_gaps": True})
        if r.status_code == 200 and r.json()["selections"]:
            ok += 1
    assert ok >= 8, f"{algo} produced an outfit only {ok}/10 times"


def test_shoes_may_still_be_borrowed(client, auth, wardrobe):
    """The reason gap-filling exists. Adidas makes no shoes in this wardrobe;
    an Adidas outfit may still end up wearing the Nike pair."""
    seen_borrowed = False
    for _ in range(15):
        r = client.post("/outfits/preview-algo", headers=auth,
                        json={"algo": "pick-by-brand", "brand": "Adidas",
                              "count": 1, "fill_gaps": True})
        if r.status_code != 200:
            continue
        for sel in r.json()["selections"]:
            if any(c["role"] == "feet" and c["brand"] != "ADIDAS" for c in sel):
                seen_borrowed = True
    assert seen_borrowed, \
        "gap-filling no longer borrows shoes, which is all it is still for"
