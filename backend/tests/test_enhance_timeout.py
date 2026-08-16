"""An enhancement that is no longer running must say so.

Reported: "j'ai lance l'amelioration d'image pour un short et ca fait 2 mins que
ca charge". Two ways that happens, and neither had an end:

  * the AI cascade tries flex, then pro, then max, and each attempt can spend
    its submit budget plus its poll budget — minutes, with somebody watching a
    spinner;
  * the worker dies (a restart, a crash) and the row stays 'processing'
    forever, because outfits had a startup sweep and enhancements did not.
"""
import time

import pytest

import bfl
import db
import routes_clothes
from config import ENHANCE_TIMEOUT_S
from conftest import create_cloth


def _status(client, auth, cloth_id, image_id):
    for im in client.get(f"/clothes/{cloth_id}", headers=auth).json()["images"]:
        if im["id"] == image_id:
            return im["enhance_status"]
    return None


def _stall(cloth_id, image_id, seconds_ago):
    """Put a row in the state the report describes: still 'processing', started
    a while back."""
    with db.get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET enhance_status = 'processing', "
            "enhance_started_at = datetime('now', ?) WHERE id = ?",
            (f"-{seconds_ago} seconds", image_id))


# --- the sweep ------------------------------------------------------------

def test_a_stalled_enhancement_is_reported_as_failed(client, auth):
    """The exact report: reading the cloth is what the app does while it waits,
    so that is where the truth has to arrive."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    _stall(c["id"], img["id"], ENHANCE_TIMEOUT_S + 60)

    assert _status(client, auth, c["id"], img["id"]) == "failed"


def test_one_that_is_still_within_its_budget_is_left_running(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    _stall(c["id"], img["id"], 5)
    assert _status(client, auth, c["id"], img["id"]) == "processing"


def test_a_row_with_no_start_time_is_swept(client, auth):
    """It predates the column, so its worker belongs to a process that is gone."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    with db.get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET enhance_status = 'processing', "
            "enhance_started_at = NULL WHERE id = ?", (img["id"],))
    assert _status(client, auth, c["id"], img["id"]) == "failed"


def test_the_sweep_counts_what_it_changed(client, auth):
    c = create_cloth(client, auth)
    for im in c["images"]:
        _stall(c["id"], im["id"], ENHANCE_TIMEOUT_S + 10)
    with db.get_conn() as conn:
        assert db.fail_stale_enhancements(conn, ENHANCE_TIMEOUT_S) == 2
        # Idempotent: a second pass has nothing left to do.
        assert db.fail_stale_enhancements(conn, ENHANCE_TIMEOUT_S) == 0


def test_the_sweep_does_not_touch_finished_work(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    with db.get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET enhance_status = 'ready' WHERE id = ?",
            (img["id"],))
        assert db.fail_stale_enhancements(conn, 0) == 0
    assert _status(client, auth, c["id"], img["id"]) == "ready"


# --- the start time -------------------------------------------------------

def test_kicking_one_off_records_when_it_started(client, auth, monkeypatch):
    """Without the stamp there is nothing to measure a stall against."""
    seen = {}

    def peek(cloth_id, image_id, mode, tier="flex"):
        # Stands in for the worker: reads the stamp the route just wrote and
        # does nothing else, so the row stays 'processing' for the assertion.
        with db.get_conn() as conn:
            row = conn.execute(
                "SELECT enhance_started_at FROM cloth_images WHERE id = ?",
                (image_id,)).fetchone()
        seen["stamp"] = row["enhance_started_at"] if row else None

    monkeypatch.setattr(routes_clothes, "_run_enhance", peek)
    c = create_cloth(client, auth)
    seen["image_id"] = c["images"][0]["id"]
    client.post(
        f"/clothes/{c['id']}/images/{seen['image_id']}/enhance",
        headers=auth, json={"mode": "auto"})
    assert seen.get("stamp"), "the start time was never recorded"


