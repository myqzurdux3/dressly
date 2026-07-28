from typing import List, Optional

from fastapi import APIRouter, Depends, File, Form, HTTPException, UploadFile, status
from pydantic import BaseModel

import logging

from auth import get_current_user
from db import get_conn
from images import (
    IMAGES_DIR,
    canonical_cutout_path,
    public_url_for,
    remove_background,
    remove_cloth_files,
)

router = APIRouter(prefix="/models", tags=["models"])
log = logging.getLogger(__name__)


def _model_dir(model_id: int):
    d = IMAGES_DIR / f"model_{model_id}"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _hydrate(conn, row) -> dict:
    model_id = row["id"]
    images = conn.execute(
        "SELECT id, role, original_path, cutout_path, sort_order, bg_accepted "
        "FROM model_images WHERE model_id = ? ORDER BY sort_order, id",
        (model_id,),
    ).fetchall()
    return {
        "id": model_id,
        "user_id": row["user_id"],
        "name": row["name"],
        "gender": row["gender"] if "gender" in row.keys() else "",
        "created_at": row["created_at"],
        "images": [
            {
                "id": im["id"],
                "role": im["role"],
                "sort_order": im["sort_order"],
                "bg_accepted": im["bg_accepted"],
                "original_url": public_url_for(im["original_path"]),
                "cutout_url": public_url_for(
                    im["cutout_path"]
                    if im["bg_accepted"] != "rejected"
                    else im["original_path"]
                ),
            }
            for im in images
        ],
    }


def _load_model(conn, model_id: int, user_id: int) -> dict:
    row = conn.execute(
        "SELECT * FROM models WHERE id = ? AND user_id = ?", (model_id, user_id)
    ).fetchone()
    if not row:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")
    return _hydrate(conn, row)


@router.get("")
def list_models(user=Depends(get_current_user), search: Optional[str] = None):
    with get_conn() as conn:
        if search and search.strip():
            like = f"%{search.strip()}%"
            rows = conn.execute(
                "SELECT * FROM models WHERE user_id = ? AND name LIKE ? "
                "ORDER BY created_at DESC",
                (user["id"], like),
            ).fetchall()
        else:
            rows = conn.execute(
                "SELECT * FROM models WHERE user_id = ? ORDER BY created_at DESC",
                (user["id"],),
            ).fetchall()
        return [_hydrate(conn, r) for r in rows]


@router.get("/{model_id}")
def get_model(model_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        return _load_model(conn, model_id, user["id"])


@router.post("")
async def create_model(
    user=Depends(get_current_user),
    name: str = Form(...),
    gender: str = Form(""),
    images: List[UploadFile] = File(...),
):
    name = name.strip()
    if not name:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Name is required")
    gender = (gender or "").strip().lower()
    if gender not in ("male", "female"):
        gender = ""
    if len(images) < 2:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST, "Front and back pictures are required"
        )
    with get_conn() as conn:
        cur = conn.execute(
            "INSERT INTO models (user_id, name, gender) VALUES (?, ?, ?)",
            (user["id"], name, gender),
        )
        model_id = cur.lastrowid
        mdir = _model_dir(model_id)
        roles = ["front", "back"] + ["extra"] * max(0, len(images) - 2)
        for idx, (role, upload) in enumerate(zip(roles, images)):
            ext = (upload.filename or "").lower().rsplit(".", 1)[-1] if upload.filename else "jpg"
            if ext not in ("jpg", "jpeg", "png", "webp"):
                ext = "jpg"
            original = mdir / f"{role}_{idx}.{ext}"
            data = await upload.read()
            if not data:
                continue
            original.write_bytes(data)
            # Models keep their original background — NO background removal.
            # cutout_path points at the original so displayUrl resolves to the
            # unprocessed photo, and bg_accepted='accepted' skips the review.
            conn.execute(
                "INSERT INTO model_images (model_id, role, original_path, cutout_path, "
                "sort_order, bg_accepted) VALUES (?, ?, ?, ?, ?, 'accepted')",
                (model_id, role, str(original), str(original), idx),
            )
        row = conn.execute("SELECT * FROM models WHERE id = ?", (model_id,)).fetchone()
        return _hydrate(conn, row)


class ModelUpdate(BaseModel):
    name: Optional[str] = None
    gender: Optional[str] = None  # '' | 'male' | 'female'


@router.patch("/{model_id}")
def update_model(model_id: int, req: ModelUpdate, user=Depends(get_current_user)):
    """Update a model's name and/or gender (gender drives the male/female random
    pick when generating outfits)."""
    with get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM models WHERE id = ? AND user_id = ?",
            (model_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")
        fields, args = [], []
        if req.name is not None and req.name.strip():
            fields.append("name = ?")
            args.append(req.name.strip())
        if req.gender is not None:
            g = req.gender.strip().lower()
            if g not in ("male", "female"):
                g = ""
            fields.append("gender = ?")
            args.append(g)
        if fields:
            args.append(model_id)
            conn.execute(f"UPDATE models SET {', '.join(fields)} WHERE id = ?", args)
        return _load_model(conn, model_id, user["id"])


@router.delete("/{model_id}")
def delete_model(model_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM models WHERE id = ? AND user_id = ?",
            (model_id, user["id"]),
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")
        conn.execute("DELETE FROM models WHERE id = ?", (model_id,))
    remove_cloth_files(f"model_{model_id}")
    return {"ok": True}


@router.post("/{model_id}/images/{image_id}/accept")
def accept_image(model_id: int, image_id: int, user=Depends(get_current_user)):
    """Confirm the cutout. Regenerate it if a prior reject deleted the file."""
    from pathlib import Path

    with get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM models WHERE id = ? AND user_id = ?", (model_id, user["id"])
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")
        img = conn.execute(
            "SELECT id, original_path, cutout_path, bg_accepted "
            "FROM model_images WHERE id = ? AND model_id = ?",
            (image_id, model_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")

        original = Path(img["original_path"])
        canonical_cutout = canonical_cutout_path(original)
        needs_regen = (
            img["bg_accepted"] == "rejected"
            or not canonical_cutout.exists()
            or img["cutout_path"] == img["original_path"]
        )
        if needs_regen:
            try:
                remove_background(original, canonical_cutout)
            except Exception as e:  # pragma: no cover
                log.warning("bg re-removal failed for image %s: %s", image_id, e)
                canonical_cutout.write_bytes(original.read_bytes())
        conn.execute(
            "UPDATE model_images SET bg_accepted = 'accepted', cutout_path = ? "
            "WHERE id = ?",
            (str(canonical_cutout), image_id),
        )
    return {"ok": True}


@router.post("/{model_id}/images/{image_id}/reject")
def reject_image(model_id: int, image_id: int, user=Depends(get_current_user)):
    with get_conn() as conn:
        row = conn.execute(
            "SELECT 1 FROM models WHERE id = ? AND user_id = ?", (model_id, user["id"])
        ).fetchone()
        if not row:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Model not found")
        img = conn.execute(
            "SELECT id, original_path, cutout_path FROM model_images WHERE id = ? AND model_id = ?",
            (image_id, model_id),
        ).fetchone()
        if not img:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Image not found")
        from pathlib import Path

        Path(img["cutout_path"]).unlink(missing_ok=True)
        conn.execute(
            "UPDATE model_images SET bg_accepted = 'rejected', cutout_path = original_path WHERE id = ?",
            (image_id,),
        )
    return {"ok": True}