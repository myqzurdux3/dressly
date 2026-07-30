"""A locked cloth decides the theme.

Reported: "je sélectionne un t-shirt Adidas puis je mets same brand et ça me
génère que des outfits avec des shorts de marque random".

It did. The themed algorithms picked their theme from the wardrobe, weighted by
how much of each brand you own, and never looked at what the user had locked.
Lock a single Adidas tee in a wardrobe full of Nike and the weighting lands on
Nike almost every time; the tee stays because it is locked, and everything built
around it is Nike. From the outside that is indistinguishable from the theme
being ignored.
"""
from tests.conftest import make_png


def _cloth(client, auth, name, brand, category, cut="normal", tags=None,
           colors=None):
    import json

    data = {"name": name, "brand": brand, "category": category, "cut": cut}
    if tags:
        data["tags"] = json.dumps(tags)
    if colors:
        data["colors"] = json.dumps(colors)
    r = client.post("/clothes", headers=auth, data=data,
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    assert r.status_code == 200, r.text
    return r.json()


def _wardrobe(client, auth):
    """id -> full cloth. The generator's selections carry only a summary, so
    cut and tags have to be looked up."""
    return {c["id"]: c for c in client.get("/clothes", headers=auth).json()}


def _generate(client, auth, algo, locked, count=1, **extra):
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": algo, "count": count,
                          "locked_cloth_ids": locked, **extra})
    assert r.status_code == 200, r.text
    return r.json()["selections"]


def _generate_raw(client, auth, algo, locked, **extra):
    return client.post("/outfits/preview-algo", headers=auth,
                       json={"algo": algo, "count": 1,
                             "locked_cloth_ids": locked, **extra})


# --- the report -----------------------------------------------------------

def test_locking_a_brand_keeps_the_whole_outfit_on_that_brand(client, auth):
    """The exact scenario: one Adidas tee, a wardrobe of Nike, lock the tee."""
    tee = _cloth(client, auth, "Adidas Tee", "Adidas", "tshirt")
    _cloth(client, auth, "Adidas Short", "Adidas", "shorts")
    for i in range(6):
        _cloth(client, auth, f"Nike Tee {i}", "Nike", "tshirt")
        _cloth(client, auth, f"Nike Short {i}", "Nike", "shorts")

    for _ in range(10):
        sel = _generate(client, auth, "same-brand", [tee["id"]])[0]
        brands = {c["brand"] for c in sel}
        assert brands == {"ADIDAS"}, f"locked Adidas, generated {brands}"
        assert any(c["category"] == "shorts" for c in sel), \
            "the outfit never got a bottom"


def test_without_a_lock_the_wardrobe_weighting_still_decides(client, auth):
    """The fix must not turn the algorithm into "always the locked brand" when
    nothing is locked — the weighting is the whole behaviour then."""
    for i in range(6):
        _cloth(client, auth, f"Nike Tee {i}", "Nike", "tshirt")
        _cloth(client, auth, f"Nike Short {i}", "Nike", "shorts")
    _cloth(client, auth, "Adidas Tee", "Adidas", "tshirt")
    _cloth(client, auth, "Adidas Short", "Adidas", "shorts")

    picks = [next(iter({c["brand"] for c in _generate(client, auth,
                                                      "same-brand", [])[0]}))
             for _ in range(30)]
    assert picks.count("NIKE") > picks.count("ADIDAS")


def test_a_lock_still_never_mixes_brands(client, auth):
    tee = _cloth(client, auth, "Adidas Tee", "Adidas", "tshirt")
    _cloth(client, auth, "Adidas Short", "Adidas", "shorts")
    _cloth(client, auth, "Nike Short", "Nike", "shorts")

    for _ in range(10):
        sel = _generate(client, auth, "same-brand", [tee["id"]])[0]
        assert len({c["brand"] for c in sel}) == 1


# --- the awkward cases ----------------------------------------------------

def test_locking_two_brands_honours_one_of_them(client, auth):
    """An Adidas tee and Nike shorts both locked cannot both win. Picking one is
    still better than picking a third brand nobody asked for."""
    tee = _cloth(client, auth, "Adidas Tee", "Adidas", "tshirt")
    short = _cloth(client, auth, "Nike Short", "Nike", "shorts")
    for i in range(5):
        _cloth(client, auth, f"Puma Tee {i}", "Puma", "tshirt")
        _cloth(client, auth, f"Puma Short {i}", "Puma", "shorts")
        _cloth(client, auth, f"Puma Shoe {i}", "Puma", "sneakers")

    for _ in range(10):
        sel = _generate(client, auth, "same-brand", [tee["id"], short["id"]])[0]
        brands = {c["brand"] for c in sel}
        assert brands <= {"ADIDAS", "NIKE"}, \
            f"picked a brand neither locked cloth named: {brands}"


def test_a_locked_cloth_with_no_brand_falls_back_to_the_wardrobe(client, auth):
    """A no-brand item cannot say which brand you meant, so the old behaviour is
    the right one — not an empty outfit."""
    plain = _cloth(client, auth, "Plain Tee", "", "tshirt")
    _cloth(client, auth, "Nike Short", "Nike", "shorts")
    _cloth(client, auth, "Nike Tee", "Nike", "tshirt")

    sel = _generate(client, auth, "same-brand", [plain["id"]])[0]
    assert any(c["id"] == plain["id"] for c in sel), "the lock was dropped"
    assert len(sel) > 1, "nothing was built around the locked cloth"


def test_a_barely_owned_locked_brand_still_wins(client, auth):
    """Two Adidas items against twenty Nike: the weighting would pick Adidas
    about one time in eleven. Locking it is the user saying so explicitly, which
    outranks how much of it they own."""
    tee = _cloth(client, auth, "Adidas Tee", "Adidas", "tshirt")
    _cloth(client, auth, "Adidas Short", "Adidas", "shorts")
    for i in range(10):
        _cloth(client, auth, f"Nike Tee {i}", "Nike", "tshirt")
        _cloth(client, auth, f"Nike Short {i}", "Nike", "shorts")

    for _ in range(6):
        sel = _generate(client, auth, "same-brand", [tee["id"]])[0]
        assert {c["brand"] for c in sel} == {"ADIDAS"}


def test_an_impossible_theme_returns_nothing_rather_than_half_an_outfit(client, auth):
    """Adidas owns no bottom here, so there is no Adidas outfit to make.

    Returning the lone tee is what produced the other half of the complaint —
    "ça me génère qu'un short vert sans aucun t-shirt". Nothing is the honest
    answer, and the user can see they own no Adidas bottom. Turning fill_gaps on
    is how they ask for the rest to come from elsewhere.
    """
    tee = _cloth(client, auth, "Adidas Tee", "Adidas", "tshirt")
    _cloth(client, auth, "Nike Short", "Nike", "shorts")

    pure = _generate_raw(client, auth, "same-brand", [tee["id"]], fill_gaps=False)
    assert pure.status_code == 404, f"half an outfit was proposed: {pure.text}"
    detail = pure.json()["detail"]
    assert "whole outfit" in detail, detail
    assert "rating" not in detail, \
        f"blames a rating filter the user never set: {detail}"

    # And fill_gaps does not rescue it either: borrowing a Nike pair of shorts
    # to finish an Adidas outfit is exactly the complaint. Shoes it may borrow;
    # trousers it may not.
    filled = _generate_raw(client, auth, "same-brand", [tee["id"]], fill_gaps=True)
    if filled.status_code == 200:
        for sel in filled.json()["selections"]:
            garments = [c for c in sel
                        if c["role"] in ("top", "bottom", "outer", "onepiece")]
            assert {c["brand"] for c in garments} == {"ADIDAS"}, \
                f"fill_gaps crossed the brand: {[(c['name'], c['brand']) for c in garments]}"
    else:
        assert filled.status_code == 404


# --- the same flaw in the sibling algorithms ------------------------------

def test_locking_a_cut_keeps_the_outfit_on_that_cut(client, auth):
    slim = _cloth(client, auth, "Slim Tee", "Nike", "tshirt", cut="slim")
    _cloth(client, auth, "Slim Jeans", "Nike", "jeans", cut="slim")
    for i in range(6):
        _cloth(client, auth, f"Large Tee {i}", "Nike", "tshirt", cut="large")
        _cloth(client, auth, f"Large Jeans {i}", "Nike", "jeans", cut="large")

    full = _wardrobe(client, auth)
    for _ in range(8):
        sel = _generate(client, auth, "same-cut", [slim["id"]])[0]
        cuts = {full[c["id"]]["cut"] for c in sel if full[c["id"]]["cut"]}
        assert cuts == {"slim"}, f"locked a slim cloth, generated {cuts}"


def test_locking_a_tag_keeps_the_outfit_on_that_tag(client, auth):
    sport = _cloth(client, auth, "Sport Tee", "Nike", "tshirt", tags=["sport"])
    _cloth(client, auth, "Sport Short", "Nike", "shorts", tags=["sport"])
    for i in range(6):
        _cloth(client, auth, f"Chic Tee {i}", "Nike", "tshirt", tags=["chic"])
        _cloth(client, auth, f"Chic Short {i}", "Nike", "shorts", tags=["chic"])

    full = _wardrobe(client, auth)
    for _ in range(8):
        sel = _generate(client, auth, "matching-tag", [sport["id"]])[0]
        for c in sel:
            tags = full[c["id"]]["custom_tags"]
            if c["id"] != sport["id"] and tags:
                assert "sport" in tags, f"locked a 'sport' cloth, got {tags}"
