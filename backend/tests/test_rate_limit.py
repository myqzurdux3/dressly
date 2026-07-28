"""Spend guard on the billed bfl.ai endpoints."""
import config
import ratelimit
from tests.conftest import create_cloth


def _gen(client, auth, cloth_ids):
    return client.post("/outfits/generate", headers=auth,
                       json={"cloth_ids": cloth_ids})


def test_generation_is_capped_per_user(client, auth, monkeypatch):
    monkeypatch.setattr(config, "GENERATION_RATE_LIMIT", 2)
    monkeypatch.setattr(config, "GENERATION_RATE_WINDOW_S", 3600)
    c = create_cloth(client, auth)

    assert _gen(client, auth, [c["id"]]).status_code == 200
    assert _gen(client, auth, [c["id"]]).status_code == 200
    blocked = _gen(client, auth, [c["id"]])
    assert blocked.status_code == 429
    assert "Retry-After" in blocked.headers
    assert int(blocked.headers["Retry-After"]) > 0


def test_limit_is_per_user_not_global(client, monkeypatch):
    monkeypatch.setattr(config, "GENERATION_RATE_LIMIT", 1)
    monkeypatch.setattr(config, "GENERATION_RATE_WINDOW_S", 3600)

    def signup(email):
        r = client.post("/auth/signup", json={"email": email, "password": "pw123456"})
        assert r.status_code == 200, r.text
        return {"Authorization": f"Bearer {r.json()['token']}"}

    a, b = signup("a@test.co"), signup("b@test.co")
    ca, cb = create_cloth(client, a), create_cloth(client, b)

    assert _gen(client, a, [ca["id"]]).status_code == 200
    assert _gen(client, a, [ca["id"]]).status_code == 429
    # b's quota is untouched by a burning through theirs.
    assert _gen(client, b, [cb["id"]]).status_code == 200


def test_limit_of_zero_disables_the_bucket(client, auth, monkeypatch):
    monkeypatch.setattr(config, "GENERATION_RATE_LIMIT", 0)
    c = create_cloth(client, auth)
    for _ in range(5):
        assert _gen(client, auth, [c["id"]]).status_code == 200


def test_window_slides(monkeypatch):
    """Old hits must age out, otherwise the first burst locks a user out forever."""
    clock = {"t": 1000.0}
    monkeypatch.setattr(ratelimit.time, "monotonic", lambda: clock["t"])
    ratelimit.reset()

    assert ratelimit._check("k", 2, 60) == 0
    assert ratelimit._check("k", 2, 60) == 0
    assert ratelimit._check("k", 2, 60) > 0     # third in the window: blocked

    clock["t"] += 61                             # window has passed
    assert ratelimit._check("k", 2, 60) == 0


def test_retry_after_reflects_the_oldest_hit(monkeypatch):
    clock = {"t": 0.0}
    monkeypatch.setattr(ratelimit.time, "monotonic", lambda: clock["t"])
    ratelimit.reset()

    ratelimit._check("k", 1, 100)
    clock["t"] += 40
    wait = ratelimit._check("k", 1, 100)
    assert 55 <= wait <= 60, wait


def test_default_limits_are_generous_enough_for_normal_use():
    """A guard that fires during ordinary use is worse than none."""
    assert config.GENERATION_RATE_LIMIT >= 20
    assert config.GENERATION_RATE_WINDOW_S <= 3600
