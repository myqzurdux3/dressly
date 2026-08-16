"""What the paid image API has cost, for an admin and nobody else.

Two figures, kept apart on purpose: what this server has spent (counted here,
always true) and what the provider says is left (only when a balance endpoint
is configured — bfl.ai documents none, so the screen says so instead of
inventing a number).
"""
import apiusage
import bfl
import db
import pytest
from conftest import create_cloth


@pytest.fixture(autouse=True)
def metering_on(monkeypatch):
    """The hook is installed at startup in production; tests install it too,
    then take it back out so no other test file gets counted."""
    apiusage.install()
    yield
    bfl.usage_recorder = None


def _make_admin(email):
    with db.get_conn() as conn:
        conn.execute("UPDATE users SET is_admin = 1 WHERE email = ?", (email,))


def _admin(client):
    tok = client.post("/auth/signup",
                      json={"email": "admin@admin.com",
                            "password": "pw123456"}).json()["token"]
    _make_admin("admin@admin.com")
    return {"Authorization": f"Bearer {tok}"}


# --- who may look ---------------------------------------------------------

def test_a_normal_account_cannot_see_the_bill(client, auth):
    assert client.get("/admin/credits", headers=auth).status_code == 403


def test_it_needs_a_token_at_all(client):
    assert client.get("/admin/credits").status_code == 401


def test_the_admin_can(client):
    r = client.get("/admin/credits", headers=_admin(client))
    assert r.status_code == 200
    body = r.json()
    assert "spent" in body and "provider" in body


# --- counting what we spend ----------------------------------------------

def test_every_submitted_job_is_counted(client, monkeypatch):
    """The figure that explains a bill: one entry per job the provider accepts."""
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")
    monkeypatch.setattr(bfl, "_post_json", lambda slug, body: {"id": "x"})
    monkeypatch.setattr(bfl, "_resolve_image_url", lambda payload, slug: "http://i")
    monkeypatch.setattr(bfl, "_download", lambda url: b"IMG")

    h = _admin(client)
    before = client.get("/admin/credits", headers=h).json()["spent"]
    bfl.generate("prompt", [], start_tier="flex")
    after = client.get("/admin/credits", headers=h).json()["spent"]

    assert after["calls_accepted"] == before["calls_accepted"] + 1
    assert after["by_tier"]["flex"]["calls"] >= 1
    assert after["last_call_at"]


def test_a_refused_submit_is_recorded_but_not_billed(client, monkeypatch):
    """A rejected request costs nothing, so it must not inflate the spend —
    but it is still worth seeing that it happened."""
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")

    def refuse(slug, body):
        raise bfl.BflError("HTTP 429 too many requests")

    monkeypatch.setattr(bfl, "_post_json", refuse)
    h = _admin(client)
    before = client.get("/admin/credits", headers=h).json()["spent"]
    with pytest.raises(bfl.BflError):
        bfl.generate("prompt", [], start_tier="max")
    after = client.get("/admin/credits", headers=h).json()["spent"]

    assert after["calls_accepted"] == before["calls_accepted"]
    assert after["calls_total"] > before["calls_total"]


def test_a_cascade_counts_each_attempt(client, monkeypatch):
    """flex fails, pro succeeds: two jobs reached the provider, and the bill
    will say so."""
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")
    monkeypatch.setattr(bfl, "_resolve_image_url", lambda payload, slug: "http://i")
    monkeypatch.setattr(bfl, "_download", lambda url: b"IMG")
    calls = []

    def flaky(slug, body):
        calls.append(slug)
        if len(calls) == 1:
            raise bfl.BflError("HTTP 500 upstream")
        return {"id": "x"}

    monkeypatch.setattr(bfl, "_post_json", flaky)
    h = _admin(client)
    before = client.get("/admin/credits", headers=h).json()["spent"]
    bfl.generate("prompt", [], start_tier="flex")
    after = client.get("/admin/credits", headers=h).json()["spent"]
    assert after["calls_total"] == before["calls_total"] + 2


def test_metering_never_breaks_a_render(client, auth, monkeypatch):
    """A broken meter must cost a number on a screen, not somebody's outfit."""
    def boom(**kwargs):
        raise RuntimeError("the meter is on fire")

    monkeypatch.setattr(bfl, "usage_recorder", boom)
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")
    monkeypatch.setattr(bfl, "_post_json", lambda slug, body: {"id": "x"})
    monkeypatch.setattr(bfl, "_resolve_image_url", lambda payload, slug: "http://i")
    monkeypatch.setattr(bfl, "_download", lambda url: b"IMG")

    data, tier, slug = bfl.generate("prompt", [], start_tier="flex")
    assert data == b"IMG" and tier == "flex"


def test_a_dry_run_server_says_so(client):
    """No key means placeholder images and no bill at all — the one thing an
    admin must not have to infer from a zero."""
    body = client.get("/admin/credits", headers=_admin(client)).json()
    assert body["dry_run"] is True
    assert body["spent"]["calls_accepted"] == 0