def test_a_finished_enhancement_clears_its_start_time(client, auth):
    """Left set, it would make the next sweep look at a job nobody is running."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                    headers=auth, json={"mode": "auto"})
    assert r.status_code == 200
    for _ in range(200):
        if _status(client, auth, c["id"], img["id"]) != "processing":
            break
        time.sleep(0.02)
    with db.get_conn() as conn:
        row = conn.execute(
            "SELECT enhance_status, enhance_started_at FROM cloth_images "
            "WHERE id = ?", (img["id"],)).fetchone()
    assert row["enhance_status"] in ("ready", "failed")
    assert row["enhance_started_at"] is None


# --- retrying -------------------------------------------------------------

def test_a_failed_enhancement_can_simply_be_run_again(client, auth):
    """What the retry button does — no special endpoint, the same request."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    _stall(c["id"], img["id"], ENHANCE_TIMEOUT_S + 60)
    assert _status(client, auth, c["id"], img["id"]) == "failed"

    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                    headers=auth, json={"mode": "auto"})
    assert r.status_code == 200
    for _ in range(200):
        st = _status(client, auth, c["id"], img["id"])
        if st != "processing":
            break
        time.sleep(0.02)
    assert st == "ready", "a retry after a stall did not work"


# --- the cascade's own budget --------------------------------------------

def test_the_cascade_stops_starting_tiers_past_its_budget(monkeypatch):
    """The first attempt always runs; what the budget prevents is quietly
    spending another two tiers' worth of minutes after it."""
    attempts = []

    def slow_submit(slug, prompt, prepared, width=None, height=None):
        attempts.append(slug)
        time.sleep(0.05)
        raise bfl.BflError("nope")

    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_submit", slow_submit)
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")

    with pytest.raises(bfl.BflError) as exc:
        bfl.generate("prompt", [], start_tier="flex", deadline_s=0.01)
    assert len(attempts) == 1, f"kept going past the budget: {attempts}"
    assert "budget spent" in str(exc.value)


def test_without_a_budget_the_cascade_still_tries_every_tier(monkeypatch):
    """The deadline is opt-in: outfit generation, where the user asked for a
    better render, still walks the whole cascade."""
    attempts = []

    def failing_submit(slug, prompt, prepared, width=None, height=None):
        attempts.append(slug)
        raise bfl.BflError("nope")

    monkeypatch.setattr(bfl, "api_key", lambda: "test-key")
    monkeypatch.setattr(bfl, "_submit", failing_submit)
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")

    with pytest.raises(bfl.BflError):
        bfl.generate("prompt", [], start_tier="flex")
    assert len(attempts) == len(bfl.TIER_ORDER)


def test_enhancement_asks_for_a_budget(monkeypatch, tmp_path):
    """The wiring, not just the mechanism: enhance_ai must pass one."""
    from PIL import Image

    import enhance

    src = tmp_path / "src.jpg"
    Image.new("RGB", (64, 64), (200, 30, 30)).save(src)
    seen = {}

    def fake_generate(prompt, paths, start_tier="flex", **kwargs):
        seen["deadline"] = kwargs.get("deadline_s")
        return Image.new("RGB", (8, 8)).tobytes(), start_tier, "mock"

    monkeypatch.setattr("bfl.generate", fake_generate)
    try:
        enhance.enhance_ai(str(src), str(tmp_path / "out.jpg"), tier="flex")
    except Exception:
        pass  # the fake returns raw pixels, not a JPEG — irrelevant here
    assert seen.get("deadline"), "the enhancement cascade runs unbounded"


# --- when it keeps failing ------------------------------------------------
#
# Reported: some garments "ne veulent pas s'ameliorer avec l'IA et mettent sans
# cesse fail meme apres reessayer". Retrying the identical request is the one
# move that cannot help; the app needs to know WHY, and to be able to step up.

def _image(client, auth, cloth_id, image_id):
    for im in client.get(f"/clothes/{cloth_id}", headers=auth).json()["images"]:
        if im["id"] == image_id:
            return im
    return {}


def _fail_enhance(monkeypatch, message="HTTP 422 content moderated"):
    import enhance

    def boom(*a, **kw):
        raise RuntimeError(message)

    monkeypatch.setattr(enhance, "enhance_ai", boom)


def test_a_failure_says_why(client, auth, monkeypatch):
    _fail_enhance(monkeypatch)
    c = create_cloth(client, auth)
    img = c["images"][0]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai", "tier": "flex"})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    assert got["enhance_status"] == "failed"
    assert "content moderated" in (got["enhance_error"] or "")


