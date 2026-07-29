"""Image URLs must not change between requests.

Image caches — the app's disk cache, the platform's, any proxy — key on the
URL. Signing originally stamped `now + TTL` into every URL, so the same photo
came back under a different address every second: the client re-downloaded the
whole wardrobe every time a screen opened and its cache never once hit.

The expiry is now rounded to a grid, which keeps the URL byte-identical for the
whole bucket while still expiring.
"""
import time

import pytest

import imagesign
from tests.conftest import create_cloth


@pytest.fixture()
def signing_on(monkeypatch):
    monkeypatch.setenv("CLOTHESAPP_SIGN_IMAGE_URLS", "1")
    assert imagesign.enabled()
    yield


def _urls(client, auth, cloth_id):
    c = client.get(f"/clothes/{cloth_id}", headers=auth).json()
    im = c["images"][0]
    return im["cutout_url"], im["thumb_url"], im["original_url"]


# --- the regression --------------------------------------------------------

def test_urls_are_identical_across_requests(client, auth, signing_on):
    """The bug, stated directly: two listings a moment apart must agree."""
    c = create_cloth(client, auth)
    first = _urls(client, auth, c["id"])
    time.sleep(1.1)
    second = _urls(client, auth, c["id"])

    assert first == second, "the URL changed between two requests — every image cache misses"


def test_the_signature_itself_is_stable(signing_on):
    # Anchored to the middle of a bucket, not to the wall clock. Using
    # time.time() meant the hour before a bucket boundary put `now` and
    # `now + 3600` in different buckets, so this failed on any run just after
    # midnight UTC — the assertion was right and the fixture was wrong.
    bucket = imagesign.IMAGE_URL_BUCKET_S
    now = (time.time() // bucket) * bucket + bucket / 2
    a = imagesign.sign_query("images/3/front_0.jpg", now)
    b = imagesign.sign_query("images/3/front_0.jpg", now + 1)
    c = imagesign.sign_query("images/3/front_0.jpg", now + 3600)
    assert a == b == c, "signature changes within the bucket"
    assert bucket / 2 > 3600, "the anchor no longer keeps all three in one bucket"


def test_the_expiry_still_moves_between_buckets(signing_on):
    now = time.time()
    a = imagesign.sign_query("images/3/front_0.jpg", now)
    later = imagesign.sign_query(
        "images/3/front_0.jpg", now + imagesign.IMAGE_URL_BUCKET_S * 2)
    assert a != later, "the expiry never advances — URLs would be permanent"


def test_a_freshly_issued_url_is_valid_for_most_of_the_ttl(signing_on):
    """Rounding must not hand out a URL that is about to expire."""
    for offset in (0, 3600, 43200, 86399):    # across a whole bucket
        now = time.time() + offset
        q = imagesign.sign_query("images/3/front_0.jpg", now)
        expires = int(q.split("&")[0][2:])
        remaining = expires - now
        assert remaining >= imagesign.IMAGE_URL_TTL_S, (
            f"only {remaining / 3600:.1f}h of validity at offset {offset}"
        )


def test_a_stable_url_still_verifies(client, auth, signing_on):
    c = create_cloth(client, auth)
    cutout, thumb, _ = _urls(client, auth, c["id"])
    assert client.get(cutout).status_code == 200
    assert client.get(thumb).status_code == 200


# --- the cache-busting part must still work -------------------------------

def test_the_url_changes_when_the_file_does(client, auth, signing_on):
    """Stability must not become staleness: rewriting a photo has to produce a
    new URL, or the app keeps showing the old one."""
    c = create_cloth(client, auth)
    before, _, _ = _urls(client, auth, c["id"])

    img = c["images"][0]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/transform",
                    headers=auth, json={"rotate": 90})
    assert r.status_code == 200, r.text

    after, _, _ = _urls(client, auth, c["id"])
    assert before != after, "a rewritten image kept its old URL"


def test_unsigned_mode_is_also_stable(client, auth, monkeypatch):
    """In dev there is no signature, and ?v=<mtime> must still be steady."""
    monkeypatch.setenv("CLOTHESAPP_SIGN_IMAGE_URLS", "0")
    c = create_cloth(client, auth)
    first = _urls(client, auth, c["id"])
    time.sleep(1.1)
    assert _urls(client, auth, c["id"]) == first


def test_expiry_grid_is_coarse_enough_to_be_useful():
    """A bucket of a few seconds would technically round and still miss."""
    assert imagesign.IMAGE_URL_BUCKET_S >= 3600
