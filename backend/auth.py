from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from config import JWT_ALG, JWT_TTL_HOURS, SECRET_KEY
from db import get_conn

_bearer = HTTPBearer(auto_error=False)

# bcrypt only uses the first 72 bytes of a password. Enforce that here so we
# never raise from the C extension on long inputs.
_BCRYPT_MAX = 72


def hash_password(password: str) -> str:
    raw = password.encode("utf-8")[:_BCRYPT_MAX]
    return bcrypt.hashpw(raw, bcrypt.gensalt()).decode("utf-8")


def verify_password(password: str, password_hash: str) -> bool:
    raw = password.encode("utf-8")[:_BCRYPT_MAX]
    try:
        return bcrypt.checkpw(raw, password_hash.encode("utf-8"))
    except ValueError:
        return False


def issue_token(user_id: int, email: str) -> str:
    now = datetime.now(timezone.utc)
    payload = {
        "sub": str(user_id),
        "email": email,
        "iat": now,
        "exp": now + timedelta(hours=JWT_TTL_HOURS),
    }
    return jwt.encode(payload, SECRET_KEY, algorithm=JWT_ALG)


def _decode(token: str) -> dict:
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[JWT_ALG])
    except jwt.PyJWTError as e:
        # `from e` keeps which JWT check failed (expired vs bad signature) in the
        # traceback, while the client still gets one opaque 401.
        raise HTTPException(status.HTTP_401_UNAUTHORIZED,
                            "Invalid or expired token") from e


def get_current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> dict:
    if creds is None or not creds.credentials:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Missing auth token")
    payload = _decode(creds.credentials)
    user_id = int(payload["sub"])
    with get_conn() as conn:
        row = conn.execute(
            "SELECT id, email, is_admin, created_at, tokens_valid_from "
            "FROM users WHERE id = ?",
            (user_id,),
        ).fetchone()
    if row is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "User no longer exists")

    # A token issued before the account's cut-off is refused. That is what makes
    # changing a password end the other sessions, which is usually the whole
    # point of changing it.
    cutoff = row["tokens_valid_from"]
    if cutoff:
        issued = payload.get("iat")
        if isinstance(issued, datetime):
            issued = int(issued.timestamp())
        if issued is None or int(issued) < int(cutoff):
            raise HTTPException(
                status.HTTP_401_UNAUTHORIZED,
                "Session ended because the password was changed",
            )

    user = dict(row)
    user.pop("tokens_valid_from", None)
    return user


def is_admin(user: dict) -> bool:
    """A user is an admin if flagged in the DB or allowlisted by email (env)."""
    from config import ADMIN_EMAILS

    return bool(user.get("is_admin")) or (
        (user.get("email") or "").lower() in ADMIN_EMAILS
    )


def require_admin(user: dict = Depends(get_current_user)) -> dict:
    """Dependency guarding manager-only endpoints (e.g. the reports queues)."""
    if not is_admin(user):
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Admin access required")
    return user