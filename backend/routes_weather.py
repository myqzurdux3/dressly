"""Forecast for the days the user is dressing for, and where to look it up.

Kept to reading the forecast and storing a location. What the app does with it
— pre-selecting hot or cold — is the generator's business, and lives there.
"""
import logging
from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel

import weather
from auth import get_current_user
from db import get_conn

router = APIRouter(prefix="/weather", tags=["weather"])
log = logging.getLogger(__name__)


class LocationIn(BaseModel):
    lat: Optional[float] = None
    lon: Optional[float] = None
    place: str = ""


def _location(conn, user_id: int):
    row = conn.execute(
        "SELECT weather_lat, weather_lon, weather_place FROM users WHERE id = ?",
        (user_id,),
    ).fetchone()
    if not row:
        return None, None, ""
    return row["weather_lat"], row["weather_lon"], row["weather_place"] or ""


@router.get("/location")
def get_location(user=Depends(get_current_user)):
    with get_conn() as conn:
        lat, lon, place = _location(conn, user["id"])
    return {"lat": lat, "lon": lon, "place": place, "set": lat is not None}


@router.put("/location")
def set_location(body: LocationIn, user=Depends(get_current_user)):
    """Set — or, with both coordinates null, clear — where to forecast for."""
    lat, lon = body.lat, body.lon
    if (lat is None) != (lon is None):
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            "Give both a latitude and a longitude, or neither to clear it.")
    if lat is not None:
        if not (-90 <= lat <= 90) or not (-180 <= lon <= 180):
            raise HTTPException(
                status.HTTP_400_BAD_REQUEST,
                "That is not a point on Earth (lat -90..90, lon -180..180).")
    place = (body.place or "").strip()[:80]
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET weather_lat = ?, weather_lon = ?, weather_place = ? "
            "WHERE id = ?",
            (lat, lon, place, user["id"]),
        )
    # The old location's forecasts are now answers to a question nobody asked.
    weather.reset_cache()
    return {"lat": lat, "lon": lon, "place": place, "set": lat is not None}


@router.get("/places")
def search_places(q: str = "", lang: str = "en", user=Depends(get_current_user)):
    """Town search, so the settings screen asks for a name and not a latitude.

    A provider outage answers with an empty list: the screen then shows "no
    match", which is a state it has to handle anyway.
    """
    try:
        return {"places": weather.search_places(q, language=(lang or "en")[:5])}
    except weather.WeatherUnavailable as e:
        log.info("place search unavailable: %s", e)
        return {"places": []}


@router.get("")
def day_forecast(day: Optional[str] = None, user=Depends(get_current_user)):
    """The forecast for one day (default today).

    Never an error the app has to handle specially: with no location, an
    unreachable provider or a day too far out, this answers `available: false`
    and `mode: "any"`, which is what the generator did before any of this
    existed.
    """
    target = (day or date.today().isoformat()).strip()
    with get_conn() as conn:
        lat, lon, place = _location(conn, user["id"])
    try:
        got = weather.forecast(lat, lon, target)
    except weather.WeatherUnavailable as e:
        return {"available": False, "day": target, "mode": "any",
                "place": place, "reason": str(e)}
    return {"available": True, "place": place, **got}
