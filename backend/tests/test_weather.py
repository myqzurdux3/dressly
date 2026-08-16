"""Dressing for the actual weather, without being asked which weather it is.

The generator has always understood weather='hot'|'cold'; somebody had to press
the right button every morning. 'auto' asks the forecast instead.

The provider is never called here: `weather._fetch` is replaced in every test
that needs an answer. A test suite that reaches the internet fails on a train.
"""
from datetime import date, timedelta

import pytest

import weather
from conftest import create_cloth


@pytest.fixture(autouse=True)
def no_network(monkeypatch):
    """Any test that forgets to stub the provider fails loudly instead of
    quietly waiting on a socket."""
    def explode(*a, **kw):
        raise AssertionError("a test tried to reach the real weather API")

    monkeypatch.setattr(weather, "_fetch", explode)
    monkeypatch.setattr(weather, "_geocode_fetch", explode)
    weather.reset_cache()
    yield
    weather.reset_cache()


def _stub(monkeypatch, temp_max, temp_min=None, calls=None):
    def fake_fetch(lat, lon, day):
        if calls is not None:
            calls.append((lat, lon, day))
        return {"daily": {
            "temperature_2m_max": [temp_max],
            "temperature_2m_min": [temp_min if temp_min is not None else temp_max - 6],
            "weather_code": [1],
        }}

    monkeypatch.setattr(weather, "_fetch", fake_fetch)


def _today():
    return date.today().isoformat()


def _set_location(client, auth, lat=48.85, lon=2.35, place="Paris"):
    r = client.put("/weather/location", headers=auth,
                   json={"lat": lat, "lon": lon, "place": place})
    assert r.status_code == 200, r.text
    return r.json()


# --- reading a forecast ---------------------------------------------------

def test_a_warm_day_is_hot_a_cool_one_is_cold(monkeypatch):
    _stub(monkeypatch, 26.0)
    assert weather.forecast(48.85, 2.35, _today())["mode"] == "hot"
    weather.reset_cache()
    _stub(monkeypatch, 9.0)
    assert weather.forecast(48.85, 2.35, _today())["mode"] == "cold"


def test_the_daily_maximum_decides_not_the_minimum(monkeypatch):
    """You dress for the afternoon. A 4 °C dawn under a 24 °C day is not a coat
    day, and treating it as one is how the feature would lose its credibility."""
    _stub(monkeypatch, 24.0, temp_min=4.0)
    got = weather.forecast(48.85, 2.35, _today())
    assert got["mode"] == "hot"
    assert got["temp_min"] == 4.0


def test_the_same_day_is_fetched_once(monkeypatch):
    """A forecast per outfit draw would put a network round trip inside every
    generation."""
    calls = []
    _stub(monkeypatch, 25.0, calls=calls)
    for _ in range(5):
        weather.forecast(48.85, 2.35, _today())
    assert len(calls) == 1


def test_two_nearby_points_share_one_lookup(monkeypatch):
    """Keyed to about a kilometre: GPS jitter must not miss the cache."""
    calls = []
    _stub(monkeypatch, 25.0, calls=calls)
    weather.forecast(48.8566, 2.3522, _today())
    weather.forecast(48.8571, 2.3519, _today())
    assert len(calls) == 1


def test_a_different_city_is_its_own_forecast(monkeypatch):
    calls = []
    _stub(monkeypatch, 25.0, calls=calls)
    weather.forecast(48.85, 2.35, _today())
    weather.forecast(59.91, 10.75, _today())
    assert len(calls) == 2


# --- when there is no answer ---------------------------------------------

def test_no_location_is_not_an_error_it_is_no_forecast():
    with pytest.raises(weather.WeatherUnavailable):
        weather.forecast(None, None, _today())


def test_a_day_beyond_the_forecast_is_refused_before_the_network():
    far = (date.today() + timedelta(days=weather.MAX_FORECAST_DAYS + 5)).isoformat()
    # _fetch is the exploding stub: reaching it would fail the test.
    with pytest.raises(weather.WeatherUnavailable):
        weather.forecast(48.85, 2.35, far)


def test_a_past_day_has_no_forecast():
    with pytest.raises(weather.WeatherUnavailable):
        weather.forecast(48.85, 2.35, "2020-01-01")


def test_nonsense_coordinates_are_refused():
    with pytest.raises(weather.WeatherUnavailable):
        weather.forecast(120.0, 2.35, _today())


def test_a_provider_outage_becomes_any_not_an_exception(monkeypatch):
    """The one rule this module has: never stop somebody choosing an outfit."""
    def boom(lat, lon, day):
        raise weather.WeatherUnavailable("provider down")

    monkeypatch.setattr(weather, "_fetch", boom)
    assert weather.mode_for(48.85, 2.35, _today()) == "any"


def test_an_unexpected_crash_also_becomes_any(monkeypatch):
    def boom(lat, lon, day):
        raise RuntimeError("something nobody predicted")

    monkeypatch.setattr(weather, "_fetch", boom)
    assert weather.mode_for(48.85, 2.35, _today()) == "any"


def test_a_reply_without_a_temperature_is_not_guessed_at(monkeypatch):
    monkeypatch.setattr(weather, "_fetch",
                        lambda lat, lon, day: {"daily": {"temperature_2m_max": []}})
    with pytest.raises(weather.WeatherUnavailable):
        weather.forecast(48.85, 2.35, _today())


# --- the location, over HTTP ---------------------------------------------

def test_location_starts_unset(client, auth):
    body = client.get("/weather/location", headers=auth).json()
    assert body["set"] is False and body["lat"] is None


def test_setting_and_clearing_a_location(client, auth):
    assert _set_location(client, auth)["place"] == "Paris"
    got = client.get("/weather/location", headers=auth).json()
    assert got["set"] is True and got["lat"] == 48.85

    cleared = client.put("/weather/location", headers=auth,
                         json={"lat": None, "lon": None})
    assert cleared.status_code == 200
    assert client.get("/weather/location", headers=auth).json()["set"] is False


def test_half_a_location_is_refused(client, auth):
    r = client.put("/weather/location", headers=auth, json={"lat": 48.85})
    assert r.status_code == 400
    assert "both" in r.json()["detail"].lower()


def test_a_point_off_the_planet_is_refused(client, auth):
    r = client.put("/weather/location", headers=auth,
                   json={"lat": 91.0, "lon": 2.0})
    assert r.status_code == 400


def test_changing_location_drops_the_cached_forecast(client, auth, monkeypatch):
    """Otherwise moving from Oslo to Nice keeps answering for Oslo for an hour."""
    calls = []
    _stub(monkeypatch, 25.0, calls=calls)
    _set_location(client, auth, 59.91, 10.75, "Oslo")
    client.get("/weather", headers=auth)
    _set_location(client, auth, 43.70, 7.26, "Nice")
    client.get("/weather", headers=auth)
    assert len(calls) == 2
    assert calls[-1][0] == 43.70


def test_the_forecast_endpoint_answers_for_today(client, auth, monkeypatch):
    _stub(monkeypatch, 27.0)
    _set_location(client, auth)
    body = client.get("/weather", headers=auth).json()
    assert body["available"] is True
    assert body["mode"] == "hot"
    assert body["day"] == _today()
    assert body["place"] == "Paris"


def test_the_forecast_endpoint_degrades_instead_of_failing(client, auth):
    """No location set: a 200 saying "no forecast", not a 4xx the app has to
    special-case on a screen that otherwise works."""
    body = client.get("/weather", headers=auth).json()
    assert body["available"] is False
    assert body["mode"] == "any"
    assert body["reason"]

def test_weather_needs_a_token(client):
    assert client.get("/weather").status_code == 401
    assert client.get("/weather/location").status_code == 401


# --- finding the place ----------------------------------------------------

def _stub_places(monkeypatch, results, seen=None):
    def fake(name, language, count):
        if seen is not None:
            seen.append((name, language, count))
        return {"results": results}

    monkeypatch.setattr(weather, "_geocode_fetch", fake)


def test_searching_a_town_returns_its_coordinates(client, auth, monkeypatch):
    _stub_places(monkeypatch, [{
        "name": "Lyon", "country": "France", "admin1": "Auvergne-Rhône-Alpes",
        "latitude": 45.75, "longitude": 4.85,
    }])
    body = client.get("/weather/places?q=lyon", headers=auth).json()
    assert body["places"] == [{
        "name": "Lyon", "country": "France", "admin": "Auvergne-Rhône-Alpes",
        "lat": 45.75, "lon": 4.85,
    }]


def test_a_one_letter_query_is_not_sent_anywhere(client, auth):
    """The provider is not asked what every place beginning with 'l' is called
    — and _geocode_fetch is the exploding stub, so reaching it fails here."""
    assert client.get("/weather/places?q=l", headers=auth).json()["places"] == []


def test_a_result_without_coordinates_is_dropped(client, auth, monkeypatch):
    _stub_places(monkeypatch, [
        {"name": "Nowhere", "latitude": None, "longitude": None},
        {"name": "Nice", "country": "France", "latitude": 43.7, "longitude": 7.26},
    ])
    places = client.get("/weather/places?q=ni", headers=auth).json()["places"]
    assert [p["name"] for p in places] == ["Nice"]


