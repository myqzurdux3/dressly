"""Schema versioning, indexes, and restart recovery."""
import sqlite3

import db


def _index_names(conn):
    return {
        r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'index'"
        )
    }


def test_migrations_stamp_the_schema_version():
    with db.get_conn() as conn:
        version = conn.execute("PRAGMA user_version").fetchone()[0]
    assert version == len(db.MIGRATIONS)


def test_migrations_are_idempotent():
    """create_tables runs on every startup; a second pass must be a no-op."""
    db.create_tables()
    db.create_tables()
    with db.get_conn() as conn:
        assert conn.execute("PRAGMA user_version").fetchone()[0] == len(db.MIGRATIONS)


def test_already_migrated_db_skips_the_migration_body(monkeypatch):
    """The whole point of user_version: stop re-running 40 PRAGMA probes per boot."""
    calls = []

    def spy(conn):
        calls.append(1)

    monkeypatch.setattr(db, "MIGRATIONS", db.MIGRATIONS[:] + [spy])
    with db.get_conn() as conn:
        db._run_migrations(conn)          # applies the appended step
        assert len(calls) == 1
        db._run_migrations(conn)          # already at target -> nothing runs
        assert len(calls) == 1


def test_hot_lookup_indexes_exist():
    expected = {
        "idx_model_images_model", "idx_agenda_outfit", "idx_cloth_wears_user",
        "idx_cloth_wears_cloth", "idx_notifs_user", "idx_reports_outfit",
        "idx_reports_unresolved", "idx_audit_user", "idx_outfits_user_status",
    }
    with db.get_conn() as conn:
        assert expected <= _index_names(conn)


def test_agenda_lookup_uses_its_index():
    with db.get_conn() as conn:
        plan = " ".join(
            r["detail"] for r in conn.execute(
                "EXPLAIN QUERY PLAN SELECT DISTINCT outfit_id FROM agenda "
                "WHERE worn = 1 AND day = '2026-01-01' AND outfit_id IN (1, 2)"
            )
        )
    assert "SCAN agenda" not in plan, f"full scan of agenda: {plan}"


def test_interrupted_generations_are_failed_on_startup(client, auth):
    """A 'processing' row at boot has no worker behind it — the background task
    died with the previous process. Left alone, the app polls it forever."""
    with db.get_conn() as conn:
        conn.execute("INSERT INTO users (email, password_hash) VALUES (?, ?)",
                     ("orphan@test.co", "x"))
        uid = conn.execute("SELECT id FROM users WHERE email = 'orphan@test.co'"
                           ).fetchone()["id"]
        conn.execute(
            "INSERT INTO outfits (user_id, cloth_ids, status) VALUES (?, '[1]', 'processing')",
            (uid,),
        )

    with db.get_conn() as conn:
        changed = db.reset_orphan_generations(conn)
    assert changed == 1

    with db.get_conn() as conn:
        row = conn.execute(
            "SELECT status, error FROM outfits WHERE user_id = ?", (uid,)
        ).fetchone()
    assert row["status"] == "failed"
    assert "restart" in row["error"]


def test_sweep_leaves_finished_outfits_alone():
    with db.get_conn() as conn:
        conn.execute("INSERT INTO users (email, password_hash) VALUES ('d@t.co', 'x')")
        uid = conn.execute("SELECT id FROM users WHERE email='d@t.co'").fetchone()["id"]
        for st in ("done", "failed"):
            conn.execute(
                "INSERT INTO outfits (user_id, cloth_ids, status) VALUES (?, '[]', ?)",
                (uid, st),
            )
        assert db.reset_orphan_generations(conn) == 0


def test_foreign_keys_are_enforced_on_every_connection():
    """Per-connection pragma — it must not get lost when we stopped re-issuing
    the journal_mode one."""
    with db.get_conn() as conn:
        assert conn.execute("PRAGMA foreign_keys").fetchone()[0] == 1


def test_wal_mode_is_active():
    with db.get_conn() as conn:
        assert conn.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"


def test_wal_survives_a_connection_that_skips_the_pragma():
    """journal_mode lives in the DB header, which is why setting it once is
    enough — verify that assumption rather than trusting it."""
    with db.get_conn():
        pass  # opening a managed connection is what sets WAL the first time
    raw = sqlite3.connect(db.DB_PATH)
    try:
        assert raw.execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    finally:
        raw.close()
