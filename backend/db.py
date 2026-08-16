import logging
import os
import sqlite3
from contextlib import contextmanager

from config import DB_PATH

log = logging.getLogger(__name__)

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    email         TEXT UNIQUE NOT NULL COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    is_admin      INTEGER NOT NULL DEFAULT 0,
    outfits_generated INTEGER NOT NULL DEFAULT 0,  -- lifetime counter, never decreases
    created_at    TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS clothes (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    brand       TEXT NOT NULL DEFAULT '',
    cut         TEXT NOT NULL DEFAULT '',
    category    TEXT NOT NULL DEFAULT '',
    custom_tags TEXT NOT NULL DEFAULT '[]',
    score       INTEGER NOT NULL DEFAULT 0,   -- 0 = unrated, 1..5 = user rating
    last_worn_at TEXT,                         -- NULL = never worn; else 'YYYY-MM-DD'
    is_favorite INTEGER NOT NULL DEFAULT 0,    -- favorite clothes (≠ favorite outfits)
    exclude_from_algo INTEGER NOT NULL DEFAULT 0, -- skip this cloth in generation algorithms
    created_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at  TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS cloth_wears (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id   INTEGER NOT NULL,
    cloth_id  INTEGER NOT NULL REFERENCES clothes(id) ON DELETE CASCADE,
    day       TEXT NOT NULL,                   -- 'YYYY-MM-DD'
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(cloth_id, day)
);

CREATE TABLE IF NOT EXISTS cloth_images (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    cloth_id      INTEGER NOT NULL REFERENCES clothes(id) ON DELETE CASCADE,
    role          TEXT NOT NULL,          -- 'front' | 'back' | 'extra'
    original_path TEXT NOT NULL,
    cutout_path   TEXT NOT NULL,
    sort_order    INTEGER NOT NULL DEFAULT 0,
    bg_accepted   TEXT NOT NULL DEFAULT 'pending',  -- 'pending' | 'accepted' | 'rejected'
    bg_tolerance  TEXT NOT NULL DEFAULT 'medium',   -- 'low' | 'medium' | 'high' removal strength
    enhanced_path TEXT,                    -- pending enhanced candidate (accept/reject)
    enhance_status TEXT,                   -- NULL | 'processing' | 'ready' | 'failed'
    enhance_method TEXT NOT NULL DEFAULT 'none',  -- applied: 'none' | 'auto' | 'ai'
    enhance_pending_method TEXT,           -- method of the pending candidate
    enhance_tier TEXT                      -- AI tier of the pending candidate
);

CREATE TABLE IF NOT EXISTS cloth_colors (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    cloth_id  INTEGER NOT NULL REFERENCES clothes(id) ON DELETE CASCADE,
    color     TEXT NOT NULL,
    dominance TEXT NOT NULL              -- 'full' | 'part' | 'little'
);

CREATE TABLE IF NOT EXISTS notifications (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL,         -- who reported it
    cloth_id   INTEGER NOT NULL,
    image_id   INTEGER NOT NULL,
    message    TEXT NOT NULL,
    resolved   INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS models (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name       TEXT NOT NULL,
    gender     TEXT NOT NULL DEFAULT '',   -- '' unknown | 'male' | 'female'
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS model_images (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    model_id      INTEGER NOT NULL REFERENCES models(id) ON DELETE CASCADE,
    role          TEXT NOT NULL,          -- 'front' | 'back'
    original_path TEXT NOT NULL,
    cutout_path   TEXT NOT NULL,
    sort_order    INTEGER NOT NULL DEFAULT 0,
    bg_accepted   TEXT NOT NULL DEFAULT 'pending'
);

CREATE TABLE IF NOT EXISTS outfits (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id            INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    model_id           INTEGER REFERENCES models(id) ON DELETE SET NULL,
    cloth_ids          TEXT NOT NULL DEFAULT '[]',   -- JSON array
    prompt             TEXT NOT NULL DEFAULT '',
    generated_path     TEXT NOT NULL DEFAULT '',
    status             TEXT NOT NULL DEFAULT 'done',  -- 'done' | 'failed'
    is_mock            INTEGER NOT NULL DEFAULT 0,
    model_tier         TEXT NOT NULL DEFAULT 'flex',  -- 'flex' | 'pro' | 'max'
    model_slug         TEXT NOT NULL DEFAULT '',
    view               TEXT NOT NULL DEFAULT 'front', -- 'front' | 'back'
    linked_id          INTEGER,                       -- paired opposite-view outfit
    is_favorite        INTEGER NOT NULL DEFAULT 0,
    describe_clothes   INTEGER NOT NULL DEFAULT 0,     -- add item names/types to the prompt
    image_mode         TEXT NOT NULL DEFAULT 'collage', -- 'collage' | 'separate' cloth reference images
    render_cloth_ids   TEXT NOT NULL DEFAULT '[]',      -- JSON subset actually rendered ([] = all)
    error              TEXT NOT NULL DEFAULT '',
    kind               TEXT NOT NULL DEFAULT 'ai',       -- 'ai' (generated) | 'manual' (non-AI builder)
    layout             TEXT NOT NULL DEFAULT '',         -- JSON builder layout (bg + placed items); manual only
    created_at         TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS outfit_blacklist (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    combo      TEXT NOT NULL,                 -- canonical sorted cloth-id set, e.g. "3,7,12"
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, combo)
);

CREATE TABLE IF NOT EXISTS agenda (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    day        TEXT NOT NULL,                 -- 'YYYY-MM-DD' the outfit is planned for
    outfit_id  INTEGER REFERENCES outfits(id) ON DELETE SET NULL,
    title      TEXT NOT NULL DEFAULT '',      -- optional label, e.g. "Dinner", "Work"
    note       TEXT NOT NULL DEFAULT '',
    worn       INTEGER NOT NULL DEFAULT 0,    -- 1 once the user confirms they wore it
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS outfit_reports (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    outfit_id  INTEGER NOT NULL REFERENCES outfits(id) ON DELETE CASCADE,
    tier       TEXT NOT NULL,
    slug       TEXT NOT NULL DEFAULT '',
    message    TEXT NOT NULL,
    resolved   INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_clothes_user ON clothes(user_id);
CREATE INDEX IF NOT EXISTS idx_images_cloth ON cloth_images(cloth_id);
CREATE INDEX IF NOT EXISTS idx_colors_cloth ON cloth_colors(cloth_id);
CREATE INDEX IF NOT EXISTS idx_notifs_unresolved ON notifications(resolved);
CREATE INDEX IF NOT EXISTS idx_models_user ON models(user_id);
CREATE INDEX IF NOT EXISTS idx_outfits_user ON outfits(user_id);
CREATE INDEX IF NOT EXISTS idx_outfits_fav ON outfits(user_id, is_favorite);
CREATE TABLE IF NOT EXISTS audit_log (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id    INTEGER,               -- null for anonymous / pre-auth events
    email      TEXT,
    action     TEXT NOT NULL,         -- e.g. 'auth.login', 'cloth.create'
    detail     TEXT NOT NULL DEFAULT '',
    ip         TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_agenda_user_day ON agenda(user_id, day);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_log(created_at);
"""


# --- migrations -----------------------------------------------------------
# Each function bumps the schema by one version, tracked in PRAGMA user_version.
# Before this, every migration re-ran on every single startup (~40 PRAGMA
# table_info round-trips) purely to discover there was nothing to do.
# Append new steps to the end. Never renumber or edit a shipped one.
MIGRATIONS = []


def migration(fn):
    MIGRATIONS.append(fn)
    return fn


def _run_migrations(conn) -> None:
    current = conn.execute("PRAGMA user_version").fetchone()[0]
    target = len(MIGRATIONS)
    if current >= target:
        return
    for version, fn in enumerate(MIGRATIONS, start=1):
        if version <= current:
            continue
        log.info("applying migration v%s (%s)", version, fn.__name__)
        fn(conn)
        # user_version takes no bound parameters; the value is a loop counter.
        conn.execute(f"PRAGMA user_version = {version}")


@migration
def _migrate(conn) -> None:
    """Add columns/tables introduced after the initial schema, idempotently."""
    ucols = {r[1] for r in conn.execute("PRAGMA table_info(users)")}
    if "is_admin" not in ucols:
        conn.execute("ALTER TABLE users ADD COLUMN is_admin INTEGER NOT NULL DEFAULT 0")
    if "outfits_generated" not in ucols:
        conn.execute("ALTER TABLE users ADD COLUMN outfits_generated INTEGER NOT NULL DEFAULT 0")
    cols = {r[1] for r in conn.execute("PRAGMA table_info(clothes)")}
    if "score" not in cols:
        conn.execute("ALTER TABLE clothes ADD COLUMN score INTEGER NOT NULL DEFAULT 0")
    if "last_worn_at" not in cols:
        conn.execute("ALTER TABLE clothes ADD COLUMN last_worn_at TEXT")
    if "is_favorite" not in cols:
        conn.execute("ALTER TABLE clothes ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0")
    if "exclude_from_algo" not in cols:
        conn.execute("ALTER TABLE clothes ADD COLUMN exclude_from_algo INTEGER NOT NULL DEFAULT 0")
    # Brands are normalised to UPPERCASE; bring any legacy lower/mixed-case rows
    # into line so they dedupe with newly-entered ones. Idempotent.
    conn.execute("UPDATE clothes SET brand = UPPER(brand) "
                 "WHERE brand IS NOT NULL AND brand <> UPPER(brand)")
    # Cloth names are normalised to lowercase. Idempotent.
    conn.execute("UPDATE clothes SET name = LOWER(name) "
                 "WHERE name IS NOT NULL AND name <> LOWER(name)")
    mcols = {r[1] for r in conn.execute("PRAGMA table_info(models)")}
    if "gender" not in mcols:
        conn.execute("ALTER TABLE models ADD COLUMN gender TEXT NOT NULL DEFAULT ''")
    cols_img = {r[1] for r in conn.execute("PRAGMA table_info(cloth_images)")}
    if "bg_accepted" not in cols_img:
        conn.execute(
            "ALTER TABLE cloth_images ADD COLUMN bg_accepted TEXT NOT NULL DEFAULT 'pending'"
        )
    if "enhanced_path" not in cols_img:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN enhanced_path TEXT")
    if "enhance_status" not in cols_img:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN enhance_status TEXT")
    if "enhance_method" not in cols_img:
        conn.execute(
            "ALTER TABLE cloth_images ADD COLUMN enhance_method TEXT NOT NULL DEFAULT 'none'"
        )
    if "enhance_pending_method" not in cols_img:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN enhance_pending_method TEXT")
    if "enhance_tier" not in cols_img:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN enhance_tier TEXT")
    if "bg_tolerance" not in cols_img:
        conn.execute(
            "ALTER TABLE cloth_images ADD COLUMN bg_tolerance TEXT NOT NULL DEFAULT 'medium'"
        )
    ocols = {r[1] for r in conn.execute("PRAGMA table_info(outfits)")}
    if "model_tier" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN model_tier TEXT NOT NULL DEFAULT 'flex'")
    if "model_slug" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN model_slug TEXT NOT NULL DEFAULT ''")
    if "view" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN view TEXT NOT NULL DEFAULT 'front'")
    if "is_favorite" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN is_favorite INTEGER NOT NULL DEFAULT 0")
    if "error" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN error TEXT NOT NULL DEFAULT ''")
    if "linked_id" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN linked_id INTEGER")
    if "describe_clothes" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN describe_clothes INTEGER NOT NULL DEFAULT 0")
    if "image_mode" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN image_mode TEXT NOT NULL DEFAULT 'collage'")
    if "render_cloth_ids" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN render_cloth_ids TEXT NOT NULL DEFAULT '[]'")
    if "kind" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN kind TEXT NOT NULL DEFAULT 'ai'")
    if "layout" not in ocols:
        conn.execute("ALTER TABLE outfits ADD COLUMN layout TEXT NOT NULL DEFAULT ''")


@migration
def _indexes_for_hot_lookups(conn) -> None:
    """Indexes for joins/filters that were doing full table scans.

    Every one of these backs a query the app issues on a normal screen load:
    the agenda "worn today" lookup, the model image fetch during generation,
    the per-user wear counts on the profile, and the two report queues.
    """
    for stmt in (
        "CREATE INDEX IF NOT EXISTS idx_model_images_model ON model_images(model_id)",
        "CREATE INDEX IF NOT EXISTS idx_agenda_outfit ON agenda(outfit_id)",
        "CREATE INDEX IF NOT EXISTS idx_cloth_wears_user ON cloth_wears(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_cloth_wears_cloth ON cloth_wears(cloth_id)",
        "CREATE INDEX IF NOT EXISTS idx_notifs_user ON notifications(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_reports_outfit ON outfit_reports(outfit_id)",
        "CREATE INDEX IF NOT EXISTS idx_reports_unresolved ON outfit_reports(resolved)",
        "CREATE INDEX IF NOT EXISTS idx_audit_user ON audit_log(user_id)",
        "CREATE INDEX IF NOT EXISTS idx_outfits_user_status ON outfits(user_id, status)",
    ):
        conn.execute(stmt)


@migration
def _rate_limit_table(conn) -> None:
    """Rate-limit counters, shared by every worker.

    In process memory they were per-worker, so N workers meant N times the
    quota and inconsistent answers depending on who handled the request.
    """
    conn.execute("""
        CREATE TABLE IF NOT EXISTS rate_hits (
            id  INTEGER PRIMARY KEY AUTOINCREMENT,
            key TEXT NOT NULL,
            ts  REAL NOT NULL
        )
    """)
    conn.execute("CREATE INDEX IF NOT EXISTS idx_rate_hits_key ON rate_hits(key, ts)")


@migration
def _generation_owner(conn) -> None:
    """Which process is rendering an outfit right now.

    The startup sweep used to fail every row still marked 'processing', which
    is correct with one worker and destructive with several: a restarting
    worker would kill jobs its siblings were actively running.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(outfits)")}
    if "worker_pid" not in cols:
        conn.execute("ALTER TABLE outfits ADD COLUMN worker_pid INTEGER")


def _process_alive(pid) -> bool:
    """Is that process still running on this machine?"""
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)          # signal 0 only checks for existence
    except (OSError, ValueError, TypeError):
        return False
    return True


@migration
def _password_change_invalidates_tokens(conn) -> None:
    """Lets a password change cut off sessions opened before it.

    Tokens are self-contained: nothing on the server tracks them, so changing a
    password would otherwise leave every existing session working — which
    defeats the main reason anyone changes one.

    Recording when tokens stop being accepted is enough: a token carries its
    issue time, and one older than this is refused.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(users)")}
    if "tokens_valid_from" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN tokens_valid_from INTEGER")


@migration
def _cutout_runs_in_the_background(conn) -> None:
    """Lets a garment exist before its cut-out does.

    Background removal is ~5 s a photo on the deployment server, and a garment
    has two, so adding one held the request — and the whole screen — for fifteen
    seconds. The AI enhancement already worked the other way: return, then
    report progress. This is the column that lets uploads do the same.

    Rows that predate this have a cut-out already, so 'ready' is the truth for
    them, not a default that happens to be convenient.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(cloth_images)")}
    if "cutout_status" not in cols:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN cutout_status TEXT")
        conn.execute("UPDATE cloth_images SET cutout_status = 'ready'")


@migration
def _weather_location(conn) -> None:
    """Where to look up the forecast for this user.

    Stored per account rather than read from the device on every request: the
    app then needs no location permission, and the answer stays the same when
    the phone is somewhere else for an afternoon. A NULL pair means "not set",
    which every weather path treats as "no forecast" and falls back from.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(users)")}
    if "weather_lat" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN weather_lat REAL")
    if "weather_lon" not in cols:
        conn.execute("ALTER TABLE users ADD COLUMN weather_lon REAL")
    if "weather_place" not in cols:
        conn.execute(
            "ALTER TABLE users ADD COLUMN weather_place TEXT NOT NULL DEFAULT ''")


@migration
def _enhance_started_at(conn) -> None:
    """When an enhancement was kicked off, so a stuck one can be recognised.

    Without it, a job whose worker died — a server restart, a provider that
    never answers — stays 'processing' forever and the app spins on it. There
    was already a sweep for outfits; enhancements had none.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(cloth_images)")}
    if "enhance_started_at" not in cols:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN enhance_started_at TEXT")
        # Anything already 'processing' predates the column and cannot be
        # running any more — the process that owned it is gone.
        conn.execute(
            "UPDATE cloth_images SET enhance_status = 'failed' "
            "WHERE enhance_status = 'processing'")


@migration
def _api_usage(conn) -> None:
    """Every paid image job this server submits.

    The provider does not document a balance endpoint, so the only figure that
    can be stated truthfully is our own consumption. Recorded at submit time,
    which is the moment that costs.
    """
    conn.execute("""
        CREATE TABLE IF NOT EXISTS api_usage (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id    INTEGER,
            kind       TEXT NOT NULL DEFAULT '',   -- 'outfit' | 'enhance' | ''
            tier       TEXT NOT NULL DEFAULT '',
            slug       TEXT NOT NULL DEFAULT '',
            ok         INTEGER NOT NULL DEFAULT 1, -- 0 = the submit was refused
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_api_usage_created ON api_usage(created_at)")


@migration
def _enhance_failure_reason(conn) -> None:
    """Why an enhancement failed, and at which tier it was tried.

    Reported: some garments "ne veulent pas s'ameliorer avec l'IA et mettent
    sans cesse fail meme apres reessayer". Retrying the same thing that just
    failed is the only move the app could offer, because the only thing it knew
    was the word "failed". Storing the reason lets it say what happened, and
    keeping the attempted tier lets it offer the next one up.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(cloth_images)")}
    if "enhance_error" not in cols:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN enhance_error TEXT")


@migration
def _outfit_shares(conn) -> None:
    """Public links to a single outfit.

    A row per link rather than a signature over the outfit id, for one reason:
    a link somebody regrets sending has to be revocable, and a pure signature
    cannot be taken back. Expiry is stored so an old link stops working even if
    nobody revokes it.
    """
    conn.execute("""
        CREATE TABLE IF NOT EXISTS outfit_shares (
            token      TEXT PRIMARY KEY,
            outfit_id  INTEGER NOT NULL REFERENCES outfits(id) ON DELETE CASCADE,
            user_id    INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            revoked    INTEGER NOT NULL DEFAULT 0,
            expires_at TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    """)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_shares_outfit ON outfit_shares(outfit_id)")


@migration
def _api_usage_cost(conn) -> None:
    """What each job actually cost, from the provider's own reply.

    Every FLUX.2 submit answers with `cost` in credits and `output_mp`. Counting
    calls was a proxy; this is the number. Rows written before this exist with
    NULL, which is why the summary reports how many it could price.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(api_usage)")}
    if "cost" not in cols:
        conn.execute("ALTER TABLE api_usage ADD COLUMN cost REAL")
    if "output_mp" not in cols:
        conn.execute("ALTER TABLE api_usage ADD COLUMN output_mp REAL")


@migration
def _outfit_add_detail(conn) -> None:
    """The extra instruction the user typed on a regenerate ("hands in
    pockets"), as a column rather than smuggled into the prompt text.

    It used to be glued onto the front of the user's own prompt, which is the
    one position the FLUX.2 guide says not to put a secondary detail in — it
    displaces the subject sentence, which the model weights most. Moving it
    after the subject meant it no longer survived the next re-compose, because
    _user_prompt_of recovers the user's text by cutting at the generated
    markers. Storing it is what lets it be in the right place AND persist, like
    describe_clothes / image_mode / render_cloth_ids already are.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(outfits)")}
    if "add_detail" not in cols:
        conn.execute(
            "ALTER TABLE outfits ADD COLUMN add_detail TEXT NOT NULL DEFAULT ''")


@migration
def _enhance_describe(conn) -> None:
    """Whether the owner's own description of the garment goes into the AI
    enhancement prompt.

    Stored per image, not passed per request, for the same reason the outfit's
    add_detail is stored: the retry buttons re-post the same job, and a choice
    that silently reverted to the default on retry is a setting the user cannot
    trust. NULL means "never chosen", which reads as the default.
    """
    cols = {r[1] for r in conn.execute("PRAGMA table_info(cloth_images)")}
    if "enhance_describe" not in cols:
        conn.execute("ALTER TABLE cloth_images ADD COLUMN enhance_describe INTEGER")


def fail_stale_enhancements(conn, timeout_s: float) -> int:
    """Mark long-running enhancements as failed. Returns how many.

    Called on startup and again whenever a cloth is read, so the app learns the
    truth on its next poll instead of at the next server restart.
    """
    rows = conn.execute(
        "SELECT id FROM cloth_images WHERE enhance_status = 'processing' AND ("
        "  enhance_started_at IS NULL"
        "  OR (julianday('now') - julianday(enhance_started_at)) * 86400.0 > ?"
        ")",
        (float(timeout_s),),
    ).fetchall()
    if not rows:
        return 0
    ids = [r["id"] for r in rows]
    ph = ",".join("?" * len(ids))
    conn.execute(
        f"UPDATE cloth_images SET enhance_status = 'failed', "
        f"enhance_error = 'Timed out — the job did not finish in time' "
        f"WHERE id IN ({ph})",
        ids,
    )
    log.warning("marked %s stalled enhancement(s) as failed", len(ids))
    return len(ids)


def reset_orphan_generations(conn) -> int:
    """Fail outfits whose rendering process is gone.

    Generation runs as an in-process background task, so a row marked
    'processing' whose owner has died will spin in the app's poll loop forever.

    Only genuinely orphaned rows are touched. With several uvicorn workers, a
    restarting worker must not fail the jobs its live siblings are still
    running — which is exactly what an unconditional sweep used to do. Rows
    predating this column have no owner recorded and are treated as orphans,
    which is right: they belong to a process that no longer exists.
    """
    rows = conn.execute(
        "SELECT id, worker_pid FROM outfits WHERE status = 'processing'"
    ).fetchall()
    orphans = [r["id"] for r in rows if not _process_alive(r["worker_pid"])]
    if not orphans:
        return 0
    placeholders = ",".join("?" * len(orphans))
    conn.execute(
        f"UPDATE outfits SET status = 'failed', "
        f"error = 'Generation was interrupted by a server restart' "
        f"WHERE id IN ({placeholders})",
        orphans,
    )
    log.warning("marked %s interrupted generation(s) as failed", len(orphans))
    return len(orphans)


def create_tables() -> None:
    with get_conn() as conn:
        conn.executescript(SCHEMA)
        _run_migrations(conn)
        reset_orphan_generations(conn)
    _log_state()


def _log_state() -> None:
    """Print the resolved DB path + row counts at startup so it's obvious
    where data lives and that restarts preserve it (not wipe it)."""
    try:
        with get_conn() as conn:
            counts = {}
            for t in ("users", "clothes", "cloth_images", "models", "model_images", "outfits"):
                counts[t] = conn.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0]
        log.info("persisted at %s", DB_PATH)
        log.info("row counts: %s", counts)
    except Exception as e:  # pragma: no cover
        log.warning("state log failed: %s", e)


# journal_mode is stored in the DB header, so it survives every connection and
# every restart — setting it per request cost a file write for no reason. The
# set is keyed by path because tests repoint DB_PATH at a fresh file.
_WAL_SET: set = set()


@contextmanager
def get_conn():
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row
    # These two are per-connection state and must be re-applied every time, but
    # they are pure memory flags — no I/O. NORMAL sync is the safe+fast pair.
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA synchronous = NORMAL")
    if DB_PATH not in _WAL_SET:
        # Durable across crashes and persisted in the header, so the uvicorn
        # reloader's fork keeps working.
        conn.execute("PRAGMA journal_mode = WAL")
        _WAL_SET.add(DB_PATH)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()