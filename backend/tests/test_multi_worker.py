"""Running more than one uvicorn worker must not corrupt shared state.

Two things used to assume a single process: the rate-limit counters (in memory,
so N workers allowed N times the quota) and the startup sweep, which failed
every outfit still marked 'processing' — correct with one worker, destructive
with several, since a restarting worker would kill jobs its siblings were
actively running.
"""
import os

import db


def _make_user(conn, email="w@test.co"):
    conn.execute("INSERT INTO users (email, password_hash) VALUES (?, 'x')",
                 (email,))
    return conn.execute("SELECT id FROM users WHERE email = ?",
                        (email,)).fetchone()["id"]


def _processing_outfit(conn, uid, worker_pid):
    conn.execute(
        "INSERT INTO outfits (user_id, cloth_ids, status, worker_pid) "
        "VALUES (?, '[1]', 'processing', ?)", (uid, worker_pid))
    return conn.execute("SELECT MAX(id) AS id FROM outfits").fetchone()["id"]


def test_a_live_sibling_worker_keeps_its_job():
    """The regression that matters: worker B restarting must not fail the
    outfit worker A is still rendering."""
    with db.get_conn() as conn:
        uid = _make_user(conn)
        # This process is alive by definition, standing in for the sibling.
        mine = _processing_outfit(conn, uid, os.getpid())

        assert db.reset_orphan_generations(conn) == 0

        row = conn.execute("SELECT status FROM outfits WHERE id = ?",
                           (mine,)).fetchone()
    assert row["status"] == "processing", "a running job was killed"


def test_a_job_whose_process_died_is_failed():
    with db.get_conn() as conn:
        uid = _make_user(conn, "dead@test.co")
        # A pid high enough that nothing can be running under it here.
        orphan = _processing_outfit(conn, uid, 2_147_483_600)

        assert db.reset_orphan_generations(conn) == 1

        row = conn.execute("SELECT status, error FROM outfits WHERE id = ?",
                           (orphan,)).fetchone()
    assert row["status"] == "failed"
    assert "restart" in row["error"]


def test_rows_predating_the_owner_column_are_treated_as_orphans():
    """They belong to a process that is definitionally gone."""
    with db.get_conn() as conn:
        uid = _make_user(conn, "legacy@test.co")
        legacy = _processing_outfit(conn, uid, None)

        assert db.reset_orphan_generations(conn) == 1
        row = conn.execute("SELECT status FROM outfits WHERE id = ?",
                           (legacy,)).fetchone()
    assert row["status"] == "failed"


def test_a_mix_reaps_only_the_dead():
    with db.get_conn() as conn:
        uid = _make_user(conn, "mix@test.co")
        alive = _processing_outfit(conn, uid, os.getpid())
        dead = _processing_outfit(conn, uid, 2_147_483_600)

        assert db.reset_orphan_generations(conn) == 1

        statuses = {
            r["id"]: r["status"]
            for r in conn.execute(
                "SELECT id, status FROM outfits WHERE id IN (?, ?)",
                (alive, dead))
        }
    assert statuses[alive] == "processing"
    assert statuses[dead] == "failed"


def test_process_alive_handles_rubbish_values():
    assert db._process_alive(os.getpid()) is True
    assert db._process_alive(None) is False
    assert db._process_alive("") is False
    assert db._process_alive("not-a-pid") is False
    assert db._process_alive(2_147_483_600) is False


def test_finished_outfits_are_never_touched():
    with db.get_conn() as conn:
        uid = _make_user(conn, "done@test.co")
        for status in ("done", "failed"):
            conn.execute(
                "INSERT INTO outfits (user_id, cloth_ids, status) "
                "VALUES (?, '[]', ?)", (uid, status))
        assert db.reset_orphan_generations(conn) == 0


def test_generation_stamps_and_clears_its_owner(client, auth):
    """End to end: the row carries an owner while rendering and none after."""
    from tests.conftest import create_cloth, gen_outfit

    c = create_cloth(client, auth)
    outfit = gen_outfit(client, auth, [c["id"]])

    with db.get_conn() as conn:
        row = conn.execute("SELECT status, worker_pid FROM outfits WHERE id = ?",
                           (outfit["id"],)).fetchone()
    assert row["status"] in ("done", "failed")
    assert row["worker_pid"] is None, "the claim was not released"
