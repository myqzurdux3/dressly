"""Endpoints of the personal stylist: chat threads, and turning a proposal
into an outfit."""
import json
import logging
import threading
from typing import List, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from pydantic import BaseModel

import stylist
from audit import record as audit_record
from auth import get_current_user
from bfl import _tile
from config import OUTFITS_DIR
from db import get_conn
from ratelimit import generation_guard
from routes_plan import _cloth_cards

router = APIRouter(prefix="/stylist", tags=["stylist"])
log = logging.getLogger(__name__)

MAX_MESSAGE_CHARS = 4000
# A turn still "pending" after this long belongs to a worker that died.
STALE_TURN_S = 360


class ChatRequest(BaseModel):
    message: str
    thread_id: Optional[int] = None
    # 'fast' | 'balanced' | 'expert' — which model answers this turn.
    speed: str = stylist.DEFAULT_SPEED
    # Where an AI render starts when the stylist is asked for one: the app's
    # own setting ('flex' | 'pro' | 'openrouter').
    render_tier: str = "flex"


class RenderRequest(BaseModel):
    # 'none' | 'random' | 'random_male' | 'random_female' | a model id.
    person: str = "none"
    tier: str = "flex"


def _thread(conn, user_id: int, thread_id: int):
    row = conn.execute(
        "SELECT * FROM stylist_threads WHERE id = ? AND user_id = ?",
        (thread_id, user_id)).fetchone()
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Conversation not found")
    return row


def _proposal_json(conn, user_id: int, row) -> dict:
    try:
        ids = [int(i) for i in json.loads(row["cloth_ids"] or "[]")]
    except (ValueError, TypeError):
        ids = []
    return {"id": row["id"], "title": row["title"], "reason": row["reason"],
            "cloth_ids": ids, "cloths": _cloth_cards(conn, user_id, ids),
            "outfit_id": row["outfit_id"],
            "render_id": row["render_id"] if "render_id" in row.keys() else None}


def _messages_json(conn, user_id: int, thread_id: int) -> List[dict]:
    props: dict = {}
    for p in conn.execute(
            "SELECT * FROM stylist_proposals WHERE thread_id = ? ORDER BY id",
            (thread_id,)):
        props.setdefault(p["message_id"], []).append(
            _proposal_json(conn, user_id, p))
    return [{"id": m["id"], "role": m["role"], "text": m["text"],
             "created_at": m["created_at"],
             "proposals": props.get(m["id"], [])}
            for m in conn.execute(
                "SELECT * FROM stylist_messages WHERE thread_id = ? ORDER BY id",
                (thread_id,))]


@router.get("/status")
def stylist_status(user=Depends(get_current_user)):
    return {"available": stylist.available(),
            "default_speed": stylist.DEFAULT_SPEED,
            "speeds": {k: v[0] for k, v in stylist.MODELS.items()}}


@router.get("/threads")
def list_threads(user=Depends(get_current_user)):
    with get_conn() as conn:
        rows = conn.execute(
            "SELECT id, title, created_at, updated_at FROM stylist_threads "
            "WHERE user_id = ? ORDER BY updated_at DESC, id DESC LIMIT 100",
            (user["id"],)).fetchall()
    return {"items": [dict(r) for r in rows]}


@router.get("/threads/{thread_id}")
def get_thread(thread_id: int, user=Depends(get_current_user)):
    """The conversation. ``pending`` is true while the stylist is answering:
    the app polls this until it turns false, then reads the reply or
    ``error``."""
    with get_conn() as conn:
        row = _thread(conn, user["id"], thread_id)
        pending, error = bool(row["pending"]), row["error"] or ""
        if pending and conn.execute(
                "SELECT 1 FROM stylist_threads WHERE id = ? AND "
                "updated_at < datetime('now', ?)",
                (thread_id, f"-{STALE_TURN_S} seconds")).fetchone():
            pending, error = False, "The stylist did not answer in time"
            conn.execute("UPDATE stylist_threads SET pending = 0, error = ? "
                         "WHERE id = ?", (error, thread_id))
        return {"id": row["id"], "title": row["title"], "pending": pending,
                "error": error,
                "messages": _messages_json(conn, user["id"], thread_id)}


@router.delete("/threads/{thread_id}")
def delete_thread(thread_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        _thread(conn, user["id"], thread_id)
        conn.execute("DELETE FROM stylist_proposals WHERE thread_id = ?", (thread_id,))
        conn.execute("DELETE FROM stylist_messages WHERE thread_id = ?", (thread_id,))
        conn.execute("DELETE FROM stylist_threads WHERE id = ?", (thread_id,))
    return {"ok": True}


@router.post("/chat")
def chat(req: ChatRequest, background: BackgroundTasks,
         user=Depends(get_current_user)):
    """Send a message. The reply is written in the background — a turn with
    several look-ups can outlast the proxy's request timeout — and the app
    polls GET /stylist/threads/{id} until ``pending`` is false."""
    text = (req.message or "").strip()
    if not text:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Empty message")
    if len(text) > MAX_MESSAGE_CHARS:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            f"At most {MAX_MESSAGE_CHARS} characters")
    if not stylist.available():
        raise HTTPException(status.HTTP_503_SERVICE_UNAVAILABLE,
                            "The stylist is not configured on the server")
    with get_conn() as conn:
        if req.thread_id:
            row = _thread(conn, user["id"], req.thread_id)
            if row["pending"]:
                raise HTTPException(status.HTTP_409_CONFLICT,
                                    "The stylist is still answering")
            thread_id = row["id"]
        else:
            thread_id = conn.execute(
                "INSERT INTO stylist_threads (user_id, title) VALUES (?, ?)",
                (user["id"], text[:60])).lastrowid
        user_msg = conn.execute(
            "INSERT INTO stylist_messages (thread_id, role, text) VALUES (?, 'user', ?)",
            (thread_id, text)).lastrowid
        conn.execute(
            "UPDATE stylist_threads SET pending = 1, error = '', "
            "updated_at = CURRENT_TIMESTAMP WHERE id = ?", (thread_id,))
        messages = _messages_json(conn, user["id"], thread_id)
    speed = req.speed if req.speed in stylist.MODELS else stylist.DEFAULT_SPEED
    background.add_task(_run_turn, user, thread_id, user_msg, text, speed,
                        req.render_tier)
    return {"thread_id": thread_id, "pending": True,
            "messages": [m for m in messages if m["id"] == user_msg]}


def _run_turn(user: dict, thread_id: int, user_msg: int, text: str,
              speed: str = stylist.DEFAULT_SPEED,
              render_tier: str = "flex") -> None:
    with get_conn() as conn:
        history = json.loads(conn.execute(
            "SELECT api_messages FROM stylist_threads WHERE id = ?",
            (thread_id,)).fetchone()["api_messages"] or "[]")
    pending: List[tuple] = []

    def on_proposal(title, ids, reason, outfit_id=None, render_id=None) -> int:
        # Numbered in this turn; the rows are written with the reply below.
        pending.append((title, ids, reason, outfit_id, render_id))
        return len(pending)

    actions = _Actions(user, on_proposal, render_tier)
    try:
        with get_conn() as conn:
            out = stylist.converse(conn, user["id"], history, text,
                                   on_proposal, speed, actions=actions,
                                   on_usage=lambda m, u: record_usage(user["id"], m, u))
    except Exception as e:  # noqa: BLE001 — any failure must clear "pending"
        if not isinstance(e, stylist.StylistUnavailable):
            log.exception("stylist turn failed for thread %s", thread_id)
        message = (str(e) if isinstance(e, stylist.StylistUnavailable)
                   else "The stylist failed, try again")
        # The question is removed so nothing is half written; the app puts it
        # back in the input box.
        with get_conn() as conn:
            conn.execute("DELETE FROM stylist_messages WHERE id = ?", (user_msg,))
            conn.execute("UPDATE stylist_threads SET pending = 0, error = ? "
                         "WHERE id = ?", (message, thread_id))
        return
    with get_conn() as conn:
        reply = out["text"] or ("Here is what I suggest." if pending else "…")
        msg_id = conn.execute(
            "INSERT INTO stylist_messages (thread_id, role, text) "
            "VALUES (?, 'assistant', ?)", (thread_id, reply)).lastrowid
        for title, ids, reason, outfit_id, render_id in pending:
            conn.execute(
                "INSERT INTO stylist_proposals (thread_id, message_id, user_id, "
                "title, reason, cloth_ids, outfit_id, render_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (thread_id, msg_id, user["id"], title, reason, json.dumps(ids),
                 outfit_id, render_id))
        conn.execute(
            "UPDATE stylist_threads SET api_messages = ?, pending = 0, error = '', "
            "updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (json.dumps(out["messages"]), thread_id))
    audit_record(user, "stylist.chat",
                 f"thread #{thread_id} {speed} cards={len(pending)} "
                 f"actions={','.join(actions.done) or '-'}")


def _cutout_paths(conn, user_id: int, ids: List[int]) -> List[str]:
    """Each garment's picture as the wardrobe shows it, in wearing order."""
    paths = []
    for cid in ids:
        im = conn.execute(
            "SELECT i.cutout_path, i.original_path, i.bg_accepted "
            "FROM cloth_images i JOIN clothes c ON c.id = i.cloth_id "
            "WHERE i.cloth_id = ? AND c.user_id = ? "
            "ORDER BY CASE i.role WHEN 'front' THEN 0 ELSE 1 END, "
            "i.sort_order, i.id LIMIT 1", (cid, user_id)).fetchone()
        if not im:
            continue
        paths.append(im["original_path"] if im["bg_accepted"] == "rejected"
                     else (im["cutout_path"] or im["original_path"]))
    return paths


def make_flat_outfit(user: dict, ids: List[int]) -> int:
    """A manual outfit whose picture is the garments side by side."""
    with get_conn() as conn:
        paths = _cutout_paths(conn, user["id"], ids)
        outfit_id = conn.execute(
            "INSERT INTO outfits (user_id, cloth_ids, status, kind, layout) "
            "VALUES (?, ?, 'done', 'manual', '')",
            (user["id"], json.dumps(ids))).lastrowid
    tile = _tile(paths, max_px=1024) if paths else None
    from routes_outfits import manual_file
    OUTFITS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = manual_file(outfit_id)
    if tile:
        import shutil
        shutil.move(tile, out_path)
    path = str(out_path) if tile else ""
    with get_conn() as conn:
        conn.execute("UPDATE outfits SET generated_path = ?, manual_path = ? "
                     "WHERE id = ?", (path, path, outfit_id))
    return outfit_id


class _Now:
    """BackgroundTasks look-alike for routes called outside a request: the
    task starts at once on its own thread."""

    def add_task(self, fn, *args, **kwargs):
        threading.Thread(target=fn, args=args, kwargs=kwargs,
                         daemon=True).start()


def start_render(user: dict, ids: List[int], person: str, tier: str) -> int:
    """Start an AI render of the garments; returns the new outfit's id."""
    import routes_outfits
    person = (person or "none").strip().lower()
    kw: dict = {}
    if person.startswith("random"):
        kw["random_model"] = True
        kw["random_model_gender"] = person.partition("_")[2]
    elif person not in ("", "none"):
        try:
            kw["model_id"] = int(person)
        except ValueError as e:
            raise ValueError(f"person must be none, random or a model id, "
                             f"not {person!r}") from e
    req = routes_outfits.GenerateRequest(
        cloth_ids=ids, tier=tier if tier in ("flex", "pro", "openrouter") else "flex",
        **kw)
    try:
        out = routes_outfits.generate_outfit(req, _Now(), user)
    except HTTPException as e:
        raise ValueError(str(e.detail)) from e
    return int(out["id"])


class _Actions:
    """The stylist's write tools, done as the user through the app's routes."""

    def __init__(self, user: dict, on_proposal, render_tier: str):
        self.user = user
        self.on_proposal = on_proposal
        self.render_tier = render_tier
        self.renders = 0
        self.done: List[str] = []
        # Flat lays made in this turn, by garment set, so "save it and put it
        # in the agenda" makes one outfit, not two.
        self.flat: dict = {}

    def _flat(self, ids: List[int]) -> int:
        key = tuple(sorted(ids))
        if key not in self.flat:
            self.flat[key] = make_flat_outfit(self.user, ids)
        return self.flat[key]

    def run(self, name: str, a: dict):
        try:
            out = getattr(self, "_" + name)(a)
        except HTTPException as e:
            raise ValueError(str(e.detail)) from e
        self.done.append(name)
        return out

    def _save_outfit(self, a):
        oid = self._flat(a["cloth_ids"])
        self.on_proposal(str(a.get("title") or "")[:80], a["cloth_ids"],
                         str(a.get("reason") or "")[:400], oid, None)
        return f"Saved as outfit {oid}; shown as a card."

    def _render_outfit(self, a):
        if self.renders >= stylist.MAX_RENDERS_PER_TURN:
            raise ValueError(f"at most {stylist.MAX_RENDERS_PER_TURN} renders "
                             "per message")
        rid = start_render(self.user, a["cloth_ids"], str(a.get("person") or ""),
                           self.render_tier)
        self.renders += 1
        self.on_proposal(str(a.get("title") or "")[:80], a["cloth_ids"], "",
                         None, rid)
        return (f"Render started as outfit {rid}; it takes about a minute and "
                "the card opens it.")

    def _list_models(self, a):
        with get_conn() as conn:
            rows = conn.execute(
                "SELECT id, name, gender FROM models WHERE user_id = ? "
                "ORDER BY id", (self.user["id"],)).fetchall()
        if not rows:
            return "No models yet: render with person 'none'."
        return "\n".join(f"{r['id']} | {r['name']} | {r['gender'] or '-'}"
                         for r in rows)

    def _schedule_outfit(self, a):
        import routes_agenda
        oid = int(a.get("outfit_id") or 0) or None
        ids = a.get("cloth_ids") or []
        if oid is None and ids:
            with get_conn() as conn:
                ids = stylist.check_outfit(conn, self.user["id"], ids)
            oid = self._flat(ids)
        routes_agenda.create_agenda(routes_agenda.AgendaCreate(
            day=str(a.get("day") or ""), outfit_id=oid,
            title=str(a.get("title") or "")[:80]), self.user)
        return f"Added to the agenda on {a.get('day')}" + (
            f" with outfit {oid}." if oid else ".")

    def _update_garment(self, a):
        import routes_clothes as rc
        cid = int(a["cloth_id"])
        changed = []
        if int(a.get("rating", -1)) >= 0:
            rc.set_score(cid, rc.ScoreRequest(score=int(a["rating"])), self.user)
            changed.append(f"rating {int(a['rating'])}")
        for key, fn, model, field in (
                ("favorite", rc.toggle_cloth_favorite, rc.FavoriteRequest, "is_favorite"),
                ("excluded", rc.set_cloth_exclude_algo, rc.ExcludeAlgoRequest, "exclude")):
            v = a.get(key, "keep")
            if v in ("yes", "no"):
                fn(cid, model(**{field: v == "yes"}), self.user)
                changed.append(f"{key} {v}")
        return f"Garment {cid}: " + (", ".join(changed) or "nothing changed") + "."

    def _mark_worn(self, a):
        import routes_clothes as rc
        day = str(a.get("day") or "").strip() or None
        ids = [int(i) for i in a.get("cloth_ids") or []]
        for cid in ids:
            rc.wear_cloth(cid, rc.WearRequest(day=day), self.user)
        return f"Marked {len(ids)} garment(s) worn."

    def _favorite_outfit(self, a):
        import routes_outfits
        out = routes_outfits.toggle_favorite(
            int(a["outfit_id"]),
            routes_outfits.FavoriteRequest(is_favorite=bool(a["favorite"])),
            self.user)
        return f"Outfit {a['outfit_id']} favourite: {out['is_favorite']}."


def record_usage(user_id: int, model: str, usage: dict) -> None:
    """One model call, priced now. Never breaks a turn."""
    try:
        with get_conn() as conn:
            conn.execute(
                "INSERT INTO llm_usage (user_id, model, input_tokens, "
                "output_tokens, cache_read, cache_write, cost_usd) "
                "VALUES (?, ?, ?, ?, ?, ?, ?)",
                (user_id, model, usage["input_tokens"], usage["output_tokens"],
                 usage["cache_read"], usage["cache_write"],
                 stylist.price(model, usage)))
    except Exception:  # noqa: BLE001
        log.exception("could not record stylist usage")


@router.post("/proposals/{proposal_id}/render")
def render_proposal(proposal_id: int, req: RenderRequest,
                    user=Depends(generation_guard)):
    """Start an AI render of a proposal. Rendering again starts a new one."""
    with get_conn() as conn:
        p = conn.execute(
            "SELECT * FROM stylist_proposals WHERE id = ? AND user_id = ?",
            (proposal_id, user["id"])).fetchone()
        if not p:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Proposal not found")
        try:
            ids = stylist.check_outfit(conn, user["id"],
                                       json.loads(p["cloth_ids"] or "[]"))
        except ValueError as e:
            raise HTTPException(status.HTTP_409_CONFLICT, str(e)) from e
    try:
        rid = start_render(user, ids, req.person, req.tier)
    except ValueError as e:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, str(e)) from e
    with get_conn() as conn:
        conn.execute("UPDATE stylist_proposals SET render_id = ? WHERE id = ?",
                     (rid, proposal_id))
    audit_record(user, "stylist.render", f"proposal #{proposal_id} -> outfit #{rid}")
    return {"outfit_id": rid}


