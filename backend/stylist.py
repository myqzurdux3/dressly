"""The personal stylist: a Claude conversation with read access to the user's
wardrobe, outfits, agenda and weather, and one write: proposing outfits.

The model never writes to the wardrobe. ``propose_outfit`` only records a
proposal; the user adds it to their outfits from the app with one tap. That
keeps a misread request from creating or changing anything on its own.

The conversation is replayed in full on every turn (``api_messages``), exactly
as the API returned it, because thinking blocks must come back unchanged.
"""
import base64
import io
import json
import logging
import time
from datetime import date, timedelta
from typing import Callable, Dict, List, Optional

import anthropic
from PIL import Image

import weather as weather_mod
from config import (
    ANTHROPIC_API_KEY,
    STYLIST_EFFORT,
    STYLIST_MAX_STEPS,
    STYLIST_MODEL,
    STYLIST_TIMEOUT_S,
)

# The speeds the app offers: (model, effort, server-side refusal fallback).
# Claude Haiku 5.5 has no server-side fallback, so none is sent for it.
MODELS = {
    "fast": ("claude-haiku-5-5", "low", False),
    "balanced": ("claude-sonnet-5-5", "low", True),
    "expert": (STYLIST_MODEL, STYLIST_EFFORT, True),
}
DEFAULT_SPEED = "balanced"

# USD per million tokens: (input, cache write 5 min, cache read, output).
# From https://platform.claude.com/docs/en/about-claude/pricing (2026-11-21).
# Haiku 5.5 costs more past 100k input tokens; a stylist turn never gets there.
PRICES = {
    "claude-haiku-5-5": (0.10, 0.125, 0.01, 0.50),
    "claude-sonnet-5-5": (2.0, 2.50, 0.10, 10.0),
    "claude-opus-5-5": (4.0, 5.0, 0.20, 20.0),
}

# Renders the stylist may start in one turn: they cost money, and a loop
# must not be able to start dozens.
MAX_RENDERS_PER_TURN = 4


def price(model: str, usage: dict) -> float:
    """What one call cost, in USD; 0 for a model not in the table."""
    p = next((v for k, v in PRICES.items() if model.startswith(k)), None)
    if not p:
        return 0.0
    return (usage.get("input_tokens", 0) * p[0]
            + usage.get("cache_write", 0) * p[1]
            + usage.get("cache_read", 0) * p[2]
            + usage.get("output_tokens", 0) * p[3]) / 1_000_000
from generator import layer_sorted, role_of, slots_of

log = logging.getLogger(__name__)

FALLBACK_BETA = "server-side-fallback-2026-07-01"

SYSTEM_PROMPT = """You are the personal stylist inside Dressly, a wardrobe app. \
You talk with one person about what to wear, using only the clothes they own.

How to work:
- The first message of a conversation carries the whole wardrobe, today's \
forecast and the agenda, so most questions need no look-up. Use \
search_wardrobe to filter (by text, category, colour, brand, tag, rating, \
favourites), view_garments to see what pieces actually look like when the \
look matters, get_weather for another day, get_agenda and get_outfits for \
plans and outfits already made.
- Recommend only garments returned by get_wardrobe, by their exact id. Never \
invent a garment, and say so plainly when the wardrobe lacks something.
- Every time you recommend a complete outfit, call propose_outfit with its \
garment ids. Write your short answer first, then make the propose_outfit \
calls in the same reply; nothing needs to follow them. The app shows each proposal as a card the person can add to \
their outfits with one tap. Propose one to three outfits per answer unless \
asked for more.
- A complete outfit has one top, one bottom and shoes; add a layer, socks, a \
cap or accessories when they fit. Never two garments of the same kind.
- Respect the owner's preferences: favour well-rated and favourite pieces, \
never use a garment marked "excluded", avoid what was worn in the last few \
days unless asked, and dress for the weather.
- You can also act, but only when the person asks for it:
  - save_outfit adds an outfit to their outfits as a flat lay (free);
  - render_outfit starts an AI picture of an outfit. It costs money, so only \
when they ask for a render or a picture ("génère-le", "fais le rendu"). \
When they say they like an outfit you proposed and want it generated, \
render that outfit's exact garments. Use person "none" unless they ask to \
see it worn: then a model's id from list_models, or "random";
  - schedule_outfit puts an outfit in the agenda for a day;
  - update_garment changes a garment's rating, favourite or excluded flag;
  - mark_worn records that garments were worn on a day;
  - favorite_outfit stars or unstars an existing outfit;
  - rate_outfit gives an existing outfit a 1-5 rating.
  After acting, say in one sentence what you did.
- Reply in the language the person writes in; in French, use "tu", as the \
app does. Keep answers short and \
concrete: name the pieces, say why in a sentence. Plain, sober tone; no \
slang. Do not list garment ids in your text, the cards show them.
"""


