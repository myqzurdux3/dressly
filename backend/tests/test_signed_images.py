"""Image URLs must be unguessable once signing is on.

`/images/3/front_0.jpg` is a predictable path behind an unauthenticated mount:
without signatures anyone who can reach the port can walk the whole wardrobe by
incrementing the cloth id.
"""
import pytest

import imagesign
from tests.conftest import create_cloth


@pytest.fixture()
def signing_on(monkeypatch):
    monkeypatch.setenv("CLOTHESAPP_SIGN_IMAGE_URLS", "1")
    assert imagesign.enabled()
    yield


@pytest.fixture()
def signing_off(monkeypatch):
    monkeypatch.setenv("CLOTHESAPP_SIGN_IMAGE_URLS", "0")
    assert not imagesign.enabled()
    yield


def _urls(cloth):
    im = cloth["images"][0]
    return im["cutout_url"], im["thumb_url"]


def _strip_signature(url: str) -> str:
    """The URL as an attacker could construct it: path plus cache-buster only."""
    path, _, query = url.partition("?")
    keep = [p for p in query.split("&") if p.startswith("v=")]
    return path + ("?" + "&".join(keep) if keep else "")


# --- signing enabled ------------------------------------------------------

def test_urls_are_signed(client, auth, signing_on):
    c = create_cloth(client, auth)
    cutout, thumb = _urls(c)
    for url in (cutout, thumb):
        assert "s=" in url and "e=" in url, url


def test_a_signed_url_is_served(client, auth, signing_on):
    c = create_cloth(client, auth)
    cutout, thumb = _urls(c)
    assert client.get(cutout).status_code == 200
    assert client.get(thumb).status_code == 200


def test_the_guessable_path_alone_is_refused(client, auth, signing_on):
    """The whole point: knowing the path is no longer enough."""
    c = create_cloth(client, auth)
    cutout, thumb = _urls(c)
    assert client.get(_strip_signature(cutout)).status_code == 404
    assert client.get(_strip_signature(thumb)).status_code == 404


def test_enumerating_another_cloth_is_refused(client, auth, signing_on):
    create_cloth(client, auth)
    # The shape an attacker would try, straight from the old URL scheme.
    for path in ("/images/1/front_0.jpg", "/images/2/front_0.jpg",
                 "/images/1/front_0_cutout.webp"):
        assert client.get(path).status_code == 404, path


def test_a_signature_does_not_transfer_to_another_path(client, auth, signing_on):
    c = create_cloth(client, auth)
    cutout, _ = _urls(c)
    path, _, query = cutout.partition("?")
    other = path.replace("front_0", "back_1")
    assert client.get(f"{other}?{query}").status_code == 404


def test_a_tampered_signature_is_refused(client, auth, signing_on):
    c = create_cloth(client, auth)
    cutout, _ = _urls(c)
    broken = cutout[:-1] + ("A" if cutout[-1] != "A" else "B")
    assert client.get(broken).status_code == 404


def test_an_expired_signature_is_refused(client, auth, signing_on, monkeypatch):
    c = create_cloth(client, auth)
    cutout, _ = _urls(c)
    # Jump past the expiry rather than fabricate a signature. The expiry is
    # rounded up to the bucket grid (so URLs stay cacheable), which puts it up
    # to one bucket beyond the TTL — the jump has to clear both.
    real_time = imagesign.time.time
    ahead = imagesign.IMAGE_URL_TTL_S + imagesign.IMAGE_URL_BUCKET_S * 2
    monkeypatch.setattr(imagesign.time, "time", lambda: real_time() + ahead)
    assert client.get(cutout).status_code == 404


def test_signing_refuses_rather_than_confirming_existence(client, auth,
                                                          signing_on):
    """404, not 403 — a 403 on a real path and 404 on a fake one would leak
    which clothes exist."""
    create_cloth(client, auth)
    real = client.get("/images/1/front_0.jpg")
    fake = client.get("/images/999999/front_0.jpg")
    assert real.status_code == fake.status_code == 404


# --- signing disabled (local development) ---------------------------------

def test_dev_mode_leaves_urls_unsigned(client, auth, signing_off):
    c = create_cloth(client, auth)
    cutout, thumb = _urls(c)
    assert "s=" not in cutout
    assert client.get(cutout).status_code == 200
    assert client.get(thumb).status_code == 200


def test_signing_is_on_by_default_outside_dev(monkeypatch):
    import config

    monkeypatch.delenv("CLOTHESAPP_SIGN_IMAGE_URLS", raising=False)
    monkeypatch.setattr(config, "IS_DEV", False)
    assert imagesign.enabled(), "a production deployment must sign by default"
    monkeypatch.setattr(config, "IS_DEV", True)
    assert not imagesign.enabled()


# --- unit level -----------------------------------------------------------

def test_signature_depends_on_both_path_and_expiry(signing_on):
    base = 1_700_000_000
    q1 = imagesign.sign_query("3/front_0.jpg", now=base)
    q2 = imagesign.sign_query("3/front_1.jpg", now=base)
    assert q1 != q2, "two different files share a signature"

    # Time only changes the signature once it crosses the rounding grid —
    # that is deliberate, and is what lets an image cache hit at all.
    same_bucket = imagesign.sign_query("3/front_0.jpg", now=base + 60)
    assert q1 == same_bucket, "signature moved within a bucket; caches would miss"

    next_bucket = imagesign.sign_query(
        "3/front_0.jpg", now=base + imagesign.IMAGE_URL_BUCKET_S * 2)
    assert q1 != next_bucket, "the expiry never advances"


def test_verify_rejects_missing_parts(signing_on):
    assert not imagesign.verify("3/front_0.jpg", None, None)
    assert not imagesign.verify("3/front_0.jpg", "not-a-number", "xxx")
