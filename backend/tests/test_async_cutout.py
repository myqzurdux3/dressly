"""Adding a garment answers before its cut-out is made.

Background removal is ~5 s a photo on the deployment server and a garment has
two, so the add screen sat frozen for fifteen seconds on work nobody needed to
watch. The AI enhancement already returned first and reported progress after;
this makes uploads behave the same way.

The guarantee under test is not "it is fast" — that is the machine's business —
but "the response does not contain the cut-out's cost", which is testable
without timing anything: the handler must not call remove_background.
"""
import pytest

import routes_clothes
from conftest import create_cloth, make_png


def _statuses(cloth):
    return [im["cutout_status"] for im in cloth["images"]]


def test_the_upload_does_not_wait_for_the_cutout(client, auth, monkeypatch):
    """The point of the change: the cut-out runs after the handler has produced
    its answer, not before.

    Asserted by ordering rather than by a stopwatch — TestClient drains
    background tasks inside the same call, so wall-clock time here includes work
    the real client never waits for, and a timing assertion would be measuring
    the test harness.
    """
    order = []
    real_hydrate = routes_clothes._hydrate
    real_remove = routes_clothes.remove_background

    def hydrate(conn, row):
        result = real_hydrate(conn, row)
        order.append("answer")       # the handler now has what it will return
        return result

    def remove(src, dst, **kw):
        order.append("cutout")
        return real_remove(src, dst, **kw)

    monkeypatch.setattr(routes_clothes, "_hydrate", hydrate)
    monkeypatch.setattr(routes_clothes, "remove_background", remove)

    body = create_cloth(client, auth)

    assert "cutout" in order, "the cut-out never ran at all"
    assert order[0] == "answer", \
        f"background removal ran before the answer was ready: {order}"
    assert _statuses(body) == ["processing", "processing"]


def test_the_garment_is_usable_immediately(client, auth):
    """It has to be a real garment, not a placeholder: an image to show, and a
    URL that actually serves."""
    body = create_cloth(client, auth)
    first = body["images"][0]

    assert first["cutout_url"], "nothing to display while it processes"
    assert client.get(first["cutout_url"].split("?")[0]).status_code == 200
    # Standing in with the original, not with a broken link.
    assert first["cutout_url"].split("?")[0] == \
        first["original_url"].split("?")[0]


def test_it_becomes_ready_on_its_own(client, auth):
    body = create_cloth(client, auth)
    later = client.get(f"/clothes/{body['id']}", headers=auth).json()

    assert _statuses(later) == ["ready", "ready"]
    assert later["images"][0]["cutout_url"] != body["images"][0]["cutout_url"]
    assert ".webp" in later["images"][0]["cutout_url"]
    assert client.get(
        later["images"][0]["cutout_url"].split("?")[0]).status_code == 200


def test_a_failed_cutout_keeps_the_garment(client, auth, monkeypatch):
    """A cut-out is a nicer picture; the garment is the user's data. Losing the
    first must not lose the second."""
    def boom(src, dst, **kw):
        raise RuntimeError("no model on this machine")

    monkeypatch.setattr(routes_clothes, "remove_background", boom)

    body = create_cloth(client, auth, name="Doomed")
    later = client.get(f"/clothes/{body['id']}", headers=auth).json()

    assert later["name"] == "doomed"
    assert _statuses(later) == ["failed", "failed"]
    # Still shows the photo that was uploaded.
    for im in later["images"]:
        assert client.get(im["cutout_url"].split("?")[0]).status_code == 200


def test_each_photo_lands_on_its_own(client, auth, monkeypatch):
    """The front should appear cut out while the back is still going, and one
    failure must not throw away the other's finished work."""
    calls = {"n": 0}
    real = routes_clothes.remove_background

    def flaky(src, dst, **kw):
        calls["n"] += 1
        if calls["n"] == 2:
            raise RuntimeError("second photo fails")
        return real(src, dst, **kw)

    monkeypatch.setattr(routes_clothes, "remove_background", flaky)

    body = create_cloth(client, auth)
    later = client.get(f"/clothes/{body['id']}", headers=auth).json()

    assert _statuses(later) == ["ready", "failed"]
    assert ".webp" in later["images"][0]["cutout_url"]


def test_a_garment_deleted_mid_cutout_does_not_crash_the_worker(client, auth,
                                                               monkeypatch):
    """The job holds image ids, not rows. Deleting the garment while it is
    queued must be a no-op, not an exception in a background task nobody is
    watching."""
    routes_clothes._run_cutouts([999_999])   # never existed; same code path


def test_the_status_survives_a_reread(client, auth):
    """It is a column, not something recomputed from whether a file exists — a
    'failed' cut-out and a 'ready' one can both leave a file on disk."""
    body = create_cloth(client, auth)
    a = client.get(f"/clothes/{body['id']}", headers=auth).json()
    b = client.get("/clothes", headers=auth).json()[0]
    assert _statuses(a) == _statuses(b) == ["ready", "ready"]


def test_old_rows_are_not_reported_as_unfinished(client, auth):
    """Every image that predates the column has a cut-out already. Defaulting
    them to anything else would make the app show a spinner on a whole wardrobe
    that is perfectly fine."""
    import db

    body = create_cloth(client, auth)
    with db.get_conn() as conn:
        conn.execute("UPDATE cloth_images SET cutout_status = NULL")

    later = client.get(f"/clothes/{body['id']}", headers=auth).json()
    assert _statuses(later) == ["ready", "ready"]


def test_replacing_a_single_photo_still_waits(client, auth):
    """Not every path should go async. Replacing one photo shows the result
    straight away, so that one keeps its cut-out in the response."""
    body = create_cloth(client, auth)
    image_id = body["images"][0]["id"]

    r = client.post(
        f"/clothes/{body['id']}/images/{image_id}/replace",
        headers=auth,
        files={"image": ("new.png", make_png(), "image/png")},
    )
    if r.status_code == 404:
        pytest.skip("no replace endpoint in this build")
    assert r.status_code == 200, r.text
    replaced = r.json()["images"][0]
    assert ".webp" in replaced["cutout_url"], \
        "the replaced photo came back without its cut-out"
