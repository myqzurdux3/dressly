"""The API's JSON is compressed; its images are not.

A wardrobe listing is the same field names and the same URL prefixes repeated
once per garment — measured at ~1.8 KB each, so a 200-piece wardrobe is ~350 KB
sent again whenever a screen needs the clothes. Photos are already WebP/JPEG, so
compressing those would only spend CPU.
"""
import json

from tests.conftest import create_cloth

GZIP = {"Accept-Encoding": "gzip"}


def test_a_listing_is_compressed(client, auth):
    for i in range(6):
        create_cloth(client, auth, name=f"tee {i}")
    r = client.get("/clothes", headers={**auth, **GZIP})
    assert r.status_code == 200
    assert r.headers.get("content-encoding") == "gzip", dict(r.headers)
    # httpx decodes transparently, so the saving is measured against the
    # decoded body it hands back.
    assert len(r.content) > 2000, "the fixture stopped producing a real payload"


def test_compression_actually_shrinks_the_listing(client, auth):
    for i in range(12):
        create_cloth(client, auth, name=f"tee {i}")
    plain = client.get("/clothes", headers={**auth, "Accept-Encoding": "identity"})
    gz = client.get("/clothes", headers={**auth, **GZIP})
    assert plain.headers.get("content-encoding") is None
    on_the_wire = int(gz.headers["content-length"])
    assert on_the_wire * 4 < len(plain.content), (
        f"{on_the_wire}B compressed vs {len(plain.content)}B raw — barely worth it")


def test_the_json_survives_the_round_trip(client, auth):
    c = create_cloth(client, auth, name="Round Trip")
    r = client.get("/clothes", headers={**auth, **GZIP})
    assert json.loads(r.content)[0]["id"] == c["id"]


def test_a_client_that_does_not_ask_gets_plain_json(client, auth):
    create_cloth(client, auth)
    r = client.get("/clothes", headers={**auth, "Accept-Encoding": "identity"})
    assert r.headers.get("content-encoding") is None
    assert json.loads(r.content)


def test_images_are_not_recompressed(client, auth):
    """WebP through gzip is CPU spent to make the file marginally bigger."""
    c = create_cloth(client, auth)
    fresh = client.get(f"/clothes/{c['id']}", headers=auth).json()
    for url in (fresh["images"][0]["cutout_url"], fresh["images"][0]["thumb_url"]):
        r = client.get(url.split("?")[0] if "thumb" not in url else url,
                       headers=GZIP)
        assert r.status_code == 200, url
        assert r.headers.get("content-encoding") != "gzip", url


def test_a_small_response_is_left_alone(client, auth):
    """Below the threshold the gzip header costs more than it saves."""
    r = client.get("/health", headers=GZIP)
    assert r.status_code == 200
    assert r.headers.get("content-encoding") is None
