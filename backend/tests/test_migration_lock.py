"""Three workers boot at once; only one may migrate.

run-prod.sh starts three uvicorn workers, each calling create_tables(). sqlite3
opens no transaction for DDL or PRAGMA, so all three read the same old
user_version, and all three run the pending migrations.

Today's migrations survive that by luck: each one re-checks PRAGMA table_info
before adding its column, so running it twice is a no-op. The next migration
written without that guard — a data backfill, an INSERT, a CREATE INDEX
without IF NOT EXISTS — would run three times, and a worker would die before
serving anything.

BEGIN IMMEDIATE removes the luck.
"""

import time

import sqlite3
import threading

import db


def test_a_non_idempotent_migration_runs_exactly_once(tmp_path, monkeypatch):
    """The case the per-migration column guards do NOT cover."""
    path = tmp_path / "race.db"
    monkeypatch.setattr(db, "DB_PATH", str(path))
    db._WAL_SET.clear()
    db.create_tables()          # up to date, then append one more migration

    runs: list = []

    def counts_itself(conn):
        runs.append(1)
        # Slow enough to overlap the window the workers share: between reading
        # user_version and writing it back.
        time.sleep(0.05)
        conn.execute("CREATE TABLE backfill_probe (id INTEGER PRIMARY KEY)")

    monkeypatch.setattr(db, "MIGRATIONS", db.MIGRATIONS + [counts_itself])

    errors: list = []
    barrier = threading.Barrier(3)

    def boot():
        try:
            barrier.wait(timeout=10)
            with db.get_conn() as conn:
                db._run_migrations(conn)
        except Exception as e:  # noqa: BLE001 - the point of the test
            errors.append(e)

    threads = [threading.Thread(target=boot) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)

    assert not errors, f"a worker failed to boot: {errors}"
    assert len(runs) == 1, f"the migration ran {len(runs)} times"


def test_concurrent_boots_migrate_once(tmp_path, monkeypatch):
    path = tmp_path / "race2.db"
    monkeypatch.setattr(db, "DB_PATH", str(path))
    db._WAL_SET.clear()

    errors: list = []
    barrier = threading.Barrier(3)

    def boot():
        try:
            barrier.wait(timeout=10)      # start together, maximise the overlap
            db.create_tables()
        except Exception:                 # noqa: BLE001 - the point of the test
            import traceback
            errors.append(traceback.format_exc())

    threads = [threading.Thread(target=boot) for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=30)

    assert not errors, f"a worker failed to boot: {errors}"

    with sqlite3.connect(path) as conn:
        assert conn.execute("PRAGMA user_version").fetchone()[0] == len(db.MIGRATIONS)
        # Every table the schema promises is there, exactly once.
        names = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")]
        assert len(names) == len(set(names))
        for expected in ("users", "clothes", "cloth_images", "outfits"):
            assert expected in names


def test_an_up_to_date_database_takes_no_write_lock(tmp_path, monkeypatch):
    """The normal boot must not serialise on a lock it does not need."""
    path = tmp_path / "ready.db"
    monkeypatch.setattr(db, "DB_PATH", str(path))
    db._WAL_SET.clear()
    db.create_tables()

    with db.get_conn() as conn:
        started = []
        real = conn.execute

        class Spy:
            def execute(self, sql, *a, **k):
                started.append(sql)
                return real(sql, *a, **k)

        db._run_migrations(Spy())
        assert not any("BEGIN" in s.upper() for s in started), started


def test_a_failing_migration_leaves_the_version_alone(tmp_path, monkeypatch):
    """A half-applied migration must not be recorded as done."""
    path = tmp_path / "boom.db"
    monkeypatch.setattr(db, "DB_PATH", str(path))
    db._WAL_SET.clear()
    db.create_tables()

    def explodes(conn):
        raise RuntimeError("migration blew up")

    monkeypatch.setattr(db, "MIGRATIONS", db.MIGRATIONS + [explodes])

    with db.get_conn() as conn:
        before = conn.execute("PRAGMA user_version").fetchone()[0]
        try:
            db._run_migrations(conn)
        except RuntimeError:
            pass
        assert conn.execute("PRAGMA user_version").fetchone()[0] == before
