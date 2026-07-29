"""Performance budgets for the paths a user waits on.

These exist because of a real regression: the thumbnail encoder was set to WebP
`method=6`, which took 1677 ms per 400 px thumbnail against 127 ms at method 4 —
thirteen times the work for a file 3.5% smaller. Nothing failed, no error was
logged; the wardrobe simply took half a minute to appear.

Budgets are deliberately loose (roughly 5-10x the measured figure) so they catch
an order-of-magnitude mistake, not normal variation between machines.
"""
import io
import time

import pytest
from PIL import Image

import images
import routes_thumbs
from tests.conftest import create_cloth


def _big_cutout(size=(1600, 1600)) -> Image.Image:
    """A realistic cut-out: photo-like content with a transparent border, which
    is what actually stresses the encoder. A flat colour compresses instantly
    and would make any budget pass."""
    import numpy as np

    rng = np.random.default_rng(0)
    rgb = rng.integers(40, 220, size=(size[1], size[0], 3), dtype=np.uint8)
    alpha = np.zeros((size[1], size[0], 1), dtype=np.uint8)
    alpha[100:-100, 100:-100] = 255
    return Image.fromarray(np.concatenate([rgb, alpha], axis=2), "RGBA")


def _timed(fn, repeat=3):
    best = float("inf")
    for _ in range(repeat):
        t = time.perf_counter()
        fn()
        best = min(best, (time.perf_counter() - t) * 1000)
    return best


# --- the regression that prompted all this --------------------------------

def test_thumbnail_encoding_effort_is_sane():
    """method>4 costs an order of magnitude for a few percent of size, and runs
    while someone is staring at an empty grid."""
    assert routes_thumbs.THUMB_WEBP_METHOD <= 4, (
        "WebP method above 4 makes thumbnail generation ~13x slower"
    )


def test_generating_one_thumbnail_is_fast(tmp_path):
    src = tmp_path / "src.webp"
    _big_cutout().save(src, "WEBP", lossless=True, method=4)
    dst = tmp_path / "out.webp"

    ms = _timed(lambda: routes_thumbs._render(src, dst, 400))

    # Measured at ~90-130 ms on this hardware; 1677 ms was the bug.
    assert ms < 800, f"thumbnail took {ms:.0f} ms — check THUMB_WEBP_METHOD"
    assert dst.stat().st_size < 200 * 1024


def test_a_cached_thumbnail_costs_almost_nothing(client, auth):
    """The second request must not re-encode. If it did, the cache freshness
    check would be broken and every screen would pay the generation cost."""
    c = create_cloth(client, auth)
    url = c["images"][0]["thumb_url"]

    assert client.get(url).status_code == 200          # warm it
    ms = _timed(lambda: client.get(url))

    assert ms < 150, f"a cached thumbnail took {ms:.0f} ms — cache not hit?"


def test_thumbnail_is_much_smaller_than_its_source(client, auth):
    """The whole point of serving thumbnails to the grid."""
    c = create_cloth(client, auth)
    im = c["images"][0]
    full = client.get(im["cutout_url"])
    thumb = client.get(im["thumb_url"])
    assert thumb.status_code == full.status_code == 200
    assert len(thumb.content) <= len(full.content)


# --- listing endpoints ----------------------------------------------------

@pytest.fixture()
def wardrobe(client, auth):
    for i in range(12):
        create_cloth(client, auth, name=f"tee {i}")
    return auth


def test_listing_clothes_is_fast(client, wardrobe):
    ms = _timed(lambda: client.get("/clothes?limit=30", headers=wardrobe))
    assert ms < 500, f"/clothes took {ms:.0f} ms"


def test_paging_does_not_cost_more_than_the_first_page(client, wardrobe):
    """A paged read must not degrade as the offset grows — that would mean the
    query is scanning everything and discarding it."""
    first = _timed(lambda: client.get("/clothes?limit=5", headers=wardrobe))
    later = _timed(lambda: client.get("/clothes?limit=5&offset=6", headers=wardrobe))
    assert later < max(first * 4, 400), (
        f"page 2 ({later:.0f} ms) far slower than page 1 ({first:.0f} ms)"
    )


def test_listing_does_not_issue_a_query_per_cloth(client, wardrobe, monkeypatch):
    """The N+1 guard. Hydration is batched into two grouped queries; if that
    regressed, the query count would grow with the wardrobe rather than stay
    flat, and the list would slow down as clothes are added."""
    import contextlib

    import db

    seen = []
    real_get_conn = db.get_conn

    @contextlib.contextmanager
    def counting_get_conn():
        with real_get_conn() as conn:
            # SQLite's own hook: fires once per statement, without wrapping the
            # connection object (which would drop row_factory and break callers).
            conn.set_trace_callback(seen.append)
            try:
                yield conn
            finally:
                conn.set_trace_callback(None)

    monkeypatch.setattr(db, "get_conn", counting_get_conn)
    for module in ("routes_clothes", "auth"):
        monkeypatch.setattr(f"{module}.get_conn", counting_get_conn)

    r = client.get("/clothes?limit=12", headers=wardrobe)
    assert r.status_code == 200
    assert len(r.json()) == 12

    selects = [q for q in seen if q.lstrip().upper().startswith("SELECT")]
    # auth lookup + the list query + two grouped hydration queries. A per-cloth
    # hydration would put this above 24.
    assert len(selects) < 12, (
        f"{len(selects)} SELECTs for 12 clothes — hydration is no longer "
        f"batched:\n  " + "\n  ".join(q[:80] for q in selects)
    )


# --- upload path ----------------------------------------------------------

def test_lossless_cutout_encoding_stays_within_budget():
    """Lossless is inherently slow (~1 s for a 1600 px cut-out) and that is
    accepted — it runs in a worker thread. This only catches it getting worse."""
    img = _big_cutout()
    ms = _timed(lambda: img.save(io.BytesIO(), "WEBP", lossless=True,
                                 method=images.CUTOUT_WEBP_METHOD), repeat=2)
    assert ms < 5000, f"cut-out encoding took {ms:.0f} ms"


def test_response_payloads_stay_small(client, wardrobe):
    """The grid pulls JSON before any image; a bloated payload delays
    everything behind it."""
    r = client.get("/clothes?limit=30", headers=wardrobe)
    assert r.status_code == 200
    per_item = len(r.content) / max(1, len(r.json()))
    assert per_item < 4096, f"{per_item:.0f} bytes per cloth in the list response"
