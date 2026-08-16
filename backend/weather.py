"""Forecast lookup, so "hot or cold?" stops being a question the user answers.

The generator has always taken weather='hot'|'cold' and filtered the pool
accordingly. Somebody still had to look out of the window and press the right
button — and press it again tomorrow.

Provider is Open-Meteo: no API key, no account, no per-request quota to leak
into a client, and a plain JSON GET. That last part matters here because it
means no new dependency — urllib, like bfl.py.

Nothing in this module is allowed to break dressing yourself: every failure
path returns "unknown" and the caller falls back to the manual choice.
"""
import json
import logging
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date

log = logging.getLogger(__name__)

BASE_URL = "https://api.open-meteo.com/v1/forecast"
# Same provider, same "no key, no account" terms. Used so the user picks a town
# by name instead of typing latitude and longitude into a settings screen.
GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"

# Above this the day is dressed as hot, below as cold. Uses the daily maximum,
# which is what you dress for — a 6 AM low of 4 °C does not make a 22 °C
# afternoon a coat day.
HOT_ABOVE_C = 20.0

# Open-Meteo serves ~16 days ahead. Past that (and for any past day) there is no
# forecast, only history nobody is dressing for.
MAX_FORECAST_DAYS = 15

HTTP_TIMEOUT_S = 6.0

# A forecast for a given day changes slowly; refetching it per request would
# add a network round trip to every outfit screen. One hour is well inside the
# rate limit and still tracks a changing day.
CACHE_TTL_S = 3600

_cache: dict = {}
_cache_lock = threading.Lock()


class WeatherUnavailable(Exception):
    """No forecast — no location set, provider down, day out of range."""


def _cache_key(lat: float, lon: float, day: str) -> tuple:
    # Rounded to ~1 km: two users in the same city should share one entry, and
    # a GPS jitter of a few metres must not miss the cache.
    return (round(lat, 2), round(lon, 2), day)


def _cached(key):
    with _cache_lock:
        hit = _cache.get(key)
    if not hit:
        return None
    stamped, value = hit
    if time.time() - stamped > CACHE_TTL_S:
        return None
    return value


def _store(key, value):
    with _cache_lock:
        _cache[key] = (time.time(), value)
        # The key space is (location, day) and days age out; a hard cap keeps a
        # long-running process from holding every day it ever looked at.
        if len(_cache) > 512:
            oldest = sorted(_cache.items(), key=lambda kv: kv[1][0])[:128]
            for k, _ in oldest:
                _cache.pop(k, None)


def reset_cache() -> None:
    """Drop everything — for tests, and for a location change."""
    with _cache_lock:
        _cache.clear()


def _fetch(lat: float, lon: float, day: str) -> dict:
    """One day of daily min/max from Open-Meteo. Raises WeatherUnavailable.

    Split out so tests can replace exactly the network call and still exercise
    the caching, the thresholds and the error handling around it.
    """
    query = urllib.parse.urlencode({
        "latitude": f"{lat:.4f}",
        "longitude": f"{lon:.4f}",
        "daily": "temperature_2m_max,temperature_2m_min,weather_code",
        "start_date": day,
        "end_date": day,
        "timezone": "auto",
    })
    url = f"{BASE_URL}?{query}"
    try:
        with urllib.request.urlopen(url, timeout=HTTP_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        raise WeatherUnavailable(f"forecast lookup failed: {e}") from e


def _geocode_fetch(name: str, language: str, count: int) -> dict:
    """Raw town search. Replaced wholesale in tests, like _fetch."""
    query = urllib.parse.urlencode({
        "name": name, "count": count, "language": language, "format": "json",
    })
    try:
        with urllib.request.urlopen(f"{GEOCODE_URL}?{query}",
                                    timeout=HTTP_TIMEOUT_S) as resp:
            return json.loads(resp.read().decode())
    except (urllib.error.URLError, TimeoutError, ValueError) as e:
        raise WeatherUnavailable(f"place lookup failed: {e}") from e


def search_places(name: str, language: str = "en", count: int = 8) -> list:
    """Towns matching ``name``: ``{name, country, admin, lat, lon}``.

    An empty query returns nothing rather than asking the provider what every
    place on Earth is called.
    """
    name = (name or "").strip()
    if len(name) < 2:
        return []
    payload = _geocode_fetch(name, language, max(1, min(int(count), 20)))
    out = []
    for hit in (payload or {}).get("results") or []:
        if hit.get("latitude") is None or hit.get("longitude") is None:
            continue
        out.append({
            "name": hit.get("name") or "",
            "country": hit.get("country") or "",
            "admin": hit.get("admin1") or "",
            "lat": float(hit["latitude"]),
            "lon": float(hit["longitude"]),
        })
    return out


def _days_ahead(day: str) -> int:
    try:
        target = date.fromisoformat(day)
    except (TypeError, ValueError) as e:
        raise WeatherUnavailable(f"not a date: {day!r}") from e
    return (target - date.today()).days


def forecast(lat, lon, day: str) -> dict:
    """``{day, temp_max, temp_min, mode, code}`` for one day at one place.

    ``mode`` is 'hot' or 'cold' — the two the generator understands.
    """
    if lat is None or lon is None:
        raise WeatherUnavailable("no location set")
    lat, lon = float(lat), float(lon)
    if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
        raise WeatherUnavailable(f"location out of range: {lat},{lon}")

    ahead = _days_ahead(day)
    if ahead < 0:
        raise WeatherUnavailable("that day is in the past")
    if ahead > MAX_FORECAST_DAYS:
        raise WeatherUnavailable(
            f"no forecast that far ahead (max {MAX_FORECAST_DAYS} days)")

    key = _cache_key(lat, lon, day)
    hit = _cached(key)
    if hit is not None:
        return hit

    payload = _fetch(lat, lon, day)
    daily = (payload or {}).get("daily") or {}
    highs = daily.get("temperature_2m_max") or []
    lows = daily.get("temperature_2m_min") or []
    codes = daily.get("weather_code") or []
    if not highs or highs[0] is None:
        raise WeatherUnavailable("the forecast came back without a temperature")

    temp_max = float(highs[0])
    result = {
        "day": day,
        "temp_max": temp_max,
        "temp_min": float(lows[0]) if lows and lows[0] is not None else None,
        "code": int(codes[0]) if codes and codes[0] is not None else None,
        "mode": "hot" if temp_max >= HOT_ABOVE_C else "cold",
    }
    _store(key, result)
    return result


def mode_for(lat, lon, day: str) -> str:
    """'hot' | 'cold' | 'any'.

    'any' means "could not tell" — the caller then behaves exactly as it did
    before this module existed, which is the only acceptable failure here: a
    provider outage must not stop somebody choosing an outfit.
    """
    try:
        return forecast(lat, lon, day)["mode"]
    except WeatherUnavailable as e:
        log.info("weather unavailable for %s: %s", day, e)
        return "any"
    except Exception as e:  # noqa: BLE001 - never let this path raise
        log.warning("weather lookup blew up for %s: %s", day, e)
        return "any"