class StylistUnavailable(RuntimeError):
    """No key configured, or the API could not be reached."""


def available() -> bool:
    return bool(ANTHROPIC_API_KEY)


_client: Optional[anthropic.Anthropic] = None


def client() -> anthropic.Anthropic:
    global _client
    if not available():
        raise StylistUnavailable("The stylist is not configured on the server")
    if _client is None:
        _client = anthropic.Anthropic(
            api_key=ANTHROPIC_API_KEY, timeout=STYLIST_TIMEOUT_S, max_retries=2)
    return _client


# --- tools -------------------------------------------------------------------

TOOLS = [
    {
        "name": "get_wardrobe",
        "description": (
            "List the owner's garments, one per line: id, name, brand, "
            "category, cut, colours (dominance), tags, the owner's rating "
            "(0 = unrated, 1-5), favourite, excluded (never use), how many "
            "times worn and when last. Optionally only one category."),
        "input_schema": {
            "type": "object",
            "properties": {
                "category": {
                    "type": "string",
                    "description": "Only this category (e.g. 'jogging'). "
                                   "Empty string for everything."},
            },
            "required": ["category"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "search_wardrobe",
        "description": (
            "Search the garments. Every filter is optional: pass an empty "
            "string, 0 or false to ignore it. 'text' matches name, brand, cut "
            "and tags. Same columns as get_wardrobe."),
        "input_schema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "category": {"type": "string"},
                "color": {"type": "string",
                          "description": "English colour name, e.g. 'Black'."},
                "brand": {"type": "string"},
                "tag": {"type": "string"},
                "min_rating": {"type": "integer", "description": "0-5"},
                "favorites_only": {"type": "boolean"},
                "include_excluded": {"type": "boolean"},
            },
            "required": ["text", "category", "color", "brand", "tag",
                         "min_rating", "favorites_only", "include_excluded"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "view_garments",
        "description": (
            "See photos of up to 6 garments, to judge shape, texture, print "
            "or exact shade."),
        "input_schema": {
            "type": "object",
            "properties": {
                "cloth_ids": {"type": "array", "items": {"type": "integer"}},
            },
            "required": ["cloth_ids"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "get_weather",
        "description": (
            "Forecast for one day at the owner's saved place: min/max "
            "temperature in Celsius and whether it is a hot or cold day. "
            "Up to about two weeks ahead."),
        "input_schema": {
            "type": "object",
            "properties": {
                "day": {"type": "string",
                        "description": "YYYY-MM-DD; empty string for today."},
            },
            "required": ["day"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "get_agenda",
        "description": (
            "What is planned in the agenda for the coming days, and which "
            "garments were worn over the last two weeks."),
        "input_schema": {
            "type": "object",
            "properties": {
                "days": {"type": "integer",
                         "description": "How many days ahead, 1-14."},
            },
            "required": ["days"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "get_outfits",
        "description": (
            "Outfits the owner already made (newest first): id, favourite, "
            "and the garments in each."),
        "input_schema": {
            "type": "object",
            "properties": {
                "favorites_only": {"type": "boolean"},
            },
            "required": ["favorites_only"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "propose_outfit",
        "description": (
            "Show the owner one recommended outfit as a card they can add to "
            "their outfits. Use garment ids from get_wardrobe only."),
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string",
                          "description": "A few words, e.g. 'Rainy Monday'."},
                "cloth_ids": {"type": "array", "items": {"type": "integer"}},
                "reason": {"type": "string",
                           "description": "One sentence: why this works."},
            },
            "required": ["title", "cloth_ids", "reason"],
            "additionalProperties": False,
        },
        "strict": True,
    },
]


_PERSON = ('"none" (just the clothes), "random", "random_male", '
           '"random_female", or a model id from list_models as text.')
TOOLS += [
    {
        "name": "save_outfit",
        "description": "Add an outfit to the owner's outfits as a flat lay "
                       "of the garments. Free. Shown as a card.",
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "cloth_ids": {"type": "array", "items": {"type": "integer"}},
                "reason": {"type": "string"},
            },
            "required": ["title", "cloth_ids", "reason"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "render_outfit",
        "description": "Start an AI picture of an outfit (paid, about a "
                       "minute). Only when the owner asks for it. Shown as "
                       "a card that opens the render.",
        "input_schema": {
            "type": "object",
            "properties": {
                "title": {"type": "string"},
                "cloth_ids": {"type": "array", "items": {"type": "integer"}},
                "person": {"type": "string", "description": _PERSON},
            },
            "required": ["title", "cloth_ids", "person"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "list_models",
        "description": "The people (models) an outfit can be rendered on.",
        "input_schema": {"type": "object", "properties": {},
                         "additionalProperties": False},
        "strict": True,
    },
    {
        "name": "schedule_outfit",
        "description": "Put an outfit in the agenda. Give outfit_id for an "
                       "existing outfit (0 otherwise) or cloth_ids to save "
                       "them as a new outfit first.",
        "input_schema": {
            "type": "object",
            "properties": {
                "day": {"type": "string", "description": "YYYY-MM-DD"},
                "outfit_id": {"type": "integer"},
                "cloth_ids": {"type": "array", "items": {"type": "integer"}},
                "title": {"type": "string"},
            },
            "required": ["day", "outfit_id", "cloth_ids", "title"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "update_garment",
        "description": "Change a garment's rating (0-5, -1 to keep), "
                       "favourite and excluded flags ('yes', 'no' or 'keep').",
        "input_schema": {
            "type": "object",
            "properties": {
                "cloth_id": {"type": "integer"},
                "rating": {"type": "integer"},
                "favorite": {"type": "string", "enum": ["yes", "no", "keep"]},
                "excluded": {"type": "string", "enum": ["yes", "no", "keep"]},
            },
            "required": ["cloth_id", "rating", "favorite", "excluded"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "mark_worn",
        "description": "Record that garments were worn on a day "
                       "(empty day = today).",
        "input_schema": {
            "type": "object",
            "properties": {
                "cloth_ids": {"type": "array", "items": {"type": "integer"}},
                "day": {"type": "string"},
            },
            "required": ["cloth_ids", "day"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "favorite_outfit",
        "description": "Star (true) or unstar (false) an existing outfit.",
        "input_schema": {
            "type": "object",
            "properties": {
                "outfit_id": {"type": "integer"},
                "favorite": {"type": "boolean"},
            },
            "required": ["outfit_id", "favorite"],
            "additionalProperties": False,
        },
        "strict": True,
    },
    {
        "name": "rate_outfit",
        "description": ("Rate an existing outfit from 1 to 5 (0 clears the "
                        "rating). Ratings teach the outfit generator which "
                        "pieces go well together."),
        "input_schema": {
            "type": "object",
            "properties": {
                "outfit_id": {"type": "integer"},
                "rating": {"type": "integer", "enum": [0, 1, 2, 3, 4, 5]},
            },
            "required": ["outfit_id", "rating"],
            "additionalProperties": False,
        },
        "strict": True,
    },
]

# Tools that change the owner's data, carried out by the route (it has the
# user and the other routers); see routes_stylist._Actions.
ACTION_TOOLS = {"save_outfit", "render_outfit", "list_models",
                "schedule_outfit", "update_garment", "mark_worn",
                "favorite_outfit", "rate_outfit"}
# Tools whose result the owner already sees as a card: a turn that only made
# cards, and already said something, needs no wrap-up call.
CARD_TOOLS = {"propose_outfit", "save_outfit", "render_outfit"}


def _wardrobe(conn, user_id: int, category: str = "", *, text: str = "",
              color: str = "", brand: str = "", tag: str = "",
              min_rating: int = 0, favorites_only: bool = False,
              include_excluded: bool = True) -> str:
    params: list = [user_id]
    where = ["c.user_id = ?"]
    if category.strip():
        where.append("c.category = ?")
        params.append(category.strip().lower())
    if brand.strip():
        where.append("c.brand LIKE ?")
        params.append(f"%{brand.strip()}%")
    if tag.strip():
        where.append("c.custom_tags LIKE ?")
        params.append(f"%{tag.strip()}%")
    if text.strip():
        where.append("(c.name LIKE ? OR c.brand LIKE ? OR c.cut LIKE ? "
                     "OR c.custom_tags LIKE ? OR c.category LIKE ?)")
        params += [f"%{text.strip()}%"] * 5
    if color.strip():
        where.append("EXISTS (SELECT 1 FROM cloth_colors k WHERE "
                     "k.cloth_id = c.id AND k.color = ? COLLATE NOCASE)")
        params.append(color.strip())
    if min_rating:
        where.append("c.score >= ?")
        params.append(int(min_rating))
    if favorites_only:
        where.append("c.is_favorite = 1")
    if not include_excluded:
        where.append("c.exclude_from_algo = 0")
    rows = conn.execute(
        "SELECT c.id, c.name, c.brand, c.category, c.cut, c.custom_tags, "
        "c.score, c.is_favorite, c.exclude_from_algo, c.last_worn_at, "
        "substr(c.created_at, 1, 10) AS added, "
        "(SELECT COUNT(*) FROM cloth_wears w WHERE w.cloth_id = c.id) AS wears "
        f"FROM clothes c WHERE {' AND '.join(where)} ORDER BY c.category, c.name",
        params).fetchall()
    if not rows:
        return "No garment matches."
    colors: Dict[int, List[str]] = {}
    ids = [r["id"] for r in rows]
    ph = ",".join("?" * len(ids))
    for c in conn.execute(
            f"SELECT cloth_id, color, dominance FROM cloth_colors "
            f"WHERE cloth_id IN ({ph})", ids):
        colors.setdefault(c["cloth_id"], []).append(f"{c['color']}({c['dominance']})")
    lines = [f"{len(rows)} garment(s). id | name | brand | category | cut | "
             "colours | tags | rating | favourite | excluded | worn | last worn | added"]
    for r in rows:
        try:
            tags = ", ".join(json.loads(r["custom_tags"] or "[]"))
        except (ValueError, TypeError):
            tags = ""
        lines.append(" | ".join(str(x) for x in (
            r["id"], r["name"], r["brand"] or "-", r["category"] or "-",
            r["cut"] or "-", " ".join(colors.get(r["id"], [])) or "-",
            tags or "-", r["score"] or 0, "yes" if r["is_favorite"] else "no",
            "yes" if r["exclude_from_algo"] else "no", r["wears"],
            r["last_worn_at"] or "never", r["added"] or "-")))
    return "\n".join(lines)


def _photo_path(conn, user_id: int, cloth_id: int) -> Optional[str]:
    im = conn.execute(
        "SELECT i.cutout_path, i.original_path, i.bg_accepted "
        "FROM cloth_images i JOIN clothes c ON c.id = i.cloth_id "
        "WHERE i.cloth_id = ? AND c.user_id = ? "
        "ORDER BY CASE i.role WHEN 'front' THEN 0 ELSE 1 END, "
        "i.sort_order, i.id LIMIT 1", (cloth_id, user_id)).fetchone()
    if not im:
        return None
    return (im["original_path"] if im["bg_accepted"] == "rejected"
            else (im["cutout_path"] or im["original_path"]))


def _view(conn, user_id: int, ids: List[int]) -> list:
    """Tool-result content: a label and a small JPEG per garment."""
    out: list = []
    names = {r["id"]: r["name"] for r in conn.execute(
        "SELECT id, name FROM clothes WHERE user_id = ?", (user_id,))}
    for cid in list(dict.fromkeys(int(i) for i in ids))[:6]:
        if cid not in names:
            out.append({"type": "text", "text": f"{cid}: not in the wardrobe"})
            continue
        path = _photo_path(conn, user_id, cid)
        try:
            im = Image.open(path).convert("RGBA")
        except Exception:  # noqa: BLE001 — a missing photo is reported, not fatal
            out.append({"type": "text", "text": f"{cid} {names[cid]}: no photo"})
            continue
        im.thumbnail((512, 512))
        flat = Image.new("RGB", im.size, (255, 255, 255))
        flat.paste(im, mask=im.split()[3])
        buf = io.BytesIO()
        flat.save(buf, "JPEG", quality=82)
        out.append({"type": "text", "text": f"{cid} {names[cid]}:"})
        out.append({"type": "image", "source": {
            "type": "base64", "media_type": "image/jpeg",
            "data": base64.b64encode(buf.getvalue()).decode()}})
    return out or [{"type": "text", "text": "No garment given."}]


def _weather(conn, user_id: int, day: str) -> str:
    day = (day or "").strip() or date.today().isoformat()
    row = conn.execute(
        "SELECT weather_lat, weather_lon, weather_place FROM users WHERE id = ?",
        (user_id,)).fetchone()
    if not row or row["weather_lat"] is None:
        return ("No place is saved, so there is no forecast. The owner can set "
                "one in Settings > Weather.")
    try:
        got = weather_mod.forecast(row["weather_lat"], row["weather_lon"], day)
    except weather_mod.WeatherUnavailable as e:
        return f"No forecast for {day}: {e}"
    return json.dumps({"day": day, "place": row["weather_place"] or "",
                       "temp_min_c": got.get("temp_min"),
                       "temp_max_c": got.get("temp_max"),
                       "kind": got.get("mode"), "code": got.get("code")})


def _agenda(conn, user_id: int, days: int) -> str:
    days = max(1, min(int(days or 7), 14))
    today = date.today()
    end = (today + timedelta(days=days)).isoformat()
    names = {r["id"]: r["name"] for r in conn.execute(
        "SELECT id, name FROM clothes WHERE user_id = ?", (user_id,))}
    planned = []
    for r in conn.execute(
            "SELECT a.day, a.title, a.worn, o.cloth_ids FROM agenda a "
            "LEFT JOIN outfits o ON o.id = a.outfit_id "
            "WHERE a.user_id = ? AND a.day >= ? AND a.day <= ? ORDER BY a.day",
            (user_id, today.isoformat(), end)):
        try:
            ids = json.loads(r["cloth_ids"] or "[]")
        except (ValueError, TypeError):
            ids = []
        planned.append({"day": r["day"], "title": r["title"],
                        "garments": [names.get(i, f"#{i}") for i in ids]})
    since = (today - timedelta(days=14)).isoformat()
    worn: Dict[str, List[str]] = {}
    for r in conn.execute(
            "SELECT w.day, w.cloth_id FROM cloth_wears w "
            "WHERE w.user_id = ? AND w.day >= ? ORDER BY w.day DESC",
            (user_id, since)):
        worn.setdefault(r["day"], []).append(
            f"{names.get(r['cloth_id'], '#?')} (id {r['cloth_id']})")
    return json.dumps({"today": today.isoformat(), "planned": planned,
                       "worn_last_14_days": worn}, ensure_ascii=False)


def _outfits(conn, user_id: int, favorites_only: bool) -> str:
    names = {r["id"]: r["name"] for r in conn.execute(
        "SELECT id, name FROM clothes WHERE user_id = ?", (user_id,))}
    rows = conn.execute(
        "SELECT id, cloth_ids, is_favorite, rating FROM outfits WHERE user_id = ? "
        "AND status = 'done' AND kind IN ('ai', 'manual') "
        "AND NOT (view = 'back' AND linked_id IS NOT NULL) "
        + ("AND is_favorite = 1 " if favorites_only else "")
        + "ORDER BY id DESC LIMIT 60", (user_id,)).fetchall()
    if not rows:
        return "No outfits yet."
    out = []
    for r in rows:
        try:
            ids = json.loads(r["cloth_ids"] or "[]")
        except (ValueError, TypeError):
            ids = []
        marks = (" (favourite)" if r["is_favorite"] else "") + (
            f" (rated {r['rating']}/5)" if r["rating"] else "")
        out.append(f"outfit {r['id']}{marks}: "
                   + ", ".join(f"{names.get(i, '?')} (id {i})" for i in ids))
    return "\n".join(out)


def check_outfit(conn, user_id: int, cloth_ids: List[int]) -> List[int]:
    """The ids as a wearable outfit, or ValueError saying what is wrong."""
    ids = list(dict.fromkeys(int(i) for i in cloth_ids))
    if not ids:
        raise ValueError("cloth_ids is empty")
    ph = ",".join("?" * len(ids))
    rows = {r["id"]: r for r in conn.execute(
        f"SELECT id, category FROM clothes WHERE user_id = ? AND id IN ({ph})",
        [user_id] + ids)}
    unknown = [i for i in ids if i not in rows]
    if unknown:
        raise ValueError(f"these ids are not in the wardrobe: {unknown}")
    seen: Dict[str, int] = {}
    for i in ids:
        for slot in slots_of(rows[i]["category"] or ""):
            if slot in seen:
                raise ValueError(
                    f"garments {seen[slot]} and {i} are the same kind ({slot}); "
                    "keep one")
            seen[slot] = i
    roles = {role_of(rows[i]["category"] or "") for i in ids}
    if not {"top", "bottom", "onepiece"} & roles:
        raise ValueError("an outfit needs at least a top or a bottom")
    return layer_sorted(ids, key=lambda i: rows[i]["category"] or "")


def run_tool(conn, user_id: int, name: str, args: dict,
             on_proposal: Callable[[str, List[int], str], int],
             actions=None):
    """Run one tool and return its result (text, or content blocks for
    view_garments); ValueError means a bad call."""
    if name == "get_wardrobe":
        return _wardrobe(conn, user_id, str(args.get("category") or ""))
    if name == "search_wardrobe":
        return _wardrobe(
            conn, user_id, str(args.get("category") or ""),
            text=str(args.get("text") or ""), color=str(args.get("color") or ""),
            brand=str(args.get("brand") or ""), tag=str(args.get("tag") or ""),
            min_rating=int(args.get("min_rating") or 0),
            favorites_only=bool(args.get("favorites_only")),
            include_excluded=bool(args.get("include_excluded")))
    if name == "view_garments":
        return _view(conn, user_id, args.get("cloth_ids") or [])
    if name == "get_weather":
        return _weather(conn, user_id, str(args.get("day") or ""))
    if name == "get_agenda":
        return _agenda(conn, user_id, int(args.get("days") or 7))
    if name == "get_outfits":
        return _outfits(conn, user_id, bool(args.get("favorites_only")))
    if name == "propose_outfit":
        ids = check_outfit(conn, user_id, args.get("cloth_ids") or [])
        pid = on_proposal(str(args.get("title") or "").strip()[:80], ids,
                          str(args.get("reason") or "").strip()[:400])
        return f"Shown to the owner as proposal {pid}."
    if name in ACTION_TOOLS:
        if actions is None:
            raise ValueError(f"{name} is not available here")
        if name in ("save_outfit", "render_outfit"):
            args = {**args, "cloth_ids": check_outfit(
                conn, user_id, args.get("cloth_ids") or [])}
        return actions.run(name, args)
    raise ValueError(f"unknown tool {name}")


# --- the conversation loop ----------------------------------------------------

def _block_dict(block) -> dict:
    """A response block as the API expects it back: unchanged, minus Nones."""
    return block.model_dump(exclude_none=True)


def opening_context(conn, user_id: int) -> str:
    """What a new conversation starts with, so the first answer needs no
    look-up: the wardrobe, today's forecast and the agenda."""
    return ("<wardrobe>\n" + _wardrobe(conn, user_id) + "\n</wardrobe>\n"
            "<weather_today>\n" + _weather(conn, user_id, "") + "\n</weather_today>\n"
            "<agenda>\n" + _agenda(conn, user_id, 7) + "\n</agenda>")


def converse(conn, user_id: int, history: List[dict], user_text: str,
             on_proposal: Callable[[str, List[int], str], int],
             speed: str = DEFAULT_SPEED, actions=None,
             on_usage: Optional[Callable[[str, dict], None]] = None) -> dict:
    """Send one user message, run the tool calls, return the final reply.

    ``history`` is the stored message list; the returned ``messages`` is the
    new one to store. ``text`` is what the app shows for this turn.
    """
    today = date.today()
    # The date rides on the user turn, not in the system prompt, so the cached
    # prefix stays the same from one day to the next.
    stamped = f"[Today is {today.strftime('%A')} {today.isoformat()}.]\n{user_text}"
    history = list(history)
    carried: list = []
    if history and history[-1]["role"] == "user" and isinstance(
            history[-1]["content"], list) and all(
            b.get("type") == "tool_result" for b in history[-1]["content"]):
        # The last turn ended on proposals whose results were never sent: they
        # open this turn, before the new question (see below).
        carried = history.pop()["content"]
    if not history:
        # Context first, question last: it stays in the cached prefix for the
        # rest of the conversation.
        content = [{"type": "text", "text": opening_context(conn, user_id)},
                   {"type": "text", "text": stamped}]
    else:
        content = [*carried, {"type": "text", "text": stamped}] if carried else stamped
    messages = history + [{"role": "user", "content": content}]
    model, effort, fallback = MODELS.get(speed, MODELS[DEFAULT_SPEED])
    texts: List[str] = []
    api = client()
    started = time.monotonic()
    for step in range(STYLIST_MAX_STEPS):
        t0 = time.monotonic()
        try:
            extra = ({"betas": [FALLBACK_BETA], "fallbacks": "default"}
                     if fallback else {})
            resp = api.beta.messages.create(
                model=model,
                max_tokens=16000,
                system=SYSTEM_PROMPT,
                tools=TOOLS,
                messages=messages,
                thinking={"type": "adaptive"},
                output_config={"effort": effort},
                cache_control={"type": "ephemeral"},
                **extra,
            )
        except anthropic.AuthenticationError as e:
            raise StylistUnavailable("The stylist's API key was refused") from e
        except anthropic.RateLimitError as e:
            raise StylistUnavailable("The stylist is busy, try again in a minute") from e
        except anthropic.APIStatusError as e:
            raise StylistUnavailable(f"The stylist failed ({e.status_code})") from e
        except anthropic.APIConnectionError as e:
            raise StylistUnavailable("The stylist could not be reached") from e

        if on_usage is not None and getattr(resp, "usage", None) is not None:
            u = resp.usage
            on_usage(getattr(resp, "model", "") or model, {
                "input_tokens": getattr(u, "input_tokens", 0) or 0,
                "output_tokens": getattr(u, "output_tokens", 0) or 0,
                "cache_read": getattr(u, "cache_read_input_tokens", 0) or 0,
                "cache_write": getattr(u, "cache_creation_input_tokens", 0) or 0,
            })
        uses = [b.name for b in resp.content if b.type == "tool_use"]
        log.info("stylist step %s: %s %.1fs stop=%s tools=%s", step, model,
                 time.monotonic() - t0, resp.stop_reason, uses)
        messages.append({"role": "assistant",
                         "content": [_block_dict(b) for b in resp.content]})
        texts.extend(b.text for b in resp.content
                     if b.type == "text" and b.text.strip())

        if resp.stop_reason == "refusal":
            texts.append("I can't help with that one. Ask me about an outfit.")
            break
        if resp.stop_reason == "pause_turn":
            continue
        if resp.stop_reason != "tool_use":
            break
        results = []
        for b in resp.content:
            if b.type != "tool_use":
                continue
            try:
                out = run_tool(conn, user_id, b.name, dict(b.input or {}),
                               on_proposal, actions)
                results.append({"type": "tool_result", "tool_use_id": b.id,
                                "content": out})
            except (ValueError, TypeError) as e:
                results.append({"type": "tool_result", "tool_use_id": b.id,
                                "content": f"Error: {e}", "is_error": True})
        messages.append({"role": "user", "content": results})
        # A turn that only proposed outfits, and already said something, is
        # done: asking the model to wrap up would cost a whole extra call for
        # a sentence. The results ride along with the next question instead.
        if (texts and uses and set(uses) <= CARD_TOOLS
                and not any(r.get("is_error") for r in results)):
            break
    else:
        log.warning("stylist hit %s steps for user %s", STYLIST_MAX_STEPS, user_id)
        # The last message is tool results nobody answered: drop the dangling
        # pair so the stored history stays a valid conversation.
        if messages and messages[-1]["role"] == "user":
            messages = messages[:-2]
        texts.append("I went round in circles on that one. Could you rephrase?")
    log.info("stylist turn: %s %.1fs", model, time.monotonic() - started)
    return {"messages": messages, "text": "\n\n".join(texts).strip()}
