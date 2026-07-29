from fastapi import APIRouter, Depends, HTTPException, Request, status
from pydantic import BaseModel, EmailStr

from audit import record as audit_record
from auth import get_current_user, hash_password, issue_token, verify_password
from db import get_conn
from ratelimit import auth_guard, note_failed_login

router = APIRouter(prefix="/auth", tags=["auth"])


class Credentials(BaseModel):
    email: EmailStr
    password: str


def _public_user(row) -> dict:
    return {"id": row["id"], "email": row["email"], "created_at": row["created_at"]}


@router.post("/signup", dependencies=[Depends(auth_guard)])
def signup(creds: Credentials):
    if len(creds.password) < 6:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Password must be at least 6 characters")
    with get_conn() as conn:
        exists = conn.execute("SELECT 1 FROM users WHERE email = ?", (creds.email,)).fetchone()
        if exists:
            raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")
        cur = conn.execute(
            "INSERT INTO users (email, password_hash) VALUES (?, ?)",
            (creds.email, hash_password(creds.password)),
        )
        user = conn.execute(
            "SELECT id, email, created_at FROM users WHERE id = ?", (cur.lastrowid,)
        ).fetchone()
    token = issue_token(user["id"], user["email"])
    audit_record(_public_user(user), "auth.signup")
    return {"token": token, "user": _public_user(user)}


@router.post("/login", dependencies=[Depends(auth_guard)])
def login(creds: Credentials, request: Request):
    with get_conn() as conn:
        user = conn.execute(
            "SELECT id, email, created_at, password_hash FROM users WHERE email = ?",
            (creds.email,),
        ).fetchone()
    if not user or not verify_password(creds.password, user["password_hash"]):
        audit_record(None, "auth.login_failed", detail=str(creds.email))
        # Charge the failure against the tighter budget BEFORE answering, so a
        # word-list run is cut off rather than merely logged.
        note_failed_login(request)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid email or password")
    token = issue_token(user["id"], user["email"])
    audit_record(_public_user(user), "auth.login")
    return {"token": token, "user": _public_user(user)}


@router.get("/me")
def me(user=Depends(get_current_user)):
    return user