"""Enhance job races: a second start while one runs, a reject while the job
runs, and an accept that fails half-way."""
from pathlib import Path

import pytest

import routes_clothes
from conftest import create_cloth
from db import get_conn


def _set_status(image_id, value):
    with get_conn() as conn:
        conn.execute("UPDATE cloth_images SET enhance_status = ? WHERE id = ?",
                     (value, image_id))


def _row(image_id):
    with get_conn() as conn:
        return conn.execute(
            "SELECT enhance_status, enhanced_path FROM cloth_images WHERE id = ?",
            (image_id,)).fetchone()


@pytest.mark.parametrize("busy", ["processing", "accepting"])
def test_enhance_refuses_while_a_run_is_in_flight(client, auth, busy, monkeypatch):
    c = create_cloth(client, auth)
    img = c["images"][0]
    _set_status(img["id"], busy)
    with get_conn() as conn:
        conn.execute("UPDATE cloth_images SET enhance_started_at = datetime('now') "
                     "WHERE id = ?", (img["id"],))
    called = []
    monkeypatch.setattr(routes_clothes, "_run_enhance",
                        lambda *a, **k: called.append(a))
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                    headers=auth, json={"mode": "ai"})
    assert r.status_code == 409, r.text
    assert called == []
    assert _row(img["id"])["enhance_status"] == busy


def test_result_of_a_rejected_run_is_dropped(client, auth, monkeypatch):
    c = create_cloth(client, auth)
    img = c["images"][0]
    produced = []

    def fake_det(src, cutout, dst):
        Path(dst).write_bytes(b"x")
        produced.append(dst)
        # The user rejects while the job is still running.
        _set_status(img["id"], None)

    import enhance
    monkeypatch.setattr(enhance, "enhance_deterministic", fake_det)
    _set_status(img["id"], "processing")
    routes_clothes._run_enhance(c["id"], img["id"], "auto")
    row = _row(img["id"])
    assert row["enhance_status"] is None
    assert row["enhanced_path"] is None
    assert produced and not Path(produced[0]).exists()


def test_failed_accept_releases_the_candidate(client, auth, monkeypatch):
    c = create_cloth(client, auth)
    img = c["images"][0]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/enhance",
                    headers=auth, json={"mode": "auto"})
    assert r.status_code == 200
    assert _row(img["id"])["enhance_status"] == "ready"

    def boom(_):
        raise OSError("disk full")

    monkeypatch.setattr(routes_clothes, "canonical_cutout_path", boom)
    failing = type(client)(client.app, raise_server_exceptions=False)
    r = failing.post(f"/clothes/{c['id']}/images/{img['id']}/enhance/accept",
                     headers=auth)
    assert r.status_code == 500
    assert _row(img["id"])["enhance_status"] == "ready"
