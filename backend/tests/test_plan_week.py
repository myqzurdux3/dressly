"""A week of outfits planned in one go.

Two properties do the work here: nothing is written until the user accepts, and
the same t-shirt does not come back on Wednesday. Everything else — the
forecast per day, the locked days — is arranged around those two.
"""
from datetime import date, timedelta

import pytest

import db
import weather
from conftest import create_cloth


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    def explode(*a, **kw):
        raise AssertionError("the planner reached the real weather API")

    monkeypatch.setattr(weather, "_fetch", explode)
    weather.reset_cache()
    yield
    weather.reset_cache()


def _wardrobe(client, auth, tops=7, bottoms=7):
    """Enough for a week without repeating, unless a test says otherwise."""
    for i in range(tops):
        create_cloth(client, auth, name=f"Tee {i}", category="tshirt")
    for i in range(bottoms):
        create_cloth(client, auth, name=f"Jeans {i}", category="jeans")
    create_cloth(client, auth, name="Sneakers", category="sneakers")


def _preview(client, auth, **body):
    r = client.post("/agenda/plan/preview", headers=auth,
                    json={"days": 7, "algo": "random", **body})
    assert r.status_code == 200, r.text
    return r.json()


def _apply(client, auth, days, replace=False):
    r = client.post("/agenda/plan/apply", headers=auth,
                    json={"days": days, "replace": replace})
    assert r.status_code == 200, r.text
    return r.json()


def _plan_map(preview):
    return {d["day"]: d["cloth_ids"] for d in preview["days"] if d["cloth_ids"]}


def _garments(day, wardrobe_by_id):
    """The garments only — shoes and socks are allowed to repeat."""
    return [c["id"] for c in day["cloths"]
            if c["category"] not in ("sneakers", "shoes", "socks")]


# --- proposing ------------------------------------------------------------

def test_a_week_is_seven_days_starting_today(client, auth):
    _wardrobe(client, auth)
    body = _preview(client, auth)
    assert len(body["days"]) == 7
    assert body["days"][0]["day"] == date.today().isoformat()
    assert body["days"][-1]["day"] == (
        date.today() + timedelta(days=6)).isoformat()


def test_each_day_gets_a_wearable_outfit(client, auth):
    _wardrobe(client, auth)
    for day in _preview(client, auth)["days"]:
        cats = {c["category"] for c in day["cloths"]}
        assert cats & {"tshirt"}, day
        assert cats & {"jeans"}, day


def test_a_garment_is_not_worn_twice_in_the_week(client, auth):
    """The whole point of planning a week rather than pressing 'random' seven
    times."""
    _wardrobe(client, auth)
    seen = []
    for day in _preview(client, auth)["days"]:
        seen.extend(_garments(day, None))
    assert len(seen) == len(set(seen)), f"a garment came back: {seen}"


def test_shoes_may_repeat_because_nobody_owns_seven_pairs(client, auth):
    _wardrobe(client, auth)
    shoes = [c["id"] for day in _preview(client, auth)["days"]
             for c in day["cloths"] if c["category"] == "sneakers"]
    assert len(shoes) >= 2, "the only pair was used once and then dropped"
    assert len(set(shoes)) == 1


def test_a_small_wardrobe_repeats_and_says_so(client, auth):
    """Two tops cannot dress seven days. Repeating is the honest answer; a hole
    in the week is not — but the day is flagged so the screen can show it."""
    _wardrobe(client, auth, tops=2, bottoms=2)
    days = _preview(client, auth)["days"]
    assert all(d["cloth_ids"] for d in days), "the plan left a day empty"
    assert any(d["repeated"] for d in days), "no day admitted to repeating"


def test_preview_writes_nothing(client, auth):
    _wardrobe(client, auth)
    _preview(client, auth)
    assert client.get("/agenda", headers=auth).json() == []
    with db.get_conn() as conn:
        n = conn.execute("SELECT COUNT(*) AS n FROM outfits").fetchone()["n"]
    assert n == 0, "a preview created outfits"


def test_an_unknown_algo_is_refused(client, auth):
    _wardrobe(client, auth)
    r = client.post("/agenda/plan/preview", headers=auth,
                    json={"algo": "astrology"})
    assert r.status_code == 400


def test_the_window_is_capped(client, auth):
    _wardrobe(client, auth)
    assert len(_preview(client, auth, days=90)["days"]) == 14


def test_a_bad_start_day_is_refused(client, auth):
    r = client.post("/agenda/plan/preview", headers=auth,
                    json={"start_day": "next tuesday"})
    assert r.status_code == 400


# --- locking + regenerating ----------------------------------------------

def test_a_locked_day_comes_back_untouched(client, auth):
    _wardrobe(client, auth)
    first = _preview(client, auth)
    monday = first["days"][0]
    again = _preview(client, auth, keep={monday["day"]: monday["cloth_ids"]})
    kept = again["days"][0]
    assert kept["locked"] is True
    assert kept["cloth_ids"] == monday["cloth_ids"]
    assert kept["cloths"], "a locked day lost its garments"


def test_a_locked_days_clothes_are_not_handed_to_another_day(client, auth):
    """Regenerating around a pinned Monday must not give Tuesday its t-shirt."""
    _wardrobe(client, auth)
    first = _preview(client, auth)
    monday = first["days"][0]
    again = _preview(client, auth, keep={monday["day"]: monday["cloth_ids"]})
    locked_garments = set(_garments(again["days"][0], None))
    for day in again["days"][1:]:
        assert not locked_garments & set(_garments(day, None)), \
            f"{day['day']} took a garment off the locked day"


def test_regenerating_changes_the_unlocked_days(client, auth):
    """With a wardrobe big enough to have alternatives, a second draw must not
    return the identical week — otherwise the button does nothing."""
    _wardrobe(client, auth, tops=14, bottoms=14)
    first = _preview(client, auth)
    monday = first["days"][0]
    again = _preview(client, auth, keep={monday["day"]: monday["cloth_ids"]})
    changed = [a["cloth_ids"] != b["cloth_ids"]
               for a, b in zip(first["days"][1:], again["days"][1:])]
    assert any(changed), "every unlocked day came back identical"


# --- the forecast ---------------------------------------------------------

def _stub_weather(monkeypatch, by_day, default=25.0):
    def fake_fetch(lat, lon, day):
        temp = by_day.get(day, default)
        return {"daily": {"temperature_2m_max": [temp],
                          "temperature_2m_min": [temp - 5],
                          "weather_code": [1]}}

    monkeypatch.setattr(weather, "_fetch", fake_fetch)


def test_each_day_is_dressed_for_its_own_forecast(client, auth, monkeypatch):
    """A cold Tuesday inside a warm week gets the warm clothes, not the week's
    average."""
    today = date.today()
    tuesday = (today + timedelta(days=1)).isoformat()
    _stub_weather(monkeypatch, {tuesday: 2.0})
    client.put("/weather/location", headers=auth,
               json={"lat": 48.85, "lon": 2.35, "place": "Paris"})
    for i in range(4):
        create_cloth(client, auth, name=f"Tee {i}", category="tshirt")
        create_cloth(client, auth, name=f"Short {i}", category="shorts")
        create_cloth(client, auth, name=f"Hoodie {i}", category="hoodie")
        create_cloth(client, auth, name=f"Jeans {i}", category="jeans")
    create_cloth(client, auth, name="Sneakers", category="sneakers")

    days = {d["day"]: d for d in _preview(client, auth, weather="auto")["days"]}
    cold_day = days[tuesday]
    assert cold_day["weather"]["mode"] == "cold"
    cats = {c["category"] for c in cold_day["cloths"]}
    assert "shorts" not in cats and "tshirt" not in cats, cats

    warm_day = days[today.isoformat()]
    assert warm_day["weather"]["mode"] == "hot"


def test_no_location_still_produces_a_plan(client, auth):
    """weather='auto' with nothing to go on falls back to 'any' — the forecast
    is a convenience, not a prerequisite."""
    _wardrobe(client, auth)
    days = _preview(client, auth, weather="auto")["days"]
    assert all(d["cloth_ids"] for d in days)
    assert all(d["weather"]["available"] is False for d in days)


# --- applying -------------------------------------------------------------

def test_applying_fills_the_agenda(client, auth):
    _wardrobe(client, auth)
    plan = _plan_map(_preview(client, auth))
    result = _apply(client, auth, plan)
    assert len(result["created"]) == 7

    entries = client.get("/agenda", headers=auth).json()
    assert len(entries) == 7
    assert {e["day"] for e in entries} == set(plan)
    # Each day carries its clothes, hydrated, with no render behind it.
    for e in entries:
        assert e["outfit"] is not None
        assert e["outfit"]["cloth_ids"], e
        assert e["outfit"]["generated_url"] == ""
        assert e["worn"] is False


def test_a_plan_costs_no_generation(client, auth, monkeypatch):
    """Seven renders is seven paid calls nobody asked for."""
    import routes_outfits

    def explode(*a, **kw):
        raise AssertionError("the planner rendered an outfit")

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", explode)
    _wardrobe(client, auth)
    _apply(client, auth, _plan_map(_preview(client, auth)))


def test_planned_days_stay_out_of_the_outfit_history(client, auth):
    """The history is what you made, not what you intend to wear."""
    _wardrobe(client, auth)
    _apply(client, auth, _plan_map(_preview(client, auth)))
    assert client.get("/outfits", headers=auth).json() == []


def test_a_rendered_plan_day_becomes_an_ordinary_outfit(client, auth):
    _wardrobe(client, auth)
    created = _apply(client, auth, _plan_map(_preview(client, auth)))["created"]
    outfit_id = created[0]["outfit_id"]

    r = client.post(f"/outfits/{outfit_id}/regenerate", headers=auth, json={})
    assert r.status_code == 200, r.text
    from conftest import wait_done
    done = wait_done(client, auth, outfit_id)
    assert done["status"] == "done"
    assert done["generated_url"], "the render produced nothing"
    ids = [o["id"] for o in client.get("/outfits", headers=auth).json()]
    assert outfit_id in ids, "a rendered day never joined the history"


def test_a_day_already_in_the_agenda_is_not_overwritten(client, auth):
    """Somebody scheduled a wedding outfit for Saturday. A plan must not delete
    it."""
    _wardrobe(client, auth)
    plan = _plan_map(_preview(client, auth))
    saturday = sorted(plan)[5]
    existing = client.post("/agenda", headers=auth,
                           json={"day": saturday, "title": "Wedding"})
    assert existing.status_code == 200

    result = _apply(client, auth, plan)
    assert any(s["day"] == saturday and s["reason"] == "already planned"
               for s in result["skipped"])
    kept = [e for e in client.get("/agenda", headers=auth).json()
            if e["day"] == saturday]
    assert [e["title"] for e in kept] == ["Wedding"]


def test_replace_is_explicit(client, auth):
    _wardrobe(client, auth)
    plan = _plan_map(_preview(client, auth))
    day = sorted(plan)[0]
    client.post("/agenda", headers=auth, json={"day": day, "title": "Old"})
    _apply(client, auth, {day: plan[day]}, replace=True)
    titles = [e["title"] for e in client.get("/agenda", headers=auth).json()
              if e["day"] == day]
    assert titles == [""], titles


def test_another_users_clothes_cannot_be_planned(client, auth):
    _wardrobe(client, auth)
    other = client.post("/auth/signup",
                        json={"email": "p@p.co", "password": "pw123456"}).json()
    oh = {"Authorization": f"Bearer {other['token']}"}
    theirs = create_cloth(client, oh, name="Theirs", category="tshirt")
    mine = create_cloth(client, auth, name="Mine", category="tshirt")

    day = date.today().isoformat()
    _apply(client, auth, {day: [mine["id"], theirs["id"]]})
    entry = [e for e in client.get("/agenda", headers=auth).json()
             if e["day"] == day][0]
    assert entry["outfit"]["cloth_ids"] == [mine["id"]]


def test_applying_nothing_is_refused(client, auth):
    r = client.post("/agenda/plan/apply", headers=auth, json={"days": {}})
    assert r.status_code == 400


def test_a_day_with_no_clothes_is_skipped_not_stored(client, auth):
    day = date.today().isoformat()
    r = client.post("/agenda/plan/apply", headers=auth,
                    json={"days": {day: []}})
    assert r.status_code == 400  # nothing at all to apply


# --- reading back ---------------------------------------------------------



def test_a_card_carries_a_picture(client, auth):
    """The plan shows cut-outs, so a garment with no usable image would render
    as a blank card."""
    _wardrobe(client, auth)
    day = _preview(client, auth)["days"][0]
    assert day["cloths"]
    for c in day["cloths"]:
        assert c["thumb_url"], c


def test_planning_needs_a_token(client):
    assert client.post("/agenda/plan/preview", json={}).status_code == 401


# --- the mix of algorithms ------------------------------------------------
#
# Reported: "pour le mode meme marque je ne veux pas que toute la semaine il y
# ait la meme chose donc je veux la possibilite d'utiliser plusieurs algos".
# Two separate answers: several algorithms across the week, and — even with one
# — a different theme each day.

def _branded(client, auth, name, brand, category, **kw):
    import json as _json
    data = {"name": name, "brand": brand, "category": category, "cut": "normal"}
    if kw.get("tags"):
        data["tags"] = _json.dumps(kw["tags"])
    if kw.get("colors"):
        data["colors"] = _json.dumps(
            [{"color": c, "dominance": "full"} for c in kw["colors"]])
    from conftest import make_png
    r = client.post("/clothes", headers=auth, data=data,
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    assert r.status_code == 200, r.text
    return r.json()


def _three_brand_wardrobe(client, auth):
    """Three brands that can each dress you, so a week has real choices."""
    for brand in ("Nike", "Adidas", "Stussy"):
        for i in range(3):
            _branded(client, auth, f"{brand} tee {i}", brand, "tshirt",
                     colors=["Green"], tags=["sport"])
            _branded(client, auth, f"{brand} jeans {i}", brand, "jeans",
                     colors=["Black"], tags=["chic"])
    _branded(client, auth, "Shoes", "Puma", "sneakers")


def test_same_brand_does_not_give_the_same_brand_all_week(client, auth):
    """The report itself. Nike is no bigger than the others here, but the old
    weighting could still land on one brand day after day; now each day is asked
    for a brand the week has not used yet."""
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[{"algo": "same-brand"}])
    brands = []
    for day in body["days"]:
        got = {c["brand"] for c in day["cloths"]
               if c["category"] in ("tshirt", "jeans")}
        brands.append(next(iter(got)) if len(got) == 1 else None)
    assert all(b for b in brands), f"a day mixed brands: {brands}"
    assert len(set(brands)) >= 3, f"the whole week is {set(brands)}"


def test_a_theme_repeats_only_once_the_others_are_spent(client, auth):
    """Three brands over seven days must repeat — but only after all three have
    been used, not from day two."""
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[{"algo": "same-brand"}])
    brands = [next(iter({c["brand"] for c in d["cloths"]
                         if c["category"] in ("tshirt", "jeans")}))
              for d in body["days"]]
    assert set(brands[:3]) == set(brands), "the first three days already repeat"


def test_repeating_a_theme_can_be_asked_for(client, auth):
    """Somebody who genuinely wants a Nike week can still have one."""
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[{"algo": "pick-by-brand",
                                          "brand": "Nike"}])
    brands = {c["brand"] for d in body["days"] for c in d["cloths"]
              if c["category"] in ("tshirt", "jeans")}
    assert brands == {"NIKE"}


def test_several_algorithms_take_turns(client, auth):
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[
        {"algo": "same-brand"}, {"algo": "random"}, {"algo": "least-worn"}])
    used = [d["algo"] for d in body["days"] if not d["locked"]]
    assert set(used) == {"same-brand", "random", "least-worn"}
    # Round-robin, so no two neighbouring days share an algorithm while another
    # one waits its turn.
    assert all(a != b for a, b in zip(used, used[1:])), used


def test_the_response_says_which_algorithm_dressed_each_day(client, auth):
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[{"algo": "same-brand"},
                                         {"algo": "random"}])
    assert body["algos"] == ["same-brand", "random"]
    for day in body["days"]:
        assert day["algo"] in ("same-brand", "random")


def test_a_pick_by_algorithm_without_its_value_is_dropped_not_fatal(client, auth):
    """Ticking "by colour" and forgetting to choose one must not fail the week
    when other algorithms were ticked too."""
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[{"algo": "pick-by-color"},
                                         {"algo": "random"}])
    assert body["algos"] == ["random"]
    assert all(d["cloth_ids"] for d in body["days"])


def test_nothing_usable_in_the_mix_is_refused_clearly(client, auth):
    _three_brand_wardrobe(client, auth)
    r = client.post("/agenda/plan/preview", headers=auth,
                    json={"algos": [{"algo": "pick-by-tag"}]})
    assert r.status_code == 400
    assert "colour, brand or tag" in r.json()["detail"]


def test_the_other_sheet_options_are_honoured(client, auth):
    """min_score, categories and fill_gaps come from the same sheet as normal
    generation — the point of reusing it is that they work here too."""
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[{"algo": "random"}],
                    categories=["tshirt", "jeans"])
    for day in body["days"]:
        cats = {c["category"] for c in day["cloths"]}
        assert cats <= {"tshirt", "jeans"}, cats


def test_a_rating_filter_can_empty_the_week_without_crashing(client, auth):
    _three_brand_wardrobe(client, auth)
    body = _preview(client, auth, algos=[{"algo": "random"}], min_score=5)
    assert all(d["cloth_ids"] == [] for d in body["days"])


# --- display order --------------------------------------------------------

def test_a_day_lists_its_clothes_in_the_order_they_are_worn(client, auth):
    """Shoes, bottom, t-shirt, jacket — the same LAYER_ORDER the render and the
    manual canvas use, not the order the algorithm happened to pick."""
    from conftest import make_png
    for name, cat in (("Veste", "jacket"), ("Tee", "tshirt"),
                      ("Jeans", "jeans"), ("Shoes", "sneakers")):
        client.post("/clothes", headers=auth,
                    data={"name": name, "category": cat, "cut": "normal"},
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    body = _preview(client, auth, algos=[{"algo": "random"}],
                    categories=["jacket", "tshirt", "jeans", "shoes"])
    day = body["days"][0]
    cats = [c["category"] for c in day["cloths"]]
    order = {"jeans": 0, "tshirt": 1, "jacket": 2, "sneakers": 3}
    ranks = [order[c] for c in cats if c in order]
    assert ranks == sorted(ranks), f"out of order: {cats}"
