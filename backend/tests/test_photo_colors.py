import io

from PIL import Image, ImageDraw

import images


def _photo(bg, shapes, size=(400, 520)):
    im = Image.new("RGB", size, bg)
    d = ImageDraw.Draw(im)
    for box, col in shapes:
        d.rectangle(box, fill=col)
    buf = io.BytesIO()
    im.save(buf, "JPEG", quality=92)
    return buf.getvalue()


def test_background_is_ignored():
    data = _photo((214, 200, 170), [((90, 80, 310, 460), (190, 25, 30))])
    got = images.detect_colors_photo(data)
    assert got[0] == {"color": "Red", "dominance": "full"}, got
    assert "Beige" not in {c["color"] for c in got}, got


def test_two_colour_garment():
    data = _photo((245, 245, 245), [((90, 80, 310, 300), (20, 20, 20)),
                                    ((90, 300, 310, 460), (30, 60, 170))])
    got = {c["color"] for c in images.detect_colors_photo(data)}
    assert {"Black", "Blue"} <= got, got
    assert "White" not in got, got


def test_garment_the_colour_of_its_background_still_gets_one():
    data = _photo((240, 240, 240), [((90, 80, 310, 460), (236, 236, 236))])
    got = images.detect_colors_photo(data)
    assert got and got[0]["color"] == "White", got


def test_endpoint(client, auth):
    data = _photo((214, 200, 170), [((90, 80, 310, 460), (30, 60, 170))])
    r = client.post("/clothes/detect-colors", headers=auth,
                    files=[("image", ("p.jpg", data, "image/jpeg"))])
    assert r.status_code == 200, r.text
    assert r.json()["colors"][0]["color"] == "Blue"
    r = client.post("/clothes/detect-colors", headers=auth,
                    files=[("image", ("p.txt", b"nope", "text/plain"))])
    assert r.status_code in (400, 415, 422), r.text
