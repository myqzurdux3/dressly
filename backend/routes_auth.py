import time

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


class PasswordChange(BaseModel):
    current_password: str
    new_password: str


MIN_PASSWORD_LENGTH = 6


def _public_user(row) -> dict:
    from auth import is_admin as _is_admin

    user = {"id": row["id"], "email": row["email"],
            "created_at": row["created_at"]}
    # Included from the first response, not only from /auth/me: the app decides
    # what to show the moment somebody signs in, and asking again for one
    # boolean would be a second round trip on the login screen.
    keys = row.keys() if hasattr(row, "keys") else ()
    user["is_admin"] = _is_admin({
        "email": user["email"],
        "is_admin": row["is_admin"] if "is_admin" in keys else 0,
    })
    return user


@router.post("/signup", dependencies=[Depends(auth_guard)])
def signup(creds: Credentials):
    if len(creds.password) < MIN_PASSWORD_LENGTH:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"Password must be at least {MIN_PASSWORD_LENGTH} characters")
    with get_conn() as conn:
        exists = conn.execute("SELECT 1 FROM users WHERE email = ?", (creds.email,)).fetchone()
        if exists:
            raise HTTPException(status.HTTP_409_CONFLICT, "Email already registered")
        cur = conn.execute(
            "INSERT INTO users (email, password_hash) VALUES (?, ?)",
            (creds.email, hash_password(creds.password)),
        )
        user = conn.execute(
            "SELECT id, email, is_admin, created_at FROM users WHERE id = ?", (cur.lastrowid,)
        ).fetchone()
    token = issue_token(user["id"], user["email"])
    audit_record(_public_user(user), "auth.signup")
    return {"token": token, "user": _public_user(user)}


@router.post("/login", dependencies=[Depends(auth_guard)])
def login(creds: Credentials, request: Request):
    with get_conn() as conn:
        user = conn.execute(
            "SELECT id, email, is_admin, created_at, password_hash FROM users WHERE email = ?",
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
    # ``is_admin`` here is the EFFECTIVE answer — the DB flag or the email
    # allowlist — so the app never has to reimplement the rule to decide
    # whether to show an admin-only screen.
    from auth import is_admin as _is_admin

    return {**user, "is_admin": _is_admin(user)}

@router.post("/password", dependencies=[Depends(auth_guard)])
def change_password(req: PasswordChange, request: Request,
                    user=Depends(get_current_user)):
    """Change the signed-in user's password.

    The current one is required even though the caller is already
    authenticated: a token is enough to browse, but it should not be enough to
    lock the owner out of their own account.

    Succeeding ends every other session. A token carries its issue time and the
    account records a cut-off, so anything older stops being accepted — which is
    usually why someone changes a password in the first place. The caller gets a
    fresh token back so they are not signed out by their own action.
    """
    if len(req.new_password) < MIN_PASSWORD_LENGTH:
        raise HTTPException(
            status.HTTP_400_BAD_REQUEST,
            f"Password must be at least {MIN_PASSWORD_LENGTH} characters")

    with get_conn() as conn:
        row = conn.execute(
            "SELECT password_hash FROM users WHERE id = ?", (user["id"],)
        ).fetchone()
    if not row or not verify_password(req.current_password, row["password_hash"]):
        audit_record(user, "auth.password_change_failed")
        # Charged against the failed-sign-in budget: guessing the current
        # password here is the same attack as guessing it at the login screen.
        note_failed_login(request)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED,
                            "Current password is incorrect")

    if req.new_password == req.current_password:
        raise HTTPException(status.HTTP_400_BAD_REQUEST,
                            "The new password must be different")

    # Tokens carry whole-second issue times, and the check is "older than the
    # cut-off", so a token minted in this same second still passes — including
    # the replacement issued just below. The cost is that a token created
    # within the same second as the change survives; the alternative was
    # sleeping a second inside the request, which is worse.
    cutoff = int(time.time())
    with get_conn() as conn:
        conn.execute(
            "UPDATE users SET password_hash = ?, tokens_valid_from = ? "
            "WHERE id = ?",
            (hash_password(req.new_password), cutoff, user["id"]),
        )
    audit_record(user, "auth.password_changed")

    return {"token": issue_token(user["id"], user["email"]),
            "user": {k: user[k] for k in ("id", "email", "created_at")}}
