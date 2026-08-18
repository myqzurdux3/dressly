"""A cut-out that nobody is working on any more must stop saying 'processing'.

_run_cutouts is a BackgroundTasks job. If the process dies between the INSERT
(status 'processing') and the UPDATE, nothing ever revisited the row: the app
showed "still processing" forever, and cutout_path stayed aliased to the
original — the state that made rejecting a background destructive.

Enhancements already had this sweep (fail_stale_enhancements); cut-outs did not.
"""

import config
from db import fail_stale_cutouts, get_conn
from tests.conftest import create_cloth


def _force_processing(image_id, *, started_at=None):
    with get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET cutout_status = 'processing', "
            "cutout_started_at = ? WHERE id = ?",
            (started_at, image_id),
        )


def _status(client, auth, cloth_id):
    return client.get(f"/clothes/{cloth_id}", headers=auth).json()["images"][0]


def test_a_stalled_cutout_is_failed_not_left_processing(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    _force_processing(img["id"], started_at="2020-01-01 00:00:00")

    with get_conn() as conn:
        assert fail_stale_cutouts(conn, config.CUTOUT_TIMEOUT_S) == 1

    row = _status(client, auth, c["id"])
    assert row["cutout_status"] == "failed"


def test_a_cutout_with_no_start_time_is_swept_too(client, auth):
    """Rows written before the column existed have NULL, like the enhancements."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    _force_processing(img["id"], started_at=None)

    with get_conn() as conn:
        assert fail_stale_cutouts(conn, config.CUTOUT_TIMEOUT_S) == 1
    assert _status(client, auth, c["id"])["cutout_status"] == "failed"


def test_a_cutout_still_within_its_budget_is_left_alone(client, auth):
    c = create_cloth(client, auth)
    img = c["images"][0]
    _force_processing(img["id"], started_at="now")

    with get_conn() as conn:
        conn.execute(
            "UPDATE cloth_images SET cutout_started_at = datetime('now') WHERE id = ?",
            (img["id"],),
        )
        assert fail_stale_cutouts(conn, config.CUTOUT_TIMEOUT_S) == 0
    assert _status(client, auth, c["id"])["cutout_status"] == "processing"


def test_the_failed_image_still_shows_the_original_photo(client, auth):
    """Losing a cut-out is a degraded picture; it must not be a blank card."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    _force_processing(img["id"], started_at="2020-01-01 00:00:00")

    with get_conn() as conn:
        fail_stale_cutouts(conn, config.CUTOUT_TIMEOUT_S)

    row = _status(client, auth, c["id"])
    assert row["cutout_url"], "the card must still have something to draw"


def test_reading_a_cloth_sweeps_without_a_restart(client, auth):
    """The app learns the truth on its next poll, not at the next restart."""
    c = create_cloth(client, auth)
    img = c["images"][0]
    _force_processing(img["id"], started_at="2020-01-01 00:00:00")

    assert _status(client, auth, c["id"])["cutout_status"] == "failed"
