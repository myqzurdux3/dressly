"""Clothes nobody is wearing.

Two clocks, and the reason there are two is a bug report: with a single
"untouched for six months" rule, counted from the day it was added for anything
never worn, a wardrobe younger than six months answered "nothing is forgotten"
next to a hundred garments that had never once been put on.

  * never worn -> listed after a short grace period (this week's uploads are
    not nagged about, but a two-month-old wardrobe still gets an answer);
  * worn and then dropped -> listed after `months`.
"""
import db
from conftest import create_cloth


def _age(cloth_id, *, created_days_ago=None, last_worn_days_ago=None):
    """Move a cloth into the past — there is no other way to have a wardrobe
    with history inside a test that starts with an empty database."""
    with db.get_conn() as conn:
        if created_days_ago is not None:
            conn.execute(
                "UPDATE clothes SET created_at = datetime('now', ?) WHERE id = ?",
                (f"-{created_days_ago} days", cloth_id))
        if last_worn_days_ago is not None:
            conn.execute(
                "UPDATE clothes SET last_worn_at = date('now', ?) WHERE id = ?",
                (f"-{last_worn_days_ago} days", cloth_id))


def _dormant(client, auth, **params):
    q = "&".join(f"{k}={v}" for k, v in params.items())
    r = client.get(f"/clothes/dormant{'?' + q if q else ''}", headers=auth)
    assert r.status_code == 200, r.text
    return r.json()


def _names(body):
    return [c["name"] for c in body["items"]]


# --- what counts as dormant ----------------------------------------------

def test_a_cloth_worn_recently_is_not_listed(client, auth):
    c = create_cloth(client, auth, name="Daily Tee")
    _age(c["id"], created_days_ago=400, last_worn_days_ago=3)
    assert _names(_dormant(client, auth)) == []


def test_a_cloth_not_worn_for_months_is_listed(client, auth):
    c = create_cloth(client, auth, name="Forgotten Shirt")
    _age(c["id"], created_days_ago=400, last_worn_days_ago=300)
    body = _dormant(client, auth)
    assert _names(body) == ["forgotten shirt"]
    item = body["items"][0]
    assert item["never_worn"] is False
    assert 295 <= item["dormant_days"] <= 305, item["dormant_days"]


def test_something_added_yesterday_is_not_already_forgotten(client, auth):
    """The grace period: a garment photographed this week is not yet evidence of
    anything, and nagging about it is how the list would lose its credibility."""
    fresh = create_cloth(client, auth, name="Brand New")
    _age(fresh["id"], created_days_ago=1)
    assert _names(_dormant(client, auth)) == []


def test_the_report_a_young_wardrobe_nobody_wears(client, auth):
    """The bug, stated directly: ten garments, never worn, added two months ago
    — younger than the six-month threshold, so the old single rule showed an
    empty list next to a full wardrobe."""
    for i in range(10):
        c = create_cloth(client, auth, name=f"Never worn {i}")
        _age(c["id"], created_days_ago=60)
    body = _dormant(client, auth)
    assert body["count"] == 10, "a wardrobe of never-worn clothes reads as empty"
    assert body["never_worn_count"] == 10
    assert body["stale_count"] == 0


def test_the_two_clocks_are_independent(client, auth):
    """A garment worn two months ago is NOT dormant at six months; one never
    worn for two months is. Same age, different question."""
    never = create_cloth(client, auth, name="Never Worn")
    _age(never["id"], created_days_ago=60)
    dropped = create_cloth(client, auth, name="Worn Recently")
    _age(dropped["id"], created_days_ago=60, last_worn_days_ago=60)

    body = _dormant(client, auth, months=6)
    assert _names(body) == ["never worn"]
    assert body["never_worn_count"] == 1 and body["stale_count"] == 0

    # Lower the threshold and the dropped one joins it.
    body = _dormant(client, auth, months=1)
    assert set(_names(body)) == {"never worn", "worn recently"}
    assert body["never_worn_count"] == 1 and body["stale_count"] == 1


def test_the_grace_period_is_short_enough_to_be_useful(client, auth):
    """Long enough not to nag about this week, short enough that a new wardrobe
    is not told it has nothing to look at."""
    c = create_cloth(client, auth, name="Month Old")
    _age(c["id"], created_days_ago=30)
    body = _dormant(client, auth)
    assert _names(body) == ["month old"]
    assert body["grace_days"] <= 30


def test_never_worn_but_old_is_the_clearest_case(client, auth):
    """Bought, photographed, never once put on."""
    c = create_cloth(client, auth, name="Tag Still On")
    _age(c["id"], created_days_ago=400)
    body = _dormant(client, auth)
    assert _names(body) == ["tag still on"]
    item = body["items"][0]
    assert item["never_worn"] is True
    assert item["times_worn"] == 0
    assert 395 <= item["dormant_days"] <= 405


def test_the_longest_forgotten_comes_first(client, auth):
    a = create_cloth(client, auth, name="Two Years")
    b = create_cloth(client, auth, name="Eight Months")
    c = create_cloth(client, auth, name="Seven Months")
    _age(a["id"], created_days_ago=900, last_worn_days_ago=730)
    _age(b["id"], created_days_ago=900, last_worn_days_ago=240)
    _age(c["id"], created_days_ago=900, last_worn_days_ago=210)
    assert _names(_dormant(client, auth)) == \
        ["two years", "eight months", "seven months"]


def test_wearing_it_takes_it_off_the_list(client, auth):
    """The list is a prompt to act, so acting has to clear it — through the
    ordinary 'worn today' button, not a special one."""
    c = create_cloth(client, auth, name="Rescued")
    _age(c["id"], created_days_ago=400, last_worn_days_ago=300)
    assert _names(_dormant(client, auth)) == ["rescued"]

    assert client.post(f"/clothes/{c['id']}/wear", headers=auth,
                       json={}).status_code == 200
    assert _names(_dormant(client, auth)) == []


# --- the threshold --------------------------------------------------------

def test_the_threshold_moves(client, auth):
    c = create_cloth(client, auth, name="Three Months")
    _age(c["id"], created_days_ago=400, last_worn_days_ago=100)
    assert _names(_dormant(client, auth, months=6)) == []
    assert _names(_dormant(client, auth, months=3)) == ["three months"]


def test_an_absurd_threshold_is_clamped_not_obeyed(client, auth):
    """months=0 would report the entire wardrobe as forgotten, which is the
    opposite of what the screen promises."""
    c = create_cloth(client, auth, name="Worn Today")
    _age(c["id"], created_days_ago=400, last_worn_days_ago=0)
    body = _dormant(client, auth, months=0)
    assert body["months"] == 1
    assert _names(body) == []
    assert _dormant(client, auth, months=9999)["months"] == 60
    # Not a number at all is a broken request, not a threshold to guess at.
    assert client.get("/clothes/dormant?months=nonsense",
                      headers=auth).status_code == 422


# --- what the screen needs ------------------------------------------------

def test_the_totals_describe_the_whole_wardrobe(client, auth):
    for i in range(3):
        c = create_cloth(client, auth, name=f"Old {i}")
        _age(c["id"], created_days_ago=400, last_worn_days_ago=300)
    for i in range(2):
        c = create_cloth(client, auth, name=f"Current {i}")
        _age(c["id"], created_days_ago=400, last_worn_days_ago=2)
    body = _dormant(client, auth)
    assert body["count"] == 3
    assert body["stale_count"] == 3       # all three were worn, then dropped
    assert body["never_worn_count"] == 0
    assert body["wardrobe_count"] == 5


def test_paging_does_not_shrink_the_count(client, auth):
    """The header says "12 dormant"; asking for one page must not turn that
    into "1 dormant"."""
    for i in range(4):
        c = create_cloth(client, auth, name=f"Old {i}")
        _age(c["id"], created_days_ago=400, last_worn_days_ago=300 + i)
    body = _dormant(client, auth, limit=2)
    assert len(body["items"]) == 2
    assert body["count"] == 4
    second = _dormant(client, auth, limit=2, offset=2)
    assert _names(second) != _names(body)
    assert len(second["items"]) == 2


def test_an_item_carries_everything_the_card_shows(client, auth):
    """The same shape as any other cloth listing, so the existing card widget
    can render it — plus why it is here."""
    c = create_cloth(client, auth, name="Full Card", category="jeans")
    _age(c["id"], created_days_ago=400, last_worn_days_ago=300)
    item = _dormant(client, auth)["items"][0]
    assert item["id"] == c["id"]
    assert item["category"] == "jeans"
    assert item["images"], "no photo to show"
    assert item["images"][0]["thumb_url"]
    assert item["dormant_since"] and item["dormant_days"] > 0


def test_times_worn_counts_the_days_it_was_worn(client, auth):
    """"Worn 3 times, and not since March" reads differently from "never worn"."""
    c = create_cloth(client, auth, name="Sometimes")
    for day in ("2026-01-01", "2026-01-02", "2026-01-03"):
        client.post(f"/clothes/{c['id']}/wear", headers=auth, json={"day": day})
    _age(c["id"], created_days_ago=400, last_worn_days_ago=300)
    item = _dormant(client, auth)["items"][0]
    assert item["times_worn"] == 3
    assert item["never_worn"] is False


def test_another_wardrobe_is_not_included(client, auth):
    mine = create_cloth(client, auth, name="Mine")
    _age(mine["id"], created_days_ago=400, last_worn_days_ago=300)
    other = client.post("/auth/signup",
                        json={"email": "n@n.co", "password": "pw123456"}).json()
    oh = {"Authorization": f"Bearer {other['token']}"}
    theirs = create_cloth(client, oh, name="Theirs")
    _age(theirs["id"], created_days_ago=400, last_worn_days_ago=300)

    assert _names(_dormant(client, auth)) == ["mine"]
    assert _names(_dormant(client, oh)) == ["theirs"]


def test_it_needs_a_token(client):
    assert client.get("/clothes/dormant").status_code == 401


def test_an_empty_wardrobe_answers_calmly(client, auth):
    body = _dormant(client, auth)
    assert body["count"] == 0
    assert body["never_worn_count"] == 0
    assert body["stale_count"] == 0
    assert body["wardrobe_count"] == 0
    assert body["items"] == []