# --- the provider's own figure -------------------------------------------

def test_the_documented_endpoint_is_the_default(client):
    """GET /v1/credits, from the provider's own API reference, derived from the
    configured base URL so a staging base is followed too. (The suite blanks
    BALANCE_URL so no test calls it for real, hence asserting on the default.)
    https://docs.bfl.ml/api-reference/get-the-users-credits"""
    assert apiusage.DEFAULT_BALANCE_URL.endswith("/v1/credits"), \
        apiusage.DEFAULT_BALANCE_URL


def test_without_a_key_it_does_not_even_ask(client, monkeypatch):
    """No key means no account to ask about — and the call would 401 anyway."""
    monkeypatch.setattr(apiusage, "BALANCE_URL", apiusage.DEFAULT_BALANCE_URL)
    monkeypatch.setattr(bfl, "api_key", lambda: "")
    body = client.get("/admin/credits", headers=_admin(client)).json()
    assert body["provider"]["available"] is False
    assert "no API key" in body["provider"]["reason"]


def test_a_balance_is_priced_in_dollars(client, monkeypatch):
    """Their pricing page: 1 credit = $0.01. A four-figure credit balance means
    nothing on its own. https://docs.bfl.ml/quick_start/pricing"""
    monkeypatch.setattr(apiusage, "BALANCE_URL", "https://example.test/credits")
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")

    class _Resp:
        def read(self):
            return b'{"credits": 18183.85}'

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(apiusage.urllib.request, "urlopen",
                        lambda req, timeout=None: _Resp())
    provider = client.get("/admin/credits",
                          headers=_admin(client)).json()["provider"]
    assert provider["available"] is True
    assert provider["credits"] == 18183.85
    assert provider["usd"] == 181.84
    assert provider["usd_per_credit"] == 0.01


def test_the_real_reply_shape_is_understood(client):
    """What GET /v1/credits actually answers, per their OpenAPI schema:
    {"credits": <number>} and nothing else."""
    assert apiusage._extract_balance({"credits": 18183.85}) == 18183.85


def test_a_configured_endpoint_is_read(client, monkeypatch):
    monkeypatch.setattr(apiusage, "BALANCE_URL", "https://example.test/balance")
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(apiusage, "_extract_balance", lambda payload: 42.5)

    class _Resp:
        def read(self):
            return b'{"credits": 42.5}'

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    monkeypatch.setattr(apiusage.urllib.request, "urlopen",
                        lambda req, timeout=None: _Resp())
    provider = client.get("/admin/credits", headers=_admin(client)).json()["provider"]
    assert provider["available"] is True
    assert provider["credits"] == 42.5


def test_an_unreachable_provider_is_not_an_error_page(client, monkeypatch):
    monkeypatch.setattr(apiusage, "BALANCE_URL", "https://example.test/balance")
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")

    def boom(req, timeout=None):
        raise apiusage.urllib.error.URLError("no route to host")

    monkeypatch.setattr(apiusage.urllib.request, "urlopen", boom)
    r = client.get("/admin/credits", headers=_admin(client))
    assert r.status_code == 200
    assert r.json()["provider"]["available"] is False


def test_a_reply_with_no_number_is_refused(client):
    """Better no figure than a made-up one."""
    assert apiusage._extract_balance({"status": "ok"}) is None
    assert apiusage._extract_balance("nonsense") is None
    assert apiusage._extract_balance({"credits": 12}) == 12.0
    assert apiusage._extract_balance({"account": {"balance": 7.5}}) == 7.5


# --- the breakdown --------------------------------------------------------

def test_the_breakdown_separates_the_tiers(client, monkeypatch):
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")
    monkeypatch.setattr(bfl, "_post_json", lambda slug, body: {"id": "x"})
    monkeypatch.setattr(bfl, "_resolve_image_url", lambda payload, slug: "http://i")
    monkeypatch.setattr(bfl, "_download", lambda url: b"IMG")

    bfl.generate("p", [], start_tier="flex")
    bfl.generate("p", [], start_tier="max")
    bfl.generate("p", [], start_tier="max")
    body = client.get("/admin/credits", headers=_admin(client)).json()
    assert body["spent"]["by_tier"]["max"]["calls"] == 2
    assert body["spent"]["by_tier"]["flex"]["calls"] == 1


def test_generating_an_outfit_shows_up_in_the_meter(client, auth):
    """End to end, through the route somebody actually presses — in dry run,
    so nothing is submitted and the meter stays at zero."""
    c = create_cloth(client, auth)
    from conftest import gen_outfit
    gen_outfit(client, auth, [c["id"]])
    body = client.get("/admin/credits", headers=_admin(client)).json()
    assert body["dry_run"] is True
    assert body["spent"]["calls_total"] == 0, \
        "a dry run reported paid calls it never made"


