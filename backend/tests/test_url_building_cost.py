"""The URL builders are called five times per photo, so their per-call work shows.

Measured before the fix, on a 60-garment wardrobe: `_hydrate_many` took 16.1 ms,
of which 14.6 ms was building URLs (720 calls). Resolving which mount a path
belongs to — a try/except `relative_to` loop — was the bulk of it, and it is
the same answer every time for a given file.

These tests pin the two properties that make the cache safe, not the timing
(which would be flaky on a loaded machine).
"""

import os
import time

import images
import routes_thumbs


def test_the_cache_key_is_the_path_not_the_content(tmp_path):
    """A rewritten file keeps its URL path but must get a fresh ?v."""
    f = tmp_path / "shot.webp"
    f.write_bytes(b"one")
    first = images.public_url_for(str(f))

    time.sleep(0.01)
    f.write_bytes(b"two")
    second = images.public_url_for(str(f))

    assert first.split("?")[0] == second.split("?")[0]
    assert first != second, "the mtime must not be cached with the path"


def test_thumb_urls_also_refresh_on_rewrite(tmp_path, monkeypatch):
    root = tmp_path / "images"
    root.mkdir()
    monkeypatch.setitem(routes_thumbs._ROOTS, "images", root)
    routes_thumbs._rel_under_roots.cache_clear()

    f = root / "3" / "front_0.webp"
    f.parent.mkdir(parents=True)
    f.write_bytes(b"one")
    first = routes_thumbs.thumb_url_for(str(f), 400)
    assert "/thumb/images/400/3/front_0.webp" in first

    time.sleep(0.01)
    f.write_bytes(b"two")
    assert routes_thumbs.thumb_url_for(str(f), 400) != first


def test_a_missing_file_still_yields_a_usable_url(tmp_path):
    missing = tmp_path / "gone.webp"
    url = images.public_url_for(str(missing))
    assert url.startswith("/images/")
    assert "v=" not in url


def test_widths_share_one_stat_per_call(tmp_path, monkeypatch):
    """Each call stats once — five widths of one photo cost five stats, not more."""
    root = tmp_path / "images"
    root.mkdir()
    monkeypatch.setitem(routes_thumbs._ROOTS, "images", root)
    routes_thumbs._rel_under_roots.cache_clear()
    f = root / "3" / "front_0.webp"
    f.parent.mkdir(parents=True)
    f.write_bytes(b"x")

    calls = []
    real = os.stat
    monkeypatch.setattr(routes_thumbs.os, "stat",
                        lambda p, *a, **k: (calls.append(p), real(p, *a, **k))[1])

    for width in (200, 400, 800):
        routes_thumbs.thumb_url_for(str(f), width)
    assert len(calls) == 3


def test_listing_models_costs_one_image_query(client, auth):
    """list_models used to run one SELECT per model (an N+1)."""
    from tests.conftest import make_png

    import routes_models
    from db import get_conn

    for i in range(5):
        r = client.post(
            "/models", headers=auth, data={"name": f"M{i}"},
            files=[("images", ("f.png", make_png(), "image/png")),
                   ("images", ("b.png", make_png(), "image/png"))],
        )
        assert r.status_code == 200, r.text

    class Counting:
        def __init__(self, conn):
            self.conn, self.n = conn, 0

        def execute(self, sql, *a, **k):
            self.n += 1
            return self.conn.execute(sql, *a, **k)

    with get_conn() as conn:
        rows = conn.execute("SELECT * FROM models").fetchall()
        counter = Counting(conn)
        out = routes_models._hydrate_many(counter, rows)

    assert len(out) == 5
    assert all(len(m["images"]) == 2 for m in out)
    assert counter.n == 1, f"{counter.n} queries for {len(rows)} models"
