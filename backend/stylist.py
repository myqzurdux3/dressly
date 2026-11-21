"""The personal stylist: a Claude conversation with read access to the user's
wardrobe, outfits, agenda and weather, and one write: proposing outfits.

The model never writes to the wardrobe. ``propose_outfit`` only records a
proposal; the user adds it to their outfits from the app with one tap. That
keeps a misread request from creating or changing anything on its own.

The conversation is replayed in full on every turn (``api_messages``), exactly
as the API returned it, because thinking blocks must come back unchanged.
"""
import json
import logging
from datetime import date, timedelta
from typing import Callable, Dict, List, Optional

import anthropic

import weather as weather_mod
from config import (
    ANTHROPIC_API_KEY,
    STYLIST_EFFORT,
    STYLIST_MAX_STEPS,
    STYLIST_MODEL,
    STYLIST_TIMEOUT_S,
)
from generator import layer_sorted, role_of, slots_of

log = logging.getLogger(__name__)

FALLBACK_BETA = "server-side-fallback-2026-07-01"

SYSTEM_PROMPT = """You are the personal stylist inside Dressly, a wardrobe app. \
You talk with one person about what to wear, using only the clothes they own.

How to work:
- Look things up before advising. get_wardrobe lists every garment with its \
attributes and the owner's own rating; get_weather gives the forecast for \
their saved place; get_agenda shows what is planned and what was worn lately; \
get_outfits lists outfits they already made.
- Recommend only garments returned by get_wardrobe, by their exact id. Never \
invent a garment, and say so plainly when the wardrobe lacks something.
- Every time you recommend a complete outfit, call propose_outfit with its \
garment ids. The app shows each proposal as a card the person can add to \
their outfits with one tap. Propose one to three outfits per answer unless \
asked for more.
- A complete outfit has one top, one bottom and shoes; add a layer, socks, a \
cap or accessories when they fit. Never two garments of the same kind.
- Respect the owner's preferences: favour well-rated and favourite pieces, \
never use a garment marked "excluded", avoid what was worn in the last few \
days unless asked, and dress for the weather.
- Reply in the language the person writes in. Keep answers short and \
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


def _wardrobe(conn, user_id: int, category: str = "") -> str:
    params: list = [user_id]
    where = "c.user_id = ?"
    if category.strip():
        where += " AND c.category = ?"
        params.append(category.strip())
    rows = conn.execute(
        f"SELECT c.id, c.name, c.brand, c.category, c.cut, c.custom_tags, "
        f"c.score, c.is_favorite, c.exclude_from_algo, c.last_worn_at, "
        f"(SELECT COUNT(*) FROM cloth_wears w WHERE w.cloth_id = c.id) AS wears "
        f"FROM clothes c WHERE {where} ORDER BY c.category, c.name",
        params).fetchall()
    if not rows:
        return "No garments" + (f" in category '{category}'." if category else ".")
    colors: Dict[int, List[str]] = {}
    ids = [r["id"] for r in rows]
    ph = ",".join("?" * len(ids))
    for c in conn.execute(
            f"SELECT cloth_id, color, dominance FROM cloth_colors "
            f"WHERE cloth_id IN ({ph})", ids):
        colors.setdefault(c["cloth_id"], []).append(f"{c['color']}({c['dominance']})")
    lines = ["id | name | brand | category | cut | colours | tags | rating | "
             "favourite | excluded | worn | last worn"]
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
            r["last_worn_at"] or "never")))
    return "\n".join(lines)


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
        "SELECT id, cloth_ids, is_favorite FROM outfits WHERE user_id = ? "
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
        out.append(f"outfit {r['id']}{' (favourite)' if r['is_favorite'] else ''}: "
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
             on_proposal: Callable[[str, List[int], str], int]) -> str:
    """Run one tool and return its text result; ValueError means a bad call."""
    if name == "get_wardrobe":
        return _wardrobe(conn, user_id, str(args.get("category") or ""))
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
    raise ValueError(f"unknown tool {name}")


# --- the conversation loop ----------------------------------------------------

def _block_dict(block) -> dict:
    """A response block as the API expects it back: unchanged, minus Nones."""
    return block.model_dump(exclude_none=True)


def converse(conn, user_id: int, history: List[dict], user_text: str,
             on_proposal: Callable[[str, List[int], str], int]) -> dict:
    """Send one user message, run the tool calls, return the final reply.

    ``history`` is the stored message list; the returned ``messages`` is the
    new one to store. ``text`` is what the app shows for this turn.
    """
    today = date.today()
    # The date rides on the user turn, not in the system prompt, so the cached
    # prefix stays the same from one day to the next.
    stamped = f"[Today is {today.strftime('%A')} {today.isoformat()}.]\n{user_text}"
    messages = list(history) + [{"role": "user", "content": stamped}]
    texts: List[str] = []
    api = client()
    for _ in range(STYLIST_MAX_STEPS):
        try:
            resp = api.beta.messages.create(
                model=STYLIST_MODEL,
                max_tokens=16000,
                system=SYSTEM_PROMPT,
                tools=TOOLS,
                messages=messages,
                thinking={"type": "adaptive"},
                output_config={"effort": STYLIST_EFFORT},
                cache_control={"type": "ephemeral"},
                betas=[FALLBACK_BETA],
                fallbacks="default",
            )
        except anthropic.AuthenticationError as e:
            raise StylistUnavailable("The stylist's API key was refused") from e
        except anthropic.RateLimitError as e:
            raise StylistUnavailable("The stylist is busy, try again in a minute") from e
        except anthropic.APIStatusError as e:
            raise StylistUnavailable(f"The stylist failed ({e.status_code})") from e
        except anthropic.APIConnectionError as e:
            raise StylistUnavailable("The stylist could not be reached") from e

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
                               on_proposal)
                results.append({"type": "tool_result", "tool_use_id": b.id,
                                "content": out})
            except (ValueError, TypeError) as e:
                results.append({"type": "tool_result", "tool_use_id": b.id,
                                "content": f"Error: {e}", "is_error": True})
        messages.append({"role": "user", "content": results})
    else:
        log.warning("stylist hit %s steps for user %s", STYLIST_MAX_STEPS, user_id)
        # The last message is tool results nobody answered: drop the dangling
        # pair so the stored history stays a valid conversation.
        if messages and messages[-1]["role"] == "user":
            messages = messages[:-2]
        texts.append("I went round in circles on that one. Could you rephrase?")
    return {"messages": messages, "text": "\n\n".join(texts).strip()}