# --- how the app knows to show the screen ---------------------------------

def test_me_reports_whether_this_account_is_an_admin(client, auth):
    assert client.get("/auth/me", headers=auth).json()["is_admin"] is False
    h = _admin(client)
    assert client.get("/auth/me", headers=h).json()["is_admin"] is True


def test_the_email_allowlist_counts_as_admin_too(client, monkeypatch):
    """DRESSLY_ADMIN_EMAILS is the other way in, and /auth/me must give the
    effective answer — otherwise the app hides a screen the server would serve.
    """
    import config

    tok = client.post("/auth/signup",
                      json={"email": "boss@example.com",
                            "password": "pw123456"}).json()["token"]
    h = {"Authorization": f"Bearer {tok}"}
    assert client.get("/auth/me", headers=h).json()["is_admin"] is False

    monkeypatch.setattr(config, "ADMIN_EMAILS", {"boss@example.com"})
    assert client.get("/auth/me", headers=h).json()["is_admin"] is True
    assert client.get("/admin/credits", headers=h).status_code == 200


# --- what a job actually cost --------------------------------------------
#
# Every FLUX.2 submit answers with `cost` in credits (AsyncResponse in their
# OpenAPI). Counting calls was a proxy for spend; this is the spend.

def _stub_submit(monkeypatch, cost=None):
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")
    monkeypatch.setattr(bfl, "_resolve_image_url", lambda payload, slug: "http://i")
    monkeypatch.setattr(bfl, "_download", lambda url: b"IMG")
    payload = {"id": "x", "polling_url": "http://poll"}
    if cost is not None:
        payload.update({"cost": cost, "input_mp": 1.0, "output_mp": 1.05})
    monkeypatch.setattr(bfl, "_post_json", lambda slug, body: payload)


def test_the_reported_cost_is_recorded(client, monkeypatch):
    _stub_submit(monkeypatch, cost=1.4)
    h = _admin(client)
    bfl.generate("prompt", [], start_tier="flex")
    spent = client.get("/admin/credits", headers=h).json()["spent"]
    assert spent["credits_spent"] == 1.4
    # 1 credit = $0.01, their published rate.
    assert spent["usd_spent"] == 0.01
    assert spent["by_tier"]["flex"]["credits"] == 1.4


def test_costs_add_up_across_calls(client, monkeypatch):
    _stub_submit(monkeypatch, cost=7.0)
    h = _admin(client)
    for _ in range(3):
        bfl.generate("prompt", [], start_tier="max")
    spent = client.get("/admin/credits", headers=h).json()["spent"]
    assert spent["credits_spent"] == 21.0
    assert spent["usd_spent"] == 0.21
    assert spent["credits_last_30_days"] == 21.0


def test_a_reply_without_a_cost_is_counted_but_not_priced(client, monkeypatch):
    """An endpoint that reports no cost must not be silently treated as free —
    a total that quietly omits it reads as cheaper than it was."""
    _stub_submit(monkeypatch, cost=None)
    h = _admin(client)
    bfl.generate("prompt", [], start_tier="flex")
    spent = client.get("/admin/credits", headers=h).json()["spent"]
    assert spent["calls_accepted"] == 1
    assert spent["priced_calls"] == 0
    assert spent["unpriced_calls"] == 1
    assert spent["credits_spent"] == 0


def test_a_refused_submit_costs_nothing(client, monkeypatch):
    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")

    def refuse(slug, body):
        raise bfl.BflError("HTTP 429 too many requests")

    monkeypatch.setattr(bfl, "_post_json", refuse)
    h = _admin(client)
    with pytest.raises(bfl.BflError):
        bfl.generate("prompt", [], start_tier="max")
    spent = client.get("/admin/credits", headers=h).json()["spent"]
    assert spent["credits_spent"] == 0
    assert spent["priced_calls"] == 0


def test_a_try_on_reports_its_cost_too(client, monkeypatch, tmp_path):
    """VTO goes through its own submit path, which had to be wired separately."""
    from PIL import Image

    person = tmp_path / "p.png"
    garment = tmp_path / "g.png"
    Image.new("RGB", (32, 48), (200, 180, 160)).save(person)
    Image.new("RGB", (32, 48), (30, 60, 90)).save(garment)

    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_post_json",
                        lambda slug, body: {"id": "x", "polling_url": "http://p",
                                            "cost": 2.5})
    monkeypatch.setattr(bfl, "_poll", lambda url, slug: "http://img")
    monkeypatch.setattr(bfl, "_download", lambda url: b"IMG")

    h = _admin(client)
    bfl.generate_outfit("prompt", [str(person), str(garment)], start_tier="vto",
                        person_path=str(person), garment_path=str(garment))
    spent = client.get("/admin/credits", headers=h).json()["spent"]
    assert spent["credits_spent"] == 2.5
    assert spent["by_tier"]["vto"]["credits"] == 2.5