def test_a_failure_keeps_the_tier_so_a_stronger_one_can_be_offered(
        client, auth, monkeypatch):
    """The whole point: after flex fails, the app can offer pro."""
    _fail_enhance(monkeypatch)
    c = create_cloth(client, auth)
    img = c["images"][0]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai", "tier": "flex"})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    assert got["enhance_tier"] == "flex"
    assert got["enhance_next_tier"] == "pro", got


def test_the_top_tier_offers_no_step_up(client, auth, monkeypatch):
    """Nothing above max: the button must not promise one."""
    _fail_enhance(monkeypatch)
    c = create_cloth(client, auth)
    img = c["images"][0]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai", "tier": "max"})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    assert got["enhance_tier"] == "max"
    assert got["enhance_next_tier"] is None


def test_retrying_at_a_stronger_tier_works(client, auth, monkeypatch):
    """flex refuses the garment, pro accepts it — which is the recovery the
    report needs and repeating flex could never give."""
    import enhance

    calls = []
    real = enhance.enhance_ai

    def picky(src, dst, tier="flex", **kw):
        calls.append(tier)
        if tier == "flex":
            raise RuntimeError("HTTP 422 the model refused this image")
        return real(src, dst, tier=tier, **kw)

    monkeypatch.setattr(enhance, "enhance_ai", picky)
    c = create_cloth(client, auth)
    img = c["images"][0]

    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai", "tier": "flex"})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    assert got["enhance_status"] == "failed"

    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai",
                                    "tier": got["enhance_next_tier"]})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    assert got["enhance_status"] == "ready", got.get("enhance_error")
    assert calls == ["flex", "pro"]


