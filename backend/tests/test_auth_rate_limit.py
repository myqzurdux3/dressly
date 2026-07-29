"""Sign-in protection.

Without a limit here, a password can be guessed as fast as the network allows —
the one gap that no amount of hashing strength compensates for.
"""
import config
import db


def _login(client, password="wrong-password", email="u@test.co"):
    return client.post("/auth/login", json={"email": email, "password": password})


def _signup(client, email):
    return client.post("/auth/signup",
                       json={"email": email, "password": "pw123456"})


def test_repeated_wrong_passwords_are_cut_off(client, auth, monkeypatch):
    monkeypatch.setattr(config, "AUTH_FAIL_RATE_LIMIT", 3)
    monkeypatch.setattr(config, "AUTH_RATE_LIMIT", 1000)  # not the limit under test

    seen_429 = False
    for _ in range(6):
        r = _login(client)
        if r.status_code == 429:
            seen_429 = True
            assert "Retry-After" in r.headers
            break
        assert r.status_code == 401
    assert seen_429, "a word-list run was never stopped"


def test_a_correct_password_still_works_below_the_limit(client, monkeypatch):
    monkeypatch.setattr(config, "AUTH_FAIL_RATE_LIMIT", 5)
    assert _signup(client, "real@test.co").status_code == 200

    assert _login(client, "nope", "real@test.co").status_code == 401
    r = _login(client, "pw123456", "real@test.co")
    assert r.status_code == 200, "someone mistyping once must not be locked out"


def test_signup_flooding_is_capped(client, monkeypatch):
    monkeypatch.setattr(config, "AUTH_RATE_LIMIT", 3)

    codes = [_signup(client, f"flood{i}@test.co").status_code for i in range(6)]
    assert 429 in codes, f"signup was never throttled: {codes}"


def test_the_attempt_limit_covers_login_too(client, monkeypatch):
    monkeypatch.setattr(config, "AUTH_RATE_LIMIT", 2)
    monkeypatch.setattr(config, "AUTH_FAIL_RATE_LIMIT", 0)  # isolate this budget

    codes = [_login(client).status_code for _ in range(5)]
    assert 429 in codes, codes


def test_limits_of_zero_disable_the_guard(client, monkeypatch):
    monkeypatch.setattr(config, "AUTH_RATE_LIMIT", 0)
    monkeypatch.setattr(config, "AUTH_FAIL_RATE_LIMIT", 0)

    for _ in range(8):
        assert _login(client).status_code == 401


def test_failed_attempts_are_recorded_for_audit(client, monkeypatch):
    monkeypatch.setattr(config, "AUTH_FAIL_RATE_LIMIT", 0)
    _login(client)
    with db.get_conn() as conn:
        n = conn.execute(
            "SELECT COUNT(*) AS n FROM audit_log WHERE action = 'auth.login_failed'"
        ).fetchone()["n"]
    assert n >= 1


# --- the counters must be shared, which is what allows several workers -----

def test_counters_survive_a_fresh_process_view(client, monkeypatch):
    """In-memory counters were per-worker: N workers meant N times the quota.
    Reloading the module must not reset anything."""
    import importlib

    import ratelimit

    monkeypatch.setattr(config, "AUTH_RATE_LIMIT", 2)
    assert _login(client).status_code == 401
    importlib.reload(ratelimit)          # stands in for "another worker"
    codes = [_login(client).status_code for _ in range(3)]
    assert 429 in codes, f"quota reset when the module was reloaded: {codes}"


def test_counters_live_in_the_database():
    """The mechanism, stated directly: a second process can only see the count
    if it is stored somewhere shared."""
    with db.get_conn() as conn:
        tables = {r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table'")}
    assert "rate_hits" in tables
