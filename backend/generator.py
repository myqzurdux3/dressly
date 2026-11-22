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
from functools import lru_cache
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

# Roles the "don't repeat within a plan" rule does not apply to. A week of
# outfits should not put the same t-shirt on twice; expecting seven different
# pairs of shoes would just make the plan fail.
AVOID_EXEMPT_ROLES = {"feet", "accessory"}

# How a real person puts clothes on, innermost first. Everything that draws or
# describes a whole outfit uses this: the collage the model is shown, the
# sentence that tells it what covers what, and the manual builder's canvas.
#
# Without it the order was whatever the clothes happened to be picked in, which
# is how a jacket came out underneath the t-shirt — the model was never told
# which one was on top, so it guessed, and guessed differently every render.
#
# Shoes sit above socks and above the trouser hem; a bag hangs over everything.
LAYER_ORDER = {
    "underwear": 10,
    "socks": 20,
    "jeans": 30, "trousers": 30, "shorts": 30, "skirt": 30, "jogging": 30,
    "dress": 35,                                   # replaces top + bottom
    "tank-top": 40, "tshirt": 42, "polo": 44, "shirt": 46,
    "sweatshirt": 50, "hoodie": 52,                # mid layer, over a t-shirt
    "jacket": 60, "coat": 62,                      # outer, over everything worn
    "sneakers": 70, "shoes": 70,
    "hat": 80, "cap": 80,
    "bag": 90,
}
# Unknown categories land between the outer layer and the shoes: visible, but
# never hiding a garment whose place we do know.
_DEFAULT_LAYER = 65


def layer_of(category: str) -> int:
    """Where a category sits in the stack — smaller is closer to the skin."""
    return LAYER_ORDER.get((category or "").strip().lower(), _DEFAULT_LAYER)


def layer_sorted(items, key=lambda it: it):
    """``items`` ordered from innermost to outermost.

    Stable, so two garments on the same layer keep the order the user chose.
    ``key`` extracts the category from whatever the caller is sorting.
    """
    return sorted(items, key=lambda it: layer_of(key(it)))


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
    # Worn UNDER the hoodie: without them a cold outfit was a hoodie on bare
    # skin (measured: no cold outfit was ever layered).
    "tshirt", "shirt", "polo",
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


# Every category the roles above know about. A value outside this set falls to
# role "other", which silently changes the minimum-photo rule, the stored cut
# and every weather/algorithm filter — so the write paths normalise case
# against it and log what they do not recognise.
KNOWN_CATEGORIES = (
    TOP_CATS | OUTER_CATS | BOTTOM_CATS | ONEPIECE_CATS | FEET_CATS | ACCESSORY_CATS
)


def normalize_category(category: str) -> str:
    """Lower-case and trim a category so role_of can match it.

    role_of compares against exact lower-case strings, so "Sneakers" used to
    land in role "other" — a garment that then needed two photos instead of
    one and disappeared from the weather and layering rules.
    """
    return (category or "").strip().lower()


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


@lru_cache(maxsize=1024)
def _color_family(c: str) -> str:
    if c in NEUTRALS:
        return "neutral"
    if c in WARM:
        return "warm"
    if c in COOL:
        return "cool"
    return "neutral"


# Cached: the answer depends only on the two colour names, and the palette is a
# dozen values — but the colour algorithm asks the same questions thousands of
# times per draw.
@lru_cache(maxsize=4096)
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
                 fill_gaps: bool = False,
                 avoid_cloth_ids: Optional[List[int]] = None,
                 avoid_theme_values: Optional[List[str]] = None, **_):
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
        # Garments already used elsewhere in the same run — the week planner
        # passes what earlier days took so a t-shirt does not come back on
        # Wednesday. Shoes and accessories are deliberately NOT avoided: nobody
        # owns seven pairs, and refusing to repeat them empties the plan.
        self.avoid_cloth_ids = set(int(x) for x in (avoid_cloth_ids or []))
        # Theme values (brands, colours, tags, cuts) already used elsewhere in
        # the same run. Reported: "pour le mode meme marque je ne veux pas que
        # toute la semaine il y ait la meme chose".
        self.avoid_theme_values = {
            str(v).strip().lower() for v in (avoid_theme_values or []) if str(v).strip()}


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
        "SELECT id, name, brand, cut, category, custom_tags, score, last_worn_at, "
        "COALESCE(is_favorite, 0) AS is_favorite "
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
            "is_favorite": bool(r["is_favorite"]),
            "role": role_of(r["category"]),
        })
    return pool