@router.post("/proposals/{proposal_id}/save")
def save_proposal(proposal_id: int, user=Depends(get_current_user)):
    """Add a proposal to the user's outfits, as a flat lay of the garments.

    No render, no cost: a manual outfit whose picture is the garments side by
    side. The app can still send it for an AI render from the outfit screen.
    Saving twice returns the outfit made the first time.
    """
    with get_conn() as conn:
        p = conn.execute(
            "SELECT * FROM stylist_proposals WHERE id = ? AND user_id = ?",
            (proposal_id, user["id"])).fetchone()
        if not p:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Proposal not found")
        if p["outfit_id"] and conn.execute(
                "SELECT 1 FROM outfits WHERE id = ?", (p["outfit_id"],)).fetchone():
            return {"outfit_id": p["outfit_id"], "created": False}
        try:
            ids = stylist.check_outfit(conn, user["id"],
                                       json.loads(p["cloth_ids"] or "[]"))
        except ValueError as e:
            # A garment was deleted since the proposal was made.
            raise HTTPException(status.HTTP_409_CONFLICT, str(e)) from e
    outfit_id = make_flat_outfit(user, ids)
    with get_conn() as conn:
        conn.execute("UPDATE stylist_proposals SET outfit_id = ? WHERE id = ?",
                     (outfit_id, proposal_id))
    audit_record(user, "stylist.save", f"proposal #{proposal_id} -> outfit #{outfit_id}")
    return {"outfit_id": outfit_id, "created": True}
