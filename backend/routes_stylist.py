"""Endpoints of the personal stylist: chat threads, and turning a proposal
into an outfit."""
import json
import logging
from typing import List, Optional

from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, status
from pydantic import BaseModel

import stylist
from audit import record as audit_record
from auth import get_current_user
from bfl import _tile
from config import OUTFITS_DIR
from db import get_conn
from routes_plan import _cloth_cards

router = APIRouter(prefix="/stylist", tags=["stylist"])
log = logging.getLogger(__name__)

MAX_MESSAGE_CHARS = 4000
# A turn still "pending" after this long belongs to a worker that died.
STALE_TURN_S = 360


class ChatRequest(BaseModel):
    message: str
    thread_id: Optional[int] = None


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
            "outfit_id": row["outfit_id"]}


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
    return {"available": stylist.available(), "model": stylist.STYLIST_MODEL}


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
    background.add_task(_run_turn, user, thread_id, user_msg, text)
    return {"thread_id": thread_id, "pending": True,
            "messages": [m for m in messages if m["id"] == user_msg]}


def _run_turn(user: dict, thread_id: int, user_msg: int, text: str) -> None:
    with get_conn() as conn:
        history = json.loads(conn.execute(
            "SELECT api_messages FROM stylist_threads WHERE id = ?",
            (thread_id,)).fetchone()["api_messages"] or "[]")
    pending: List[tuple] = []

    def on_proposal(title, ids, reason) -> int:
        # Numbered in this turn; the rows are written with the reply below.
        pending.append((title, ids, reason))
        return len(pending)

    try:
        with get_conn() as conn:
            out = stylist.converse(conn, user["id"], history, text, on_proposal)
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
        for title, ids, reason in pending:
            conn.execute(
                "INSERT INTO stylist_proposals (thread_id, message_id, user_id, "
                "title, reason, cloth_ids) VALUES (?, ?, ?, ?, ?, ?)",
                (thread_id, msg_id, user["id"], title, reason, json.dumps(ids)))
        conn.execute(
            "UPDATE stylist_threads SET api_messages = ?, pending = 0, error = '', "
            "updated_at = CURRENT_TIMESTAMP WHERE id = ?",
            (json.dumps(out["messages"]), thread_id))
    audit_record(user, "stylist.chat", f"thread #{thread_id} proposals={len(pending)}")


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
        paths = _cutout_paths(conn, user["id"], ids)
        outfit_id = conn.execute(
            "INSERT INTO outfits (user_id, cloth_ids, status, kind, layout) "
            "VALUES (?, ?, 'done', 'manual', '')",
            (user["id"], json.dumps(ids))).lastrowid
    tile = _tile(paths, max_px=1024) if paths else None
    OUTFITS_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTFITS_DIR / f"{outfit_id}.png"
    if tile:
        import shutil
        shutil.move(tile, out_path)
    with get_conn() as conn:
        conn.execute("UPDATE outfits SET generated_path = ? WHERE id = ?",
                     (str(out_path) if tile else "", outfit_id))
        conn.execute("UPDATE stylist_proposals SET outfit_id = ? WHERE id = ?",
                     (outfit_id, proposal_id))
    audit_record(user, "stylist.save", f"proposal #{proposal_id} -> outfit #{outfit_id}")
    return {"outfit_id": outfit_id, "created": True}