def test_a_new_attempt_clears_the_previous_reason(client, auth):
    """A stale error under a running job would read as a fresh failure."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    with db.get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET enhance_status = 'failed', "
            "enhance_error = 'old news' WHERE id = ?", (img["id"],))
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "auto"})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    assert got["enhance_error"] in (None, "")


def test_a_stalled_job_explains_itself_too(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    _stall(c["id"], img["id"], ENHANCE_TIMEOUT_S + 60)
    got = _image(client, auth, c["id"], img["id"])
    assert got["enhance_status"] == "failed"
    assert "Timed out" in (got["enhance_error"] or "")


def test_a_cascade_error_is_shortened_to_one_line(client, auth, monkeypatch):
    """bfl reports every tier it tried, joined by ' | '. The card has one line."""
    _fail_enhance(monkeypatch,
                  "flex(a): HTTP 422 refused | pro(b): HTTP 422 refused | "
                  "max(c): HTTP 422 refused")
    c = create_cloth(client, auth)
    img = c["images"][0]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai", "tier": "flex"})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    reason = got["enhance_error"] or ""
    assert "|" not in reason, reason
    assert len(reason) <= 200


# --- the budgets have to agree with each other ---------------------------

def test_the_time_budgets_are_consistent():
    """Three numbers govern how long an enhancement may take, and they only
    work in this order:

        one attempt  <= submit budget + poll budget
        the cascade deadline stops it STARTING another tier
        the stale sweep declares a job that is no longer running failed

    They did not hold: with a 120 s submit budget one honest attempt could run
    180 s — the sweep threshold exactly — so a job still working could be marked
    stalled, and the deadline could never stop a second tier because the first
    outlasted it on its own.
    """
    import config

    longest_attempt = config.BFL_UPLOAD_TIMEOUT_S + config.BFL_POLL_TIMEOUT_S
    assert config.ENHANCE_DEADLINE_S < longest_attempt, (
        "the deadline is above one attempt, so it can never stop a second tier")
    assert config.ENHANCE_TIMEOUT_S > longest_attempt, (
        f"the sweep ({config.ENHANCE_TIMEOUT_S}s) fires inside a legitimate "
        f"attempt ({longest_attempt}s) — a working job would be called stalled")


# --- when the provider refuses the picture itself -------------------------
#
# Reported: "certains habits n'arrivent juste pas à s'améliorer avec l'IA … par
# ex le jogging adidas noir … je n'arrive juste pas à l'améliorer avec tous les
# modèles".
#
# Cause: their documented status enum is
#     Pending | Request Moderated | Content Moderated | Ready | Error
# and the poll loop matched only Ready, Error and "Failed" — a status that does
# not exist. A moderated job matched nothing, so the loop kept asking for a
# verdict that was already final until the budget ran out, reported a timeout,
# and every tier repeated it on the same image at the same cost.

def _moderated_payload(status="Content Moderated"):
    return {"status": status, "result": None}


def test_a_moderated_job_is_reported_at_once(monkeypatch):
    """Not after sixty seconds of polling a decision that will not change."""
    polls = []

    class _Resp:
        def __init__(self, body):
            self._body = body

        def read(self):
            import json as _json
            return _json.dumps(self._body).encode()

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    def fake_urlopen(req, timeout=None):
        polls.append(1)
        return _Resp(_moderated_payload())

    monkeypatch.setattr(bfl, "api_key", lambda: "k")
    monkeypatch.setattr(bfl.urllib.request, "urlopen", fake_urlopen)

    with pytest.raises(bfl.BflModerated) as exc:
        bfl._poll("http://poll", "flux-2-klein-4b")
    assert len(polls) == 1, f"kept polling a final verdict {len(polls)} times"
    assert "declined this image" in str(exc.value)


def test_both_moderation_statuses_are_recognised():
    """The request can be refused, or the result can be."""
    assert set(bfl.MODERATED_STATUSES) == {"Request Moderated",
                                           "Content Moderated"}
    assert issubclass(bfl.BflModerated, bfl.BflError), \
        "callers that catch BflError must keep catching this"


def test_a_refusal_does_not_walk_the_rest_of_the_cascade(monkeypatch):
    """Three tiers refusing the same picture is three refusals billed for one
    answer."""
    attempts = []

    def submit(slug, prompt, prepared, width=None, height=None):
        attempts.append(slug)
        return {"id": "x", "polling_url": "http://poll"}

    monkeypatch.setattr(bfl, "api_key", lambda: "k")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")
    monkeypatch.setattr(bfl, "_submit", submit)
    monkeypatch.setattr(bfl, "_resolve_image_url",
                        lambda payload, slug: (_ for _ in ()).throw(
                            bfl.BflModerated("declined this image")))

    with pytest.raises(bfl.BflModerated):
        bfl.generate("prompt", [], start_tier="flex")
    assert attempts == [bfl.TIER_SLUGS["flex"]], attempts


def test_an_ordinary_failure_still_advances_the_cascade(monkeypatch):
    """Only a refusal is final. A transient error is what the cascade is for."""
    attempts = []

    def submit(slug, prompt, prepared, width=None, height=None):
        attempts.append(slug)
        raise bfl.BflError("HTTP 500 upstream hiccup")

    monkeypatch.setattr(bfl, "api_key", lambda: "k")
    monkeypatch.setattr(bfl, "_prepare_image", lambda p: "data")
    monkeypatch.setattr(bfl, "_submit", submit)

    with pytest.raises(bfl.BflError):
        bfl.generate("prompt", [], start_tier="flex")
    assert len(attempts) == len(bfl.TIER_ORDER)


def test_the_user_is_told_it_was_refused_not_that_it_timed_out(
        client, auth, monkeypatch):
    """The whole point: an actionable reason on the card instead of a stopwatch
    running out."""
    import enhance

    def refuse(*a, **kw):
        raise bfl.BflModerated(
            "flux-2-klein-4b: the provider declined this image "
            "(Content Moderated). Trying a different model will not change "
            "that — a clearer, plainer photo of the garment might.")

    monkeypatch.setattr(enhance, "enhance_ai", refuse)
    c = create_cloth(client, auth, name="Jogging")
    img = c["images"][0]
    client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                headers=auth, json={"mode": "ai", "tier": "flex"})
    for _ in range(200):
        got = _image(client, auth, c["id"], img["id"])
        if got.get("enhance_status") != "processing":
            break
        time.sleep(0.02)
    assert got["enhance_status"] == "failed"
    reason = (got["enhance_error"] or "").lower()
    assert "declined this image" in reason, reason
    assert "did not finish" not in reason, "still reported as a timeout"