# Algorithms whose whole promise is that every GARMENT shares one property.
# "Fill gaps" may still borrow shoes for them — nobody asks a brand to make
# trainers — but borrowing a top is the difference between "same brand" and
# "some brand", and it is what the option used to do.
_HARD_THEMES = {
    "same-brand": lambda c: c["brand"],
    "pick-by-brand": lambda c: c["brand"],
    "single-color": lambda c: frozenset(c.get("dom_colors", ())),
    "pick-by-color": lambda c: frozenset(c.get("dom_colors", ())),
    "matching-tag": lambda c: frozenset(c["tags"]),
    "pick-by-tag": lambda c: frozenset(c["tags"]),
    "same-cut": lambda c: c["cut"] if has_cut(c["category"]) else None,
}

# Roles a theme is not expected to cover. Shoes and accessories are where
# "complete it from the rest of the wardrobe" earns its keep.
_BORROWABLE_ROLES = {"feet", "other"}


def _theme_allows(algo: str, picked: List[dict], req=None):
    """Predicate: may this cloth join the outfit without breaking the theme?

    Derived from what was already picked rather than from the algorithm's
    internals, so it cannot drift out of step with them. A set-valued theme
    (colours, tags) matches on overlap; a scalar one (brand, cut) on equality.

    With one exception, and it is the important one: pick-by-colour/brand/tag
    carry their theme in the REQUEST, so it is known even when the pick came
    back empty. Inferring from an empty selection used to yield "anything
    goes", and gap-filling then dressed a "Nike" outfit in Stussy — the exact
    complaint this file already carries a fix for, reappearing whenever the
    themed pool ran dry (which a week plan does by design, once it has used
    that brand's clothes on the earlier days).
    """
    if req is not None:
        if algo == "pick-by-brand" and getattr(req, "brand", ""):
            want = req.brand.strip().lower()
            return lambda c: (c.get("brand") or "").strip().lower() == want
        if algo == "pick-by-color" and getattr(req, "color", ""):
            want = req.color.strip().lower()
            return lambda c: any(
                (v or "").strip().lower() == want
                for v in (c.get("dom_colors") or ()))
        if algo == "pick-by-tag" and getattr(req, "tag", ""):
            want = req.tag.strip().lower()
            return lambda c: any(
                (t or "").strip().lower() == want for t in (c.get("tags") or ()))
    key = _HARD_THEMES.get(algo)
    if key is None:
        return lambda c: True
    values = [key(c) for c in picked if key(c)]
    if not values:
        # A themed algorithm that picked nothing still has a theme; letting
        # anything in would quietly answer a different question.
        return (lambda c: True) if algo not in _HARD_THEMES else (lambda c: False)
    if isinstance(values[0], frozenset):
        common = set.intersection(*(set(v) for v in values)) or set().union(*values)
        return lambda c: bool(set(key(c) or ()) & common)
    allowed = set(values)
    return lambda c: key(c) in allowed


def _fill_missing_roles(picked: List[dict], pool: List[dict],
                        algo: str = "", req=None) -> List[dict]:
    """Fill any missing core role (top, bottom, feet) from the pool.

    Used by the "fill gaps with other clothes" option. It used to fill from the
    WHOLE pool regardless of the theme, which is how locking an Adidas pair of
    shorts and asking for the same brand came back with a Stussy t-shirt: Adidas
    owned no top, so the gap was filled from everything.

    Now a themed run keeps its theme for the garments and only borrows shoes.
    If the theme owns no top, the outfit has no top, and the caller reports that
    honestly instead of quietly changing what the user asked for.
    """
    allows = _theme_allows(algo, picked, req)
    have_ids = {p["id"] for p in picked}
    covered = {p["role"] for p in picked}
    if "onepiece" in covered:  # a dress already covers top + bottom
        covered |= {"top", "bottom"}
    for role in ("top", "bottom", "feet"):
        if role in covered:
            continue
        candidates = [c for c in _shuffle(pool)
                      if c["role"] == role and c["id"] not in have_ids]
        if role not in _BORROWABLE_ROLES:
            on_theme = [c for c in candidates if allows(c)]
            candidates = on_theme          # never cross the theme for a garment
        for c in candidates:
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


# --- composing an outfit ---------------------------------------------------
#
# Measured on a real 173-piece wardrobe (60 draws per algorithm and weather)
# before this existed: a t-shirt was never worn under a hoodie (both were the
# "top" role, one per role), every "any weather" outfit had a jacket even over
# shorts, random draws clashed in colour one time in five, "least worn" gave
# the very same outfit every time, and "same cut" / "shared tag" never had
# shoes. Every algorithm now picks its theme, then hands the themed pool to
# _compose, which dresses a person slot by slot.

# Where a garment goes on the body. None = never picked on its own (underwear,
# unknown categories): it only appears when the user locks it in.
def _slot(category: str) -> Optional[str]:
    c = (category or "").strip().lower()
    if c in ONEPIECE_CATS:
        return "onepiece"
    if c in _BASE_TOP_CATS:
        return "top"
    if c in _MID_TOP_CATS:
        return "mid"
    if c in OUTER_CATS:
        return "outer"
    if c in BOTTOM_CATS:
        return "bottom"
    if c in FEET_CATS:
        return "feet"
    if c in ("hat", "cap"):
        return "headwear"
    if c in ("socks", "bag"):
        return c
    return None


_LIGHT_BOTTOMS = {"shorts", "skirt"}

# Per climate: chance of a mid layer, of an outer layer, and how much more a
# light bottom (shorts, skirt) is wanted than a long one. 0 = never.
_CLIMATES = {
    "hot":  {"mid": 0.0, "outer": 0.0, "light": 4.0, "long": 0.0},
    "warm": {"mid": 0.08, "outer": 0.05, "light": 3.0, "long": 1.0},
    "mild": {"mid": 0.45, "outer": 0.3, "light": 0.6, "long": 1.5},
    "cool": {"mid": 0.75, "outer": 0.8, "light": 0.0, "long": 1.0},
    "cold": {"mid": 0.85, "outer": 0.97, "light": 0.0, "long": 1.0},
}
_HEADWEAR_CHANCE = 0.3
_BAG_CHANCE = 0.15
_ONEPIECE_CHANCE = 0.25
# A hoodie or sweatshirt is usually worn over a t-shirt.
_UNDER_MID_CHANCE = 0.85


def _climate_for(weather: str, pool: List[dict]) -> str:
    """The climate of one draw. 'hot'/'cold' are what was asked; 'any' varies
    between draws, among the climates this wardrobe can actually dress."""
    if weather in ("hot", "cold"):
        return weather
    cats = {c["category"] for c in pool}
    options = []
    if cats & _LIGHT_BOTTOMS:
        options.append("warm")
    if cats & (BOTTOM_CATS - _LIGHT_BOTTOMS):
        options += ["mild", "mild", "cool"]
    return _random.choice(options) if options else "mild"


def _colours(c: dict) -> List[str]:
    return list(c.get("dom_colors") or ()) or list(c.get("colors") or ())[:1]


def _loud(colours) -> set:
    return {x for x in colours if x not in NEUTRALS}


def _days_since(day: Optional[str]) -> Optional[int]:
    if not day:
        return None
    from datetime import date
    try:
        return (date.today() - date.fromisoformat(str(day)[:10])).days
    except ValueError:
        return None


def _item_weight(c: dict, chosen: List[dict], strict_colours: bool) -> float:
    """How much this garment is wanted next to what is already chosen."""
    score = c.get("score") or 0
    w = (1.0 + (score if score > 0 else 2.5)) ** 1.6
    if c.get("is_favorite"):
        w *= 1.6
    days = _days_since(c.get("last_worn_at"))
    if days is None:
        w *= 1.15
    elif days <= 2:
        w *= 0.2
    elif days <= 6:
        w *= 0.6
    mine = _colours(c)
    others = [x for o in chosen for x in _colours(o)]
    if mine and others:
        if any(not _pair_compatible(a, b) for a in mine for b in others):
            return 0.0 if strict_colours else w * 0.03
        loud_mine, loud_others = _loud(mine), _loud(others)
        if loud_mine and loud_others:
            # Echoing a colour already worn reads as intended; a second, new
            # bright colour rarely does.
            w *= 1.4 if loud_mine & loud_others else 0.35
    return w