def test_a_search_outage_is_an_empty_list_not_a_500(client, auth, monkeypatch):
    def boom(*a, **kw):
        raise weather.WeatherUnavailable("geocoder down")

    monkeypatch.setattr(weather, "_geocode_fetch", boom)
    r = client.get("/weather/places?q=paris", headers=auth)
    assert r.status_code == 200
    assert r.json()["places"] == []


# --- and what it is all for ----------------------------------------------

def _wardrobe(client, auth):
    create_cloth(client, auth, name="Tee", category="tshirt")
    create_cloth(client, auth, name="Shorts", category="shorts")
    create_cloth(client, auth, name="Hoodie", category="hoodie")
    create_cloth(client, auth, name="Jeans", category="jeans")


def _preview(client, auth, **body):
    return client.post("/outfits/preview-algo", headers=auth,
                       json={"algo": "random", "count": 1, **body})


def test_auto_dresses_for_a_hot_day(client, auth, monkeypatch):
    _stub(monkeypatch, 29.0)
    _set_location(client, auth)
    _wardrobe(client, auth)
    r = _preview(client, auth, weather="auto")
    assert r.status_code == 200, r.text
    assert r.json()["weather"] == "hot"
    cats = {c["category"] for c in r.json()["selections"][0]}
    assert "hoodie" not in cats and "jeans" not in cats, cats


def test_auto_dresses_for_a_cold_day(client, auth, monkeypatch):
    _stub(monkeypatch, 4.0)
    _set_location(client, auth)
    _wardrobe(client, auth)
    r = _preview(client, auth, weather="auto")
    assert r.status_code == 200, r.text
    assert r.json()["weather"] == "cold"
    cats = {c["category"] for c in r.json()["selections"][0]}
    assert "shorts" not in cats and "tshirt" not in cats, cats


def test_auto_without_a_location_behaves_exactly_as_before(client, auth):
    """The fallback has to be the old behaviour, not an empty wardrobe: someone
    who never sets a location must not notice this feature exists."""
    _wardrobe(client, auth)
    r = _preview(client, auth, weather="auto")
    assert r.status_code == 200, r.text
    assert r.json()["weather"] == "any"
    assert r.json()["selections"][0]


def test_auto_survives_the_provider_being_down(client, auth, monkeypatch):
    monkeypatch.setattr(weather, "_fetch",
                        lambda *a, **kw: (_ for _ in ()).throw(
                            weather.WeatherUnavailable("down")))
    _set_location(client, auth)
    _wardrobe(client, auth)
    r = _preview(client, auth, weather="auto")
    assert r.status_code == 200, r.text
    assert r.json()["weather"] == "any"


def test_an_explicit_choice_still_wins(client, auth, monkeypatch):
    """The forecast is a default, not a rule: asking for cold in a heatwave is
    allowed, and must not trigger a lookup at all."""
    calls = []
    _stub(monkeypatch, 30.0, calls=calls)
    _set_location(client, auth)
    _wardrobe(client, auth)
    r = _preview(client, auth, weather="cold")
    assert r.json()["weather"] == "cold"
    cats = {c["category"] for c in r.json()["selections"][0]}
    assert "shorts" not in cats
    assert calls == [], "an explicit choice asked the forecast anyway"


def test_a_batch_of_proposals_looks_the_forecast_up_once(client, auth, monkeypatch):
    calls = []
    _stub(monkeypatch, 28.0, calls=calls)
    _set_location(client, auth)
    _wardrobe(client, auth)
    r = _preview(client, auth, weather="auto", count=4)
    assert r.status_code == 200, r.text
    assert len(calls) == 1, f"{len(calls)} forecast lookups for one batch"


def test_auto_can_target_another_day(client, auth, monkeypatch):
    """Planning Thursday's outfit asks about Thursday, not about today."""
    seen = []
    _stub(monkeypatch, 25.0, calls=seen)
    _set_location(client, auth)
    _wardrobe(client, auth)
    thursday = (date.today() + timedelta(days=3)).isoformat()
    r = _preview(client, auth, weather="auto", weather_day=thursday)
    assert r.status_code == 200, r.text
    assert seen and seen[-1][2] == thursday


def test_generate_from_algo_also_understands_auto(client, auth, monkeypatch):
    _stub(monkeypatch, 30.0)
    _set_location(client, auth)
    _wardrobe(client, auth)
    r = client.post("/outfits/generate-from-algo", headers=auth,
                    json={"algo": "random", "weather": "auto"})
    assert r.status_code == 200, r.text
