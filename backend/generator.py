"""Outfit generator algorithms.

Each algorithm selects a coherent set of clothes from the user's wardrobe
(no two of the same clothing category), optionally filtered by a minimum
user rating. The selection is then handed to the image generator, which lays
the chosen clothes out on a *labeled* collage (TOP / BOTTOM / FEET rows) so
the model can tell what each garment is — the fix for "it can't tell what's
what with several clothes."

Categories are grouped into roles for composition:

  top       tshirt, shirt, polo, tank-top, hoodie, sweatshirt
  outer     jacket, coat
  bottom    jeans, trousers, shorts, skirt
  onepiece  dress          (worn alone, replaces top+bottom)
  feet      sneakers, shoes
  accessory hat, socks, underwear

An outfit is at most one item per role, so two of the "same type" can never
end up in the same outfit.
"""

import json
import random as _random
from typing import List, Optional

from db import get_conn

TOP_CATS = {"tshirt", "shirt", "polo", "tank-top", "hoodie", "sweatshirt"}
OUTER_CATS = {"jacket", "coat"}
BOTTOM_CATS = {"jeans", "trousers", "shorts", "skirt", "jogging"}
ONEPIECE_CATS = {"dress"}
FEET_CATS = {"sneakers", "shoes"}
ACCESSORY_CATS = {"hat", "cap", "socks", "underwear", "bag"}

# Roles where a fixed front/back pair is meaningless — the user instead adds
# however many angle photos they actually have (top, sole, side, detail…).
# These items get their extra angles fed to the generator's spare input slots.
MULTI_ANGLE_ROLES = {"feet", "accessory"}


def is_multi_angle(category: str) -> bool:
    """True for shoes/bags/accessories etc. — items photographed from arbitrary
    angles rather than a front + back pair."""
    return role_of(category) in MULTI_ANGLE_ROLES


def has_cut(category: str) -> bool:
    """False for shoes / bags / accessories, which have no garment 'cut'
    (slim/normal/large/oversize). The same-cut algorithm ignores these."""
    return role_of(category) not in ("feet", "accessory")

# Weather → which categories are appropriate. The pool is restricted to these,
# so a hot random pulls shorts + light tops and skips coats / hoodies.
HOT_CATEGORIES = {
    "tshirt", "shirt", "polo", "tank-top",              # light tops
    "shorts", "skirt", "dress",                        # light bottoms
    "sneakers", "shoes", "hat", "cap", "socks", "bag",  # feet + accessory
}
COLD_CATEGORIES = {
    "hoodie", "sweatshirt", "jacket", "coat",          # warm tops + outers
    "jeans", "trousers", "jogging",                    # warm bottoms
    "sneakers", "shoes", "hat", "cap", "socks", "bag",  # feet + accessory
}

NEUTRALS = {"Black", "White", "Grey", "Beige", "Brown"}
WARM = {"Red", "Orange", "Yellow"}
COOL = {"Blue", "Green", "Purple", "Pink"}
COMPLEMENTARY = [
    {"Blue", "Orange"},
    {"Red", "Green"},
    {"Yellow", "Purple"},
]

ALGOS = [
    "same-brand",
    "single-color",
    "color-match",
    "matching-tag",
    "same-cut",
    "least-worn",
    "pick-by-color",
    "pick-by-brand",
    "pick-by-tag",
    "random",
]


def role_of(category: str) -> str:
    if category in TOP_CATS:
        return "top"
    if category in OUTER_CATS:
        return "outer"
    if category in BOTTOM_CATS:
        return "bottom"
    if category in ONEPIECE_CATS:
        return "onepiece"
    if category in FEET_CATS:
        return "feet"
    if category in ACCESSORY_CATS:
        return "accessory"
    return "other"


# Fine outfit slots — finer than role_of: the upper body splits into base top /
# mid layer / outer (so they can coexist as layers), but two items of the SAME
# slot are alternatives (two bottoms, a sweatshirt + a hoodie, …). Each unique
# accessory (hat, socks, bag, underwear) is its own slot so they don't clash.
# Mirrors the app's outfitSlots so the "pick one alternative" behaviour matches.
_BASE_TOP_CATS = {"tshirt", "shirt", "polo", "tank-top"}
_MID_TOP_CATS = {"hoodie", "sweatshirt"}


def slots_of(category: str) -> frozenset:
    if category in _BASE_TOP_CATS:
        return frozenset({"top"})
    if category in _MID_TOP_CATS:
        return frozenset({"mid"})
    if category in OUTER_CATS:
        return frozenset({"outer"})
    if category in BOTTOM_CATS:
        return frozenset({"bottom"})
    if category in ONEPIECE_CATS:
        return frozenset({"top", "mid", "bottom"})  # a dress fills the whole body
    if category in FEET_CATS:
        return frozenset({"feet"})
    if category in ("hat", "cap"):
        return frozenset({"headwear"})
    if not category:
        return frozenset()
    return frozenset({category})  # socks, underwear, bag — each its own slot


def _color_family(c: str) -> str:
    if c in NEUTRALS:
        return "neutral"
    if c in WARM:
        return "warm"
    if c in COOL:
        return "cool"
    return "neutral"


def _pair_compatible(a: str, b: str) -> bool:
    if a == b:
        return True
    if a in NEUTRALS or b in NEUTRALS:
        return True
    if _color_family(a) == _color_family(b):
        return True
    for pair in COMPLEMENTARY:
        if {a, b} == pair:
            return True
    return False


def _colors_compatible(colors: List[str]) -> bool:
    for i in range(len(colors)):
        for j in range(i + 1, len(colors)):
            if not _pair_compatible(colors[i], colors[j]):
                return False
    return True


class GenerateRequest:
    """Loose request object accepted by ``generate``."""

    def __init__(self, algo: str, min_score: int = 0, color: str = "",
                 brand: str = "", tag: str = "", user_id: int = 0,
                 weather: str = "any",
                 categories: Optional[List[str]] = None,
                 locked_cloth_ids: Optional[List[int]] = None,
                 fill_gaps: bool = False, **_):
        self.algo = algo
        self.min_score = int(min_score or 0)
        self.color = (color or "").strip()
        self.brand = (brand or "").strip()
        self.tag = (tag or "").strip()
        self.user_id = user_id
        self.weather = (weather or "any").strip().lower()
        self.categories = [c for c in (categories or []) if c]
        self.locked_cloth_ids = list(locked_cloth_ids or [])
        # When true, missing core roles (top/bottom/shoes) the theme couldn't
        # cover are filled from ANY cloth — e.g. add other-brand shoes when the
        # chosen brand has none.
        self.fill_gaps = bool(fill_gaps)


def _weather_categories(weather: str):
    if weather == "hot":
        return HOT_CATEGORIES
    if weather == "cold":
        return COLD_CATEGORIES
    return None  # any


def _fetch_pool(conn, user_id: int, min_score: int, weather: str = "any",
                 categories: Optional[List[str]] = None,
                 include_excluded: bool = False) -> List[dict]:
    """All of the user's clothes with their colors + parsed tags + score,
    optionally restricted to a weather set or an explicit category list.
    ``include_excluded`` keeps clothes marked exclude_from_algo (used only when
    resolving hand-locked items — algorithms never see excluded clothes)."""
    allowed = None
    if categories:
        allowed = set(categories)
    else:
        allowed = _weather_categories(weather)
    # exclude_from_algo clothes are opt-in only: the user can still lock them
    # into an outfit by hand, but algorithms never pull them from the pool.
    where_excl = "" if include_excluded else " AND COALESCE(exclude_from_algo, 0) = 0"
    rows = conn.execute(
        "SELECT id, name, brand, cut, category, custom_tags, score, last_worn_at "
        f"FROM clothes WHERE user_id = ?{where_excl} "
        "ORDER BY id",
        (user_id,),
    ).fetchall()
    # Fetch every color for this user's clothes in one query (was N+1: one
    # SELECT per cloth) and group them in memory.
    from collections import defaultdict
    colors_by_cloth = defaultdict(list)
    dom_by_cloth = defaultdict(list)  # (color, tier) for computing dominant colors
    _TIER = {"full": 3, "part": 2, "little": 1}
    for cr in conn.execute(
        "SELECT cc.cloth_id, cc.color, cc.dominance FROM cloth_colors cc "
        "JOIN clothes c ON c.id = cc.cloth_id WHERE c.user_id = ? ORDER BY cc.id",
        (user_id,),
    ).fetchall():
        colors_by_cloth[cr["cloth_id"]].append(cr["color"])
        dom_by_cloth[cr["cloth_id"]].append(
            (cr["color"], _TIER.get((cr["dominance"] or "").lower(), 2)))

    def _dominant(cid):
        # The colours at the highest dominance tier on this cloth. "jogging" that
        # is Black-full + White-little -> {"Black"}; a White-full tee -> {"White"};
        # an all-"part" white/grey/black shoe -> all three (co-dominant).
        pairs = dom_by_cloth.get(cid, [])
        if not pairs:
            return set()
        top = max(t for _, t in pairs)
        return {col for col, t in pairs if t == top}
    pool = []
    for r in rows:
        if allowed is not None and r["category"] not in allowed:
            continue
        score = r["score"] if "score" in r.keys() else 0
        # min_score>0 means "only rated clothes at or above this rating".
        # score 0 = unrated, so it's excluded when a threshold is set.
        if min_score > 0 and (score < min_score):
            continue
        colors = colors_by_cloth.get(r["id"], [])
        tags = json.loads(r["custom_tags"] or "[]")
        pool.append({
            "id": r["id"], "name": r["name"], "brand": (r["brand"] or ""),
            "cut": r["cut"], "category": r["category"], "tags": tags,
            "score": score, "colors": colors, "dom_colors": _dominant(r["id"]),
            "last_worn_at": r["last_worn_at"] if "last_worn_at" in r.keys() else None,
            "role": role_of(r["category"]),
        })
    return pool


def _pick_one_per_role(items: List[dict]) -> List[dict]:
    """Take the first item for each role (preserve input order). Never two of
    the same role → never two of the same clothing type."""
    seen = set()
    out = []
    for it in items:
        if it["role"] in seen:
            continue
        seen.add(it["role"])
        out.append(it)
    return out


def _complete(picked: List[dict], pool: List[dict]) -> List[dict]:
    """Fill missing core roles (top or onepiece, then bottom) from the pool so
    the outfit is wearable even if the theme didn't cover every role."""
    roles = {p["role"] for p in picked}
    if "top" not in roles and "onepiece" not in roles:
        for c in pool:
            if c["role"] in ("top", "onepiece") and c["id"] not in {p["id"] for p in picked}:
                picked.append(c)
                roles.add(c["role"])
                break
    if "onepiece" not in roles and "bottom" not in roles:
        for c in pool:
            if c["role"] == "bottom" and c["id"] not in {p["id"] for p in picked}:
                picked.append(c)
                roles.add("bottom")
                break
    return picked


def _fill_missing_roles(picked: List[dict], pool: List[dict]) -> List[dict]:
    """Fill any missing core role (top, bottom, feet) from the WHOLE pool —
    regardless of the theme. Used by the 'fill gaps with other clothes' option so
    e.g. a same-brand outfit still gets shoes when that brand has none."""
    have_ids = {p["id"] for p in picked}
    covered = {p["role"] for p in picked}
    if "onepiece" in covered:  # a dress already covers top + bottom
        covered |= {"top", "bottom"}
    for role in ("top", "bottom", "feet"):
        if role in covered:
            continue
        for c in _shuffle(pool):
            if c["role"] == role and c["id"] not in have_ids:
                picked.append(c)
                covered.add(role)
                have_ids.add(c["id"])
                break
    return picked


def _dedupe_slots(items: List[dict]) -> List[dict]:
    """Drop any item whose fine slot is already taken, keeping the first (so
    locked / earlier-picked items win). Two bottoms (shorts + jogging), two tops,
    two hats, shoe + shoe, etc. collapse to one; genuinely distinct slots — a base
    top + mid layer + outer, or hat + socks + bag — all survive. A dress fills
    top+mid+bottom, so it blocks a separate top/bottom."""
    used: set = set()
    out = []
    for it in items:
        s = slots_of(it["category"])
        if s and (s & used):
            continue
        out.append(it)
        used |= s
    return out


def _shuffle(items: List[dict]) -> List[dict]:
    s = list(items)
    _random.shuffle(s)
    return s


# --- algorithms ----------------------------------------------------------

def _algo_same_brand(pool):
    if not pool:
        return []
    from collections import Counter
    counts = Counter(c["brand"] for c in pool if c["brand"])
    if not counts:
        return []
    # Pick the brand WEIGHTED by how many items of it you own — so a brand you
    # have a lot of (e.g. Nike) comes up proportionally more often than one you
    # barely own (e.g. a single Adidas tee), instead of always the most common
    # or a flat random. Rarely-owned brands still appear, just rarely.
    brands = list(counts)
    target = _random.choices(brands, weights=[counts[b] for b in brands], k=1)[0]
    themed = [c for c in pool if c["brand"] == target]
    # Complete ONLY from the same brand — never mix in another brand's cloth.
    return _complete(_pick_one_per_role(_shuffle(themed)), themed)


def _algo_single_color(pool):
    if not pool:
        return []
    # Use each cloth's DOMINANT colour(s) (highest dominance tier), not just any
    # colour it carries — otherwise a black jogging with a little white counts as
    # white. Pick the outfit's colour WEIGHTED by how many clothes have it as
    # dominant — so a colour you own a lot of comes up proportionally more often,
    # and it VARIES between runs instead of always returning the single most
    # common (which felt like "it always gives black").
    from collections import Counter
    counts = Counter(col for c in pool for col in c.get("dom_colors", ()))
    if not counts:
        return []
    colors = list(counts)
    target = _random.choices(colors, weights=[counts[c] for c in colors], k=1)[0]
    themed = [c for c in pool if target in c.get("dom_colors", ())]
    return _complete(_pick_one_per_role(_shuffle(themed)), themed)


def _algo_color_match(pool):
    if not pool:
        return []
    with_color = [c for c in pool if c["colors"]]
    if not with_color:
        return _algo_random(pool)
    # Greedy: try each seed color family, keep the largest compatible set.
    best = []
    for seed in with_color:
        chosen = [seed]
        colors = list(seed["colors"])
        for c in with_color:
            if c["id"] == seed["id"]:
                continue
            trial = colors + [col for col in c["colors"] if col not in colors]
            if _colors_compatible(trial):
                chosen.append(c)
                colors = trial
        if len(chosen) > len(best):
            best = chosen
    return _complete(_pick_one_per_role(_shuffle(best)), best)


def _algo_matching_tag(pool):
    if not pool:
        return []
    from collections import Counter, defaultdict
    tag_counts: Counter = Counter()
    tag_roles = defaultdict(set)
    for c in pool:
        for t in c["tags"]:
            tag_counts[t] += 1
            tag_roles[t].add(c["role"])
    if not tag_counts:
        return []

    def _wearable(tag) -> bool:
        # A tag can form a real outfit if it covers a bottom AND an upper (top or
        # outer), or a one-piece. This keeps the algo off top-only tags like
        # "maillot" that would return a lone t-shirt with no bottom.
        roles = tag_roles[tag]
        return "onepiece" in roles or (
            "bottom" in roles and ("top" in roles or "outer" in roles))

    # Prefer tags that make a complete outfit; only fall back to the rest if none
    # do. Among the candidates, pick WEIGHTED by how many clothes carry the tag
    # (favours a tag you use a lot, varies between runs), then shuffle so
    # different items fill each role.
    candidates = [t for t in tag_counts if _wearable(t)] or list(tag_counts)
    target = _random.choices(
        candidates, weights=[tag_counts[t] for t in candidates], k=1)[0]
    themed = [c for c in pool if target in c["tags"]]
    return _complete(_pick_one_per_role(_shuffle(themed)), themed)


def _algo_same_cut(pool):
    if not pool:
        return []
    # Only clothes that actually have a cut count — shoes/bags/accessories are
    # ignored (they have no slim/oversize fit).
    candidates = [c for c in pool if c["cut"] and has_cut(c["category"])]
    cuts = [c["cut"] for c in candidates]
    if not cuts:
        return []
    from collections import Counter
    counts = Counter(cuts)
    keys = list(counts)
    # Weighted by how many clothes have each cut (varies, favours common cuts).
    target = _random.choices(keys, weights=[counts[k] for k in keys], k=1)[0]
    themed = [c for c in candidates if c["cut"] == target]
    return _complete(_pick_one_per_role(_shuffle(themed)), themed)


def _algo_least_worn(pool):
    """Prefer the clothes worn longest ago (never-worn first). Builds an outfit
    from the least-recently-worn item in each role, so nothing sits unused."""
    if not pool:
        return []
    # Never worn (None) sorts before any date; older dates sort before newer.
    ordered = sorted(pool, key=lambda c: (c["last_worn_at"] is not None,
                                          c["last_worn_at"] or ""))
    return _complete(_pick_one_per_role(ordered), pool)


def _algo_pick_by_color(pool, color):
    if not color or not pool:
        return []
    # Only clothes whose DOMINANT colour is the chosen one — a black jogging with
    # a little white trim must not count as "white".
    themed = [c for c in pool if color in c.get("dom_colors", ())]
    if not themed:
        return []
    # Complete only from themed clothes so the "single color" promise holds.
    return _pick_one_per_role(_shuffle(themed))


def _algo_pick_by_brand(pool, brand):
    if not brand or not pool:
        return []
    themed = [c for c in pool if c["brand"].lower() == brand.lower()]
    if not themed:
        return []
    # Complete only from themed clothes so the "single brand" promise holds.
    return _pick_one_per_role(_shuffle(themed))


def _algo_pick_by_tag(pool, tag):
    if not tag or not pool:
        return []
    tl = tag.strip().lower()
    themed = [c for c in pool if any(t.lower() == tl for t in c["tags"])]
    if not themed:
        return []
    # Complete only from clothes carrying the chosen tag.
    return _pick_one_per_role(_shuffle(themed))


def _algo_random(pool, weather="any"):
    if not pool:
        return []
    # Weather shapes what _complete fills in. A hot outfit should not get an
    # outer; a cold outfit should.
    want_top = "top"
    want_bottom = "bottom"
    want_outer = None
    if weather == "cold":
        want_outer = "outer"
        want_bottom = "bottom"
    elif weather == "hot":
        want_outer = None
        want_bottom = "bottom"
    picked = _pick_one_per_role(_shuffle(pool))
    picked = _ensure_role(picked, pool, want_top) or picked
    if not any(p["role"] == "onepiece" for p in picked):
        picked = _ensure_role(picked, pool, want_bottom) or picked
    if want_outer:
        picked = _ensure_role(picked, pool, want_outer) or picked
    return picked


def _ensure_role(picked, pool, role):
    if not role:
        return picked
    if any(p["role"] == role for p in picked):
        return picked
    if role == "top" and any(p["role"] == "onepiece" for p in picked):
        return picked
    for c in pool:
        if c["role"] == role and c["id"] not in {p["id"] for p in picked}:
            return picked + [c]
    return picked


def _ensure_socks(picked, pool):
    """Guarantee a pair of socks is in the outfit. Socks share the 'accessory'
    role with hats/bags, so the normal one-per-role pick often drops them; here
    we add a socks cloth explicitly (in addition to any other accessory) when the
    user owns one and none is picked yet. Used for hot/cold weather generation."""
    if any(p["category"] == "socks" for p in picked):
        return picked
    chosen = {p["id"] for p in picked}
    socks = [c for c in pool if c["category"] == "socks" and c["id"] not in chosen]
    if not socks:
        return picked
    return picked + [_random.choice(socks)]


def _ensure_feet(picked, pool):
    """Guarantee a pair of shoes when the outfit has socks — the mirror of
    _ensure_socks. A colour/brand theme can pick socks yet exclude every shoe
    (wrong colour/brand); rather than leave socks with no shoes, add a pair from
    the whole wardrobe. Used for hot/cold weather generation."""
    if any(p["role"] == "feet" for p in picked):
        return picked
    chosen = {p["id"] for p in picked}
    feet = [c for c in pool if c["role"] == "feet" and c["id"] not in chosen]
    if not feet:
        return picked
    return picked + [_random.choice(feet)]


_ALGOS = {
    "same-brand": lambda p, r: _algo_same_brand(p),
    "single-color": lambda p, r: _algo_single_color(p),
    "color-match": lambda p, r: _algo_color_match(p),
    "matching-tag": lambda p, r: _algo_matching_tag(p),
    "same-cut": lambda p, r: _algo_same_cut(p),
    "least-worn": lambda p, r: _algo_least_worn(p),
    "pick-by-color": lambda p, r: _algo_pick_by_color(p, r.color),
    "pick-by-brand": lambda p, r: _algo_pick_by_brand(p, r.brand),
    "pick-by-tag": lambda p, r: _algo_pick_by_tag(p, r.tag),
    "random": lambda p, r: _algo_random(p, r.weather),
}


def _theme_filtered_pool(pool, algo, req):
    """For pick-by-color/brand/tag, restrict the pool to clothes matching the
    chosen color / brand / tag, so that filter is applied even alongside an
    explicit category list. Other algorithms get the pool unchanged."""
    if algo == "pick-by-color" and req.color:
        return [c for c in pool if req.color in c.get("dom_colors", ())]
    if algo == "pick-by-brand" and req.brand:
        b = req.brand.strip().lower()
        return [c for c in pool if c["brand"].strip().lower() == b]
    if algo == "pick-by-tag" and req.tag:
        t = req.tag.strip().lower()
        return [c for c in pool if any(tag.lower() == t for tag in c["tags"])]
    return pool


def _select_by_categories(pool, categories):
    """Explicit category list: pick one random cloth per requested category, but
    only ONE per fine slot — so if the user ticked conflicting types (e.g. jeans
    + trousers, or joggers + shorts) the outfit gets a single bottom, not several.
    Which of the conflicting types wins is random (each draw varies)."""
    cats = list(categories)
    _random.shuffle(cats)  # random which of two same-slot types is used
    out = []
    used_slots: set = set()
    for cat in cats:
        s = slots_of(cat)
        if s and (s & used_slots):
            continue  # a same-slot type was already chosen this draw
        candidates = [c for c in pool if c["category"] == cat]
        if not candidates:
            continue  # no cloth of this type — leave the slot open for another
        out.append(_random.choice(candidates))
        used_slots |= s
    return out


def combo_key(cloth_ids) -> str:
    """Canonical key for a set of clothes (order-independent), used to match a
    proposed outfit against the user's blacklist."""
    return ",".join(str(i) for i in sorted({int(x) for x in cloth_ids}))


def _blacklisted_combos(conn, user_id: int) -> set:
    return {r["combo"] for r in conn.execute(
        "SELECT combo FROM outfit_blacklist WHERE user_id = ?", (user_id,)
    ).fetchall()}


def _fetch_clothes_by_id(conn, user_id: int, ids: List[int]) -> List[dict]:
    """Pool-shaped dicts for specific owned clothes (used to LOCK user-picked
    items into an algorithm run, even if they'd be filtered out by weather /
    rating / category). Preserves the given id order."""
    if not ids:
        return []
    full = _fetch_pool(conn, user_id, 0, weather="any", categories=None,
                       include_excluded=True)
    by_id = {c["id"]: c for c in full}
    return [by_id[i] for i in ids if i in by_id]