def _weighted_pick(cands: List[dict], chosen: List[dict],
                   strict_colours: bool, stale_first: bool) -> Optional[dict]:
    if not cands:
        return None
    if stale_first:
        # "Least worn": only the longest-unworn tier competes (never worn,
        # else the oldest quarter), and the choice inside it varies.
        never = [c for c in cands if not c.get("last_worn_at")]
        if never:
            cands = never
        else:
            ordered = sorted(cands, key=lambda c: c["last_worn_at"])
            cands = ordered[:max(1, len(ordered) // 4)]
    weights = [_item_weight(c, chosen, strict_colours) for c in cands]
    if not any(weights):
        return None
    return _random.choices(cands, weights=weights, k=1)[0]


def _compose(pool: List[dict], weather: str = "any", locked=(),
             extras: Optional[List[dict]] = None, strict_colours: bool = False,
             stale_first: bool = False) -> List[dict]:
    """Dress one person from ``pool``, slot by slot.

    ``locked`` garments are already worn: their slots are taken and colours
    are matched around them. ``extras`` is where shoes, socks, headwear and a
    bag come from when a theme does not apply to them (a cut has no shoes);
    by default the same pool.
    """
    climate = _climate_for(weather, pool)
    rules = _CLIMATES[climate]
    chosen: List[dict] = list(locked)
    taken = set()
    for c in chosen:
        taken |= slots_of(c["category"])
    ids = {c["id"] for c in chosen}

    def take(slot: str, src: List[dict], weigh=None) -> Optional[dict]:
        cands = [c for c in src if _slot(c["category"]) == slot
                 and c["id"] not in ids and not (slots_of(c["category"]) & taken)]
        if weigh is not None:
            cands = [c for c in cands if weigh(c) > 0]
        pick = _weighted_pick(cands, chosen, strict_colours, stale_first)
        if pick is not None:
            chosen.append(pick)
            ids.add(pick["id"])
            taken.update(slots_of(pick["category"]))
        return pick

    side = extras if extras is not None else pool
    # The body first: a one-piece sometimes, else a top and a bottom.
    has_onepiece = any(_slot(c["category"]) == "onepiece" for c in pool)
    if (has_onepiece and "top" not in taken and "bottom" not in taken
            and _random.random() < _ONEPIECE_CHANCE):
        take("onepiece", pool)
    bottom_light = None
    if "bottom" not in taken:
        def bottom_ok(c):
            light = c["category"] in _LIGHT_BOTTOMS
            return rules["light"] if light else rules["long"]
        # Weighted by climate: shorts in the heat, long trousers in the cold.
        cands = [c for c in pool if _slot(c["category"]) == "bottom"]
        by_climate = [c for c in cands if bottom_ok(c) > 0]
        b = take("bottom", by_climate or cands)
        if b is not None:
            bottom_light = b["category"] in _LIGHT_BOTTOMS
    else:
        bottom_light = any(c["category"] in _LIGHT_BOTTOMS for c in chosen)
    # Layers: fewer over shorts, whatever the forecast says.
    mid_p, outer_p = rules["mid"], rules["outer"]
    if bottom_light:
        mid_p, outer_p = mid_p * 0.15, outer_p * 0.1
    want_mid = "mid" not in taken and _random.random() < mid_p
    if want_mid:
        take("mid", pool)
    if "top" not in taken:
        if "mid" not in taken or _random.random() < _UNDER_MID_CHANCE:
            take("top", pool)
        if "top" not in taken and "mid" not in taken:
            take("mid", pool)  # no t-shirt to wear: a sweatshirt will do
    if "outer" not in taken and _random.random() < outer_p:
        take("outer", pool)
    if climate == "cold" and not taken & {"mid", "outer"}:
        # A t-shirt on its own is not dressed for the cold: add whichever warm
        # layer the wardrobe has.
        take("mid", pool) or take("outer", pool)
    if "feet" not in taken:
        take("feet", side)
    if "socks" not in taken and "feet" in taken:
        take("socks", side)
    if "headwear" not in taken and _random.random() < (
            _HEADWEAR_CHANCE * (1.5 if climate in ("hot", "warm") else 1)):
        take("headwear", side)
    if "bag" not in taken and _random.random() < _BAG_CHANCE:
        take("bag", side)
    return chosen


def learned_pairs(conn, user_id: int) -> dict:
    """What the owner's outfit ratings say about garments worn together.

    Each rated outfit votes on every pair of its garments: a 5 adds 2, a 4
    adds 1, a 2 takes 1 away and a 1 takes 2. Summed over all outfits, a pair
    that keeps getting good marks is drawn together more often, and one that
    keeps getting bad ones is drawn apart.
    """
    from collections import defaultdict
    votes: dict = defaultdict(float)
    for r in conn.execute(
            "SELECT cloth_ids, rating FROM outfits WHERE user_id = ? "
            "AND rating > 0 AND rating != 3", (user_id,)).fetchall():
        try:
            ids = sorted({int(x) for x in json.loads(r["cloth_ids"] or "[]")})
        except (TypeError, ValueError):
            continue
        w = float(r["rating"] - 3)
        for i, a in enumerate(ids):
            for b in ids[i + 1:]:
                votes[(a, b)] += w
    return dict(votes)


def _learned_bonus(picked: List[dict], pairs: Optional[dict]) -> float:
    if not pairs:
        return 0.0
    ids = sorted(c["id"] for c in picked)
    total = sum(pairs.get((a, b), 0.0)
                for i, a in enumerate(ids) for b in ids[i + 1:])
    # Bounded, so one loved outfit does not drown the colour rules.
    return max(-3.0, min(3.0, 0.5 * total))


def outfit_score(picked: List[dict], pairs: Optional[dict] = None) -> float:
    """How good an outfit looks on paper: colours that go together, few
    bright colours, liked and not just-worn pieces, complete feet, and what
    the owner's own outfit ratings say about these pieces together."""
    cols = [x for c in picked for x in _colours(c)]
    clashes = sum(1 for i, a in enumerate(cols) for b in cols[i + 1:]
                  if not _pair_compatible(a, b))
    loud = len(_loud(cols))
    scores = [c.get("score") or 0 for c in picked]
    rated = [s for s in scores if s > 0]
    s = 0.0
    s -= 2.0 * clashes
    s -= 0.6 * max(0, loud - 1)
    s += 0.35 * (sum(rated) / len(rated) if rated else 2.5)
    s += 0.4 * sum(1 for c in picked if c.get("is_favorite"))
    s -= 0.5 * sum(1 for c in picked
                   if (_days_since(c.get("last_worn_at")) or 99) <= 2)
    slots = {_slot(c["category"]) for c in picked}
    if "feet" in slots:
        s += 1.0
        if "socks" in slots:
            s += 0.2
    return s + _learned_bonus(picked, pairs)


# --- algorithms ----------------------------------------------------------

def _theme_from_locked(locked, values_of):
    """The theme the user already committed to by locking a cloth.

    Without this, locking an Adidas tee and asking for "same brand" picked a
    brand weighted by wardrobe share — usually not Adidas — and then filled the
    remaining roles from THAT brand. The locked tee stayed, everything around it
    came from somewhere else, and the result looked like the theme was ignored,
    because it was.

    ``values_of`` pulls the candidate theme values out of one cloth (its brand,
    its dominant colours, its cut...). Returns the values worth honouring, most
    specific first, or an empty list when the locked clothes carry none — a
    locked no-brand item cannot say which brand you meant.
    """
    seen = []
    for c in locked or ():
        for v in values_of(c) or ():
            if v and v not in seen:
                seen.append(v)
    return seen


def _dressable_values(pool, values_of, counts):
    """Theme values that can cover an upper AND a lower on their own.

    matching-tag already refused tags that could not dress anybody ("maillot"
    returning a lone t-shirt). The brand, colour and cut themes did not, so they
    would happily pick the colour you own exactly one pair of shorts in, produce
    that pair of shorts, and get thrown away by the wearability check. The draw
    is re-rolled either way, but choosing a value that can work beats rolling
    the dice thirty times and giving up.

    Falls back to every value when none qualifies: an incomplete themed outfit
    is still worth offering when fill_gaps can finish it.
    """
    from collections import defaultdict
    roles = defaultdict(set)
    for c in pool:
        for v in values_of(c) or ():
            if v:
                roles[v].add(c["role"])
    good = {v: n for v, n in counts.items()
            if "onepiece" in roles.get(v, ())
            or ({"bottom"} <= roles.get(v, ()) and roles.get(v, ()) & {"top", "outer"})}
    return good or counts


def _pick_theme(locked, values_of, counts, all_counts=None, avoid=()):
    """Choose a theme value: from the locked clothes when they name one,
    otherwise weighted by how much of it you own.

    ``counts`` is the preferred set (values that can dress a whole outfit);
    ``all_counts`` is every value there is. A locked value is looked up in
    ``all_counts``, never in the preferred set — filtering it there would drop
    the brand the user explicitly pinned just because they own no trousers of
    it, and silently theme the outfit on something else. That is the bug this
    whole function exists to fix; it must not reappear one layer down.

    ``avoid`` holds theme values already used elsewhere in the same run. The
    week planner passes what earlier days landed on: without it, "same brand"
    weighted by wardrobe share picks the brand you own most of on nearly every
    day, and a planned week is seven variations of one brand. Avoided values
    are dropped only while something else remains — a repeated theme beats no
    outfit, and a locked cloth still wins outright.
    """
    known = all_counts if all_counts is not None else counts
    pinned = _theme_from_locked(locked, values_of)
    # A locked cloth the pool filtered out (shorts locked on a cold day) still
    # names the theme: answering with another one would dress it in clothes
    # off the theme it set.
    from_locked = [v for v in pinned if v in known] or pinned
    if from_locked:
        # Several locked clothes can disagree (an Adidas tee and Nike shorts).
        # Honouring one of them beats honouring neither, so pick among those.
        return _random.choice(from_locked)
    if not counts:
        return None
    avoid = {str(v).strip().lower() for v in (avoid or ())}
    keys = [k for k in counts if str(k).strip().lower() not in avoid] or list(counts)
    return _random.choices(keys, weights=[counts[k] for k in keys], k=1)[0]


def _algo_same_brand(pool, locked=(), avoid=(), weather="any"):
    if not pool:
        return []
    from collections import Counter
    counts = Counter(c["brand"] for c in pool if c["brand"])
    if not counts:
        return []
    # A locked cloth decides the brand. Otherwise pick one WEIGHTED by how many
    # items of it you own, so a brand you have a lot of comes up proportionally
    # more often than one you barely own, instead of always the most common.
    target = _pick_theme(locked, lambda c: [c["brand"]],
                         _dressable_values(pool, lambda c: [c["brand"]], counts),
                         all_counts=counts, avoid=avoid)
    if target is None:
        return []
    themed = [c for c in pool if c["brand"] == target]
    # Complete ONLY from the same brand — never mix in another brand's cloth.
    return _compose(themed, weather, locked)


def _algo_single_color(pool, locked=(), avoid=(), weather="any"):
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
    target = _pick_theme(
        locked, lambda c: c.get("dom_colors", ()),
        _dressable_values(pool, lambda c: c.get("dom_colors", ()), counts),
        all_counts=counts, avoid=avoid)
    if target is None:
        return []
    themed = [c for c in pool if target in c.get("dom_colors", ())]
    return _compose(themed, weather, locked)


def _algo_color_match(pool, locked=(), weather="any"):
    """Colours that go together: every piece is checked against the ones
    already chosen, clashes are refused and a second bright colour is rare."""
    if not pool:
        return []
    with_color = [c for c in pool if c["colors"]]
    if not with_color:
        return _algo_random(pool, weather, locked)
    return _compose(with_color, weather, locked, strict_colours=True)


def _extras_for(themed: List[dict], pool: List[dict]) -> List[dict]:
    """Shoes, socks, headwear and bag for a themed outfit: the themed ones
    when the theme has any of that kind, else the wardrobe's."""
    out = list(themed)
    have = {_slot(c["category"]) for c in themed}
    for c in pool:
        s = _slot(c["category"])
        if s in ("feet", "socks", "headwear", "bag") and s not in have:
            out.append(c)
    return out


def _algo_matching_tag(pool, locked=(), avoid=(), weather="any"):
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
    # A locked cloth's tag wins, even one that cannot dress a whole outfit on
    # its own: the user named it. Restricted to candidates so a tag no pool
    # cloth carries does not empty the result.
    target = _pick_theme(locked, lambda c: c["tags"],
                         {t: tag_counts[t] for t in candidates},
                         avoid=avoid,
                         all_counts=tag_counts)
    if target is None:
        return []
    themed = [c for c in pool if target in c["tags"]]
    # Tags are put on clothes far more than on shoes: when no tagged pair
    # exists, shoes and socks come from the rest of the wardrobe.
    return _compose(themed, weather, locked, extras=_extras_for(themed, pool))


def _algo_same_cut(pool, locked=(), avoid=(), weather="any"):
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
    # A locked cloth decides the cut; otherwise weighted by how many you own.
    _cut_of = lambda c: [c["cut"]] if has_cut(c["category"]) else []  # noqa: E731
    target = _pick_theme(locked, _cut_of,
                         _dressable_values(candidates, _cut_of, counts),
                         all_counts=counts, avoid=avoid)
    if target is None:
        return []
    themed = [c for c in candidates if c["cut"] == target]
    # Shoes, socks and caps have no cut: they come from the whole wardrobe.
    return _compose(themed, weather, locked, extras=pool)


def _algo_least_worn(pool, locked=(), weather="any"):
    """Prefer the clothes worn longest ago (never-worn first), so nothing sits
    unused. Each slot draws among its longest-unworn pieces: it used to take
    the first one, and gave the very same outfit every time."""
    if not pool:
        return []
    return _compose(pool, weather, locked, stale_first=True)


def _algo_pick_by_color(pool, color, locked=(), weather="any"):
    if not color or not pool:
        return []
    # Only clothes whose DOMINANT colour is the chosen one — a black jogging with
    # a little white trim must not count as "white".
    themed = [c for c in pool if color in c.get("dom_colors", ())]
    if not themed:
        return []
    # Complete only from themed clothes so the "single color" promise holds.
    return _compose(themed, weather, locked)


def _algo_pick_by_brand(pool, brand, locked=(), weather="any"):
    if not brand or not pool:
        return []
    themed = [c for c in pool if c["brand"].lower() == brand.lower()]
    if not themed:
        return []
    # Complete only from themed clothes so the "single brand" promise holds.
    return _compose(themed, weather, locked)


def _algo_pick_by_tag(pool, tag, locked=(), weather="any"):
    if not tag or not pool:
        return []
    tl = tag.strip().lower()
    themed = [c for c in pool if any(t.lower() == tl for t in c["tags"])]
    if not themed:
        return []
    # Complete only from clothes carrying the chosen tag.
    return _compose(themed, weather, locked)


def _algo_random(pool, weather="any", locked=()):
    """Any wardrobe piece, but still dressed like a person: layers by the
    weather, colours that do not clash, liked and rested pieces first."""
    if not pool:
        return []
    return _compose(pool, weather, locked)


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


def _avoid(r):
    return getattr(r, "avoid_theme_values", ())


_ALGOS = {
    # `locked` is the clothes the user pinned. Themed algorithms take their
    # theme FROM them: locking an Adidas tee and asking for "same brand" must
    # mean Adidas, not whichever brand the wardrobe weighting landed on. The
    # locked clothes are also handed to _compose, which dresses around them.
    "same-brand": lambda p, r, locked: _algo_same_brand(
        p, locked, _avoid(r), r.weather),
    "single-color": lambda p, r, locked: _algo_single_color(
        p, locked, _avoid(r), r.weather),
    "color-match": lambda p, r, locked: _algo_color_match(p, locked, r.weather),
    "matching-tag": lambda p, r, locked: _algo_matching_tag(
        p, locked, _avoid(r), r.weather),
    "same-cut": lambda p, r, locked: _algo_same_cut(
        p, locked, _avoid(r), r.weather),
    "least-worn": lambda p, r, locked: _algo_least_worn(p, locked, r.weather),
    "pick-by-color": lambda p, r, locked: _algo_pick_by_color(
        p, r.color, locked, r.weather),
    "pick-by-brand": lambda p, r, locked: _algo_pick_by_brand(
        p, r.brand, locked, r.weather),
    "pick-by-tag": lambda p, r, locked: _algo_pick_by_tag(
        p, r.tag, locked, r.weather),
    "random": lambda p, r, locked: _algo_random(p, r.weather, locked),
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


def why_empty(req) -> str:
    """A sentence explaining why select() came back with nothing.

    "No clothes match this algorithm (and rating filter). Add more or lower the
    rating." was the only message, and for the case this module now guards
    against it is simply untrue: the clothes match fine, they just cannot make a
    whole outfit between them. Being told to lower a rating filter you never set
    sends you looking in the wrong place.
    """
    theme = {
        "same-brand": "of a single brand",
        "single-color": "of a single colour",
        "pick-by-color": f"in {req.color}" if getattr(req, "color", "") else "in that colour",
        "pick-by-brand": f"from {req.brand}" if getattr(req, "brand", "") else "from that brand",
        "pick-by-tag": f"tagged {req.tag}" if getattr(req, "tag", "") else "with that tag",
        "matching-tag": "sharing a tag",
        "same-cut": "of the same cut",
    }.get(getattr(req, "algo", ""), "")
    if theme:
        return (f"Not enough clothes {theme} to make a whole outfit — a top and "
                f"a bottom, or a one-piece. Add some, or turn on "
                f"\u201cfill gaps with other clothes\u201d.")
    return ("No clothes match this algorithm (and rating filter). Add more or "
            "lower the rating.")


def _is_wearable(picked: List[dict], req) -> bool:
    """Is this something a person could put on?

    Reported as "pour vert ça me génère qu'un short vert sans aucun t-shirt". A
    themed algorithm completes only from within its own theme, so a wardrobe
    whose only green item is a pair of shorts produced an outfit of one pair of
    shorts. An audit over every algorithm found six of the ten could do it:
    single-color, pick-by-color, matching-tag and pick-by-tag every time on such
    a wardrobe, same-brand and same-cut some of the time.

    Wearable means something on top and something on the bottom, or a one-piece
    that is both. Shoes are optional — a missing pair is a gap, not a nonsense.

    Exception: an explicit category list. Asking for shorts only and getting
    shorts only is the feature, not the bug.
    """
    if getattr(req, "categories", None):
        return True
    roles = {c["role"] for c in picked}
    upper = roles & {"top", "outer", "onepiece"}
    lower = roles & {"bottom", "onepiece"}
    return bool(upper and lower)


def theme_value_of(algo: str, picked: List[dict]) -> Optional[str]:
    """The theme a selection ended up on — the brand of a "same brand" outfit,
    the colour of a "single colour" one, and so on.

    Read back from the result rather than returned by ``select`` so the
    signature every caller uses stays a plain list of clothes. The week planner
    feeds it to the next day's ``avoid_theme_values``.
    """
    if not picked:
        return None
    garments = [c for c in picked if c.get("role") in
                ("top", "bottom", "outer", "onepiece")] or picked
    if algo in ("same-brand", "pick-by-brand"):
        brands = {c.get("brand") for c in garments if c.get("brand")}
        return next(iter(brands)) if len(brands) == 1 else None
    if algo in ("single-color", "pick-by-color"):
        shared = None
        for c in garments:
            cols = set(c.get("dom_colors") or c.get("colors") or ())
            shared = cols if shared is None else (shared & cols)
        return next(iter(shared)) if shared and len(shared) == 1 else (
            next(iter(sorted(shared))) if shared else None)
    if algo in ("matching-tag", "pick-by-tag"):
        shared = None
        for c in garments:
            tags = set(c.get("tags") or ())
            shared = tags if shared is None else (shared & tags)
        return next(iter(sorted(shared))) if shared else None
    if algo == "same-cut":
        cuts = {c.get("cut") for c in garments if c.get("cut")}
        return next(iter(cuts)) if len(cuts) == 1 else None
    return None  # untuned algorithms promise no shared property


# Wearable drafts drawn per outfit before keeping one.
_DRAFTS = 5


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
        # Garments earlier days of a plan already used. Applied here rather than
        # in _fetch_pool so the socks/shoes sources below are untouched.
        avoid = getattr(req, "avoid_cloth_ids", None) or set()
        if avoid:
            pool = [c for c in pool
                    if c["id"] not in avoid or c["role"] in AVOID_EXEMPT_ROLES]
        # Socks + shoes sources, independent of the category / theme restriction:
        # hot/cold outfits pair socks WITH shoes even when the chosen types or a
        # colour/brand theme dropped one of them.
        _essentials = _fetch_pool(conn, req.user_id, req.min_score)
        socks_pool = [c for c in _essentials if c["category"] == "socks"]
        feet_pool = [c for c in _essentials if c["role"] == "feet"]
        locked = _fetch_clothes_by_id(conn, req.user_id, locked_ids)
        blacklist = _blacklisted_combos(conn, req.user_id)
        pairs = learned_pairs(conn, req.user_id)
        # An outfit rated 1 or 2 is not offered again as is.
        disliked = {combo_key(json.loads(r["cloth_ids"] or "[]")) for r in conn.execute(
            "SELECT cloth_ids FROM outfits WHERE user_id = ? "
            "AND rating BETWEEN 1 AND 2", (req.user_id,)).fetchall()}

    locked_id_set = {c["id"] for c in locked}

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
            picked = _ALGOS[algo](themed_pool, req, locked)
            core = _dedupe_slots(picked)
        if not locked:
            result = core
        else:
            # Locked clothes always stay; the algo only fills the slots they
            # leave free (a locked t-shirt still gets a hoodie over it).
            locked_slots = set()
            for c in locked:
                locked_slots |= slots_of(c["category"])
            extra = _dedupe_slots([
                c for c in core if c["id"] not in locked_id_set
                and not (slots_of(c["category"]) & locked_slots)
            ])
            result = locked + extra
        # Optionally fill missing core roles (top/bottom/shoes) from ANY cloth —
        # e.g. add other-brand shoes when the chosen brand has none.
        if req.fill_gaps:
            result = _fill_missing_roles(result, pool, algo, req)
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

    # Re-roll past blacklisted combinations, and past draws that are not an
    # outfit at all. Both are re-rolls rather than refusals: single-color that
    # landed on the one colour you own a single garment of will find a workable
    # colour on the next draw, and giving up on the first try would have hidden
    # every outfit the wardrobe could actually make.
    #
    # Deterministic algos converge to empty, which is the honest answer: the
    # caller reports "no outfit" instead of showing a lone pair of shorts.
    #
    # Then the best of a few: several wearable drafts are drawn and one is
    # kept, the better-looking ones (outfit_score) far more likely, so the
    # result is good without always being the same.
    drafts: List[List[dict]] = []
    seen = set()
    for _ in range(30):
        last = _pick_once()
        if not last:
            break
        if not _is_wearable(last, req):
            continue
        key = combo_key([c["id"] for c in last])
        if (blacklist and key in blacklist) or key in disliked:
            continue
        if key not in seen:
            seen.add(key)
            drafts.append(last)
        if len(drafts) >= _DRAFTS:
            break
    if not drafts:
        return []  # only blacklisted or unwearable combos were reachable
    import math
    scores = [outfit_score(d, pairs) for d in drafts]
    best = max(scores)
    weights = [math.exp(2.0 * (sc - best)) for sc in scores]
    return _random.choices(drafts, weights=weights, k=1)[0]


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