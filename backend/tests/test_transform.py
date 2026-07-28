import io

from PIL import Image

from conftest import make_png


def _rect_cloth(client, auth, w=40, h=20):
    r = client.post(
        "/clothes", headers=auth,
        data={"name": "Tee", "category": "tshirt", "cut": "normal"},
        files=[
            ("images", ("f.png", make_png((200, 0, 0), (w, h)), "image/png")),
            ("images", ("b.png", make_png((0, 0, 200), (w, h)), "image/png")),
        ],
    )
    assert r.status_code == 200, r.text
    return r.json()


def _dims(client, url):
    return Image.open(io.BytesIO(client.get(url).content)).size


def test_rotate_swaps_dimensions(client, auth):
    c = _rect_cloth(client, auth, 40, 20)
    img = c["images"][0]
    before = _dims(client, img["original_url"])
    assert before == (40, 20)
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/transform",
                    headers=auth, json={"rotate": 90})
    assert r.status_code == 200
    new = next(i for i in r.json()["images"] if i["id"] == img["id"])
    assert _dims(client, new["original_url"]) == (20, 40)  # swapped
    assert new["original_url"] != img["original_url"]      # cache-busted


def test_crop_reduces_dimensions(client, auth):
    c = _rect_cloth(client, auth, 40, 20)
    img = c["images"][0]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/transform",
                    headers=auth,
                    json={"crop": {"left": 0.0, "top": 0.0, "right": 0.5, "bottom": 0.5}})
    assert r.status_code == 200
    new = next(i for i in r.json()["images"] if i["id"] == img["id"])
    assert _dims(client, new["original_url"]) == (20, 10)  # half each side


def test_transform_validation(client, auth):
    c = _rect_cloth(client, auth)
    img = c["images"][0]
    base = f"/clothes/{c['id']}/images/{img['id']}/transform"
    assert client.post(base, headers=auth, json={"rotate": 45}).status_code == 400
    assert client.post(base, headers=auth, json={}).status_code == 400
    assert client.post(base, headers=auth,
                       json={"crop": {"left": 0.5, "top": 0, "right": 0.5, "bottom": 1}}
                       ).status_code == 400  # zero width


def test_transform_keeps_cutout_in_sync(client, auth):
    c = _rect_cloth(client, auth, 40, 20)
    img = c["images"][0]
    r = client.post(f"/clothes/{c['id']}/images/{img['id']}/transform",
                    headers=auth, json={"rotate": 90})
    new = next(i for i in r.json()["images"] if i["id"] == img["id"])
    # original and cut-out share the same (rotated) dimensions
    assert _dims(client, new["original_url"]) == _dims(client, new["cutout_url"])