def select(req: GenerateRequest) -> List[dict]:
    """Run an algorithm and return the chosen clothes (list of dicts with id,
    name, brand, category, role). Empty list if nothing matched — or if every
    attempt hit a blacklisted combination.

    ``locked_cloth_ids`` on the request are always kept in the outfit; the
    algorithm fills the remaining roles around them."""
    algo = req.algo if req.algo in _ALGOS else "random"
    locked_ids = list(dict.fromkeys(
        int(x) for x in (getattr(req, "locked_cloth_ids", []) or [])))
    with get_conn() as conn:
        pool = _fetch_pool(conn, req.user_id, req.min_score,
                           weather=req.weather, categories=req.categories)
        # Socks + shoes sources, independent of the category / theme restriction:
        # hot/cold outfits pair socks WITH shoes even when the chosen types or a
        # colour/brand theme dropped one of them.
        _essentials = _fetch_pool(conn, req.user_id, req.min_score)
        socks_pool = [c for c in _essentials if c["category"] == "socks"]
        feet_pool = [c for c in _essentials if c["role"] == "feet"]
        locked = _fetch_clothes_by_id(conn, req.user_id, locked_ids)
        blacklist = _blacklisted_combos(conn, req.user_id)

    locked_id_set = {c["id"] for c in locked}
    locked_roles = {c["role"] for c in locked if c["role"] != "other"}

    def _pick_once() -> List[dict]:
        # A pick-by-color/brand/tag theme is a HARD filter on the pool, so it's
        # honoured even when categories are also set (otherwise picking "white"
        # while a weather preset filled categories returned the wrong colour).
        themed_pool = _theme_filtered_pool(pool, algo, req)
        # An explicit category list picks one cloth per requested type (keeping one
        # per fine slot, so hat + socks + bag all survive). This "types to include"
        # mode is the RANDOM algorithm; every other algorithm keeps its theme and
        # just runs on the (category-restricted) pool, so e.g. single-color still
        # builds a one-colour outfit instead of the colour being ignored.
        if req.categories and algo == "random":
            picked = _select_by_categories(themed_pool, req.categories)
            core = [c for c in picked if c["role"] != "other"] or picked
        else:
            picked = _ALGOS[algo](themed_pool, req)
            core = [c for c in _pick_one_per_role(picked) if c["role"] != "other"] or picked
        if not locked:
            result = core
        else:
            # Locked clothes always stay; the algo only fills roles they don't cover.
            extra = _pick_one_per_role([
                c for c in core if c["id"] not in locked_id_set
                and (c["role"] == "other" or c["role"] not in locked_roles)
            ])
            result = locked + extra
        # Optionally fill missing core roles (top/bottom/shoes) from ANY cloth —
        # e.g. add other-brand shoes when the chosen brand has none.
        if req.fill_gaps:
            result = _fill_missing_roles(result, pool)
        # Hot/cold outfits pair socks WITH shoes — you don't wear shoes barefoot,
        # nor socks with no shoes. So if the outfit ended up with only one of the
        # pair (a category list omitted one, or a colour/brand theme excluded it),
        # add the other from the whole wardrobe. This fixes "only socks OR only
        # shoes" on a hot outfit.
        if req.weather in ("hot", "cold"):
            has_feet = any(c["role"] == "feet" for c in result)
            has_socks = any(c["category"] == "socks" for c in result)
            if has_feet and not has_socks:
                result = _ensure_socks(result, socks_pool)
            elif has_socks and not has_feet:
                result = _ensure_feet(result, feet_pool)
        # Final safety net: never two items sharing a fine slot (two bottoms like
        # shorts + jogging, two tops, two hats, ...). This is belt-and-braces on
        # top of the per-role / per-slot picks above, so no algorithm path can
        # ever emit a physically-impossible outfit.
        return _dedupe_slots(result)

    # Re-roll past blacklisted combinations so the generator never proposes an
    # outfit the user banned. Deterministic algos just converge to empty.
    last: List[dict] = []
    for _ in range(30):
        last = _pick_once()
        if not last or not blacklist:
            return last
        if combo_key([c["id"] for c in last]) not in blacklist:
            return last
    return []  # only blacklisted combos were reachable


def explain(picked: List[dict], algo: str) -> str:
    """Short human label for the dialog, e.g. 'Color match · Black'."""
    names = {
        "same-brand": "Same brand",
        "single-color": "One dominant color",
        "color-match": "Matching colors",
        "matching-tag": "Shared tag",
        "same-cut": "Same cut",
        "least-worn": "Not worn recently",
        "pick-by-color": "Picked color",
        "pick-by-brand": "Picked brand",
        "pick-by-tag": "Picked tag",
        "random": "Random",
    }[algo] if algo in ALGOS else algo
    brands = sorted({c["brand"] for c in picked if c["brand"]})
    if algo == "same-brand" and brands:
        return f"{names} · {brands[0]}"
    return names