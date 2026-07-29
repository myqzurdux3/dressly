"""Changing a password, and what it should do to existing sessions."""
import time

import config
import db
from tests.conftest import create_cloth


def _signup(client, email="pw@test.co", password="original-pw"):
    r = client.post("/auth/signup", json={"email": email, "password": password})
    assert r.status_code == 200, r.text
    return r.json()["token"]


def _hdr(token):
    return {"Authorization": f"Bearer {token}"}


def _change(client, token, current, new):
    return client.post("/auth/password", headers=_hdr(token),
                       json={"current_password": current, "new_password": new})


def test_the_password_actually_changes(client):
    token = _signup(client)
    assert _change(client, token, "original-pw", "brand-new-pw").status_code == 200

    assert client.post("/auth/login",
                       json={"email": "pw@test.co",
                             "password": "brand-new-pw"}).status_code == 200
    assert client.post("/auth/login",
                       json={"email": "pw@test.co",
                             "password": "original-pw"}).status_code == 401


def test_the_current_password_is_required(client):
    """A token is enough to browse; it must not be enough to lock the owner
    out of their own account."""
    token = _signup(client)
    r = _change(client, token, "not-the-password", "brand-new-pw")
    assert r.status_code == 401
    assert "Current password" in r.json()["detail"]

    # And nothing changed.
    assert client.post("/auth/login",
                       json={"email": "pw@test.co",
                             "password": "original-pw"}).status_code == 200


def test_a_short_password_is_refused(client):
    token = _signup(client)
    r = _change(client, token, "original-pw", "abc")
    assert r.status_code == 400
    assert "at least" in r.json()["detail"]


def test_reusing_the_same_password_is_refused(client):
    token = _signup(client)
    r = _change(client, token, "original-pw", "original-pw")
    assert r.status_code == 400


def test_it_needs_authentication(client):
    r = client.post("/auth/password",
                    json={"current_password": "a", "new_password": "bbbbbbb"})
    assert r.status_code in (401, 403)


# --- sessions -------------------------------------------------------------

def test_other_sessions_stop_working(client):
    """The usual reason for changing a password is to cut someone off. A
    self-contained token would otherwise keep working until it expired."""
    first = _signup(client)
    second = client.post("/auth/login",
                         json={"email": "pw@test.co",
                               "password": "original-pw"}).json()["token"]
    assert client.get("/auth/me", headers=_hdr(second)).status_code == 200

    time.sleep(1.05)   # tokens carry whole-second issue times
    assert _change(client, first, "original-pw", "brand-new-pw").status_code == 200

    r = client.get("/auth/me", headers=_hdr(second))
    assert r.status_code == 401, "the other session survived the change"
    assert "password was changed" in r.json()["detail"]


def test_the_caller_is_not_signed_out_by_their_own_change(client):
    token = _signup(client)
    r = _change(client, token, "original-pw", "brand-new-pw")
    assert r.status_code == 200

    fresh = r.json()["token"]
    assert client.get("/auth/me", headers=_hdr(fresh)).status_code == 200


def test_the_returned_token_works_for_real_requests(client):
    token = _signup(client)
    create_cloth(client, _hdr(token))
    fresh = _change(client, token, "original-pw", "brand-new-pw").json()["token"]

    r = client.get("/clothes", headers=_hdr(fresh))
    assert r.status_code == 200
    assert len(r.json()) == 1, "the account is the same one"


def test_accounts_are_independent(client):
    """One user changing a password must not sign out anybody else."""
    a = _signup(client, "a@test.co", "a-password")
    b = _signup(client, "b@test.co", "b-password")

    time.sleep(1.05)
    assert _change(client, a, "a-password", "a-new-password").status_code == 200

    assert client.get("/auth/me", headers=_hdr(b)).status_code == 200


# --- abuse ----------------------------------------------------------------

def test_guessing_the_current_password_is_rate_limited(client, monkeypatch):
    """Guessing here is the same attack as guessing at the sign-in screen, so
    it draws on the same budget."""
    monkeypatch.setattr(config, "AUTH_FAIL_RATE_LIMIT", 3)
    monkeypatch.setattr(config, "AUTH_RATE_LIMIT", 1000)
    token = _signup(client)

    seen_429 = False
    for _ in range(6):
        r = _change(client, token, f"guess-{_}", "brand-new-pw")
        if r.status_code == 429:
            seen_429 = True
            break
        assert r.status_code == 401
    assert seen_429, "a guessing run was never stopped"


def test_both_outcomes_are_recorded(client):
    token = _signup(client)
    _change(client, token, "wrong", "brand-new-pw")
    _change(client, token, "original-pw", "brand-new-pw")

    with db.get_conn() as conn:
        actions = {
            r["action"] for r in conn.execute(
                "SELECT action FROM audit_log WHERE action LIKE 'auth.password%'")
        }
    assert "auth.password_change_failed" in actions
    assert "auth.password_changed" in actions
