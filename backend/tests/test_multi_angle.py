"""Shoes / bags / accessories are 'multi-angle' items: one photo is enough and
the user can add any number of angle shots, which get fed to the generator's
spare input slots. Regular garments still need a front + back pair."""
import routes_outfits
from conftest import make_png, wait_done


def _create(client, auth, category, n_images):
    files = [("images", (f"{i}.png", make_png((i * 10, 20, 30)), "image/png"))
             for i in range(n_images)]
    return client.post("/clothes", headers=auth,
                       data={"name": category, "category": category, "cut": "normal"},
                       files=files)


def test_shoes_accept_single_photo(client, auth):
    r = _create(client, auth, "shoes", 1)
    assert r.status_code == 200, r.text
    imgs = r.json()["images"]
    assert len(imgs) == 1
    assert imgs[0]["role"] == "front"


def test_garment_still_needs_two(client, auth):
    r = _create(client, auth, "tshirt", 1)
    assert r.status_code == 400
    assert "front and back" in r.json()["detail"].lower()


def test_multi_angle_extra_roles(client, auth):
    r = _create(client, auth, "bag", 3)
    assert r.status_code == 200, r.text
    roles = [im["role"] for im in r.json()["images"]]
    # anchor + interchangeable angles — no forced 'back'.
    assert roles == ["front", "extra", "extra"]


def test_extra_angles_feed_the_generator(client, auth, monkeypatch):
    """A shoe's extra photos should reach bfl as additional input images."""
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flux", **kwargs):
        captured["paths"] = list(image_paths)
        captured["prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)

    shoe = _create(client, auth, "shoes", 3).json()  # 1 anchor + 2 angles
    r = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [shoe["id"]]})
    assert r.status_code == 200
    wait_done(client, auth, r.json()["id"])
    # collage (1) + two extra angle photos (2), no model.
    assert len(captured["paths"]) == 3
    assert "reference photos" in captured["prompt"].lower()


def test_describe_clothes_appends_prompt(client, auth, monkeypatch):
    """The opt-in flag adds each item's brand/name/type to the prompt."""
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flux", **kwargs):
        captured["prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)

    r = client.post("/clothes", headers=auth,
                    data={"name": "Oversized hoodie", "brand": "Nike",
                          "category": "hoodie", "cut": "normal"},
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    cid = r.json()["id"]
    out = client.post("/outfits/generate", headers=auth,
                      json={"cloth_ids": [cid], "describe_clothes": True})
    assert out.status_code == 200
    wait_done(client, auth, out.json()["id"])
    p = captured["prompt"].lower()
    assert "nike" in p and "oversized hoodie" in p and "hoodie" in p


def test_describe_clothes_off_by_default(client, auth, monkeypatch):
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flux", **kwargs):
        captured["prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)
    shoe = _create(client, auth, "shoes", 1).json()
    out = client.post("/outfits/generate", headers=auth,
                      json={"cloth_ids": [shoe["id"]]})
    wait_done(client, auth, out.json()["id"])
    assert "made up of" not in captured["prompt"].lower()


def test_garment_angles_not_fed_as_extras(client, auth, monkeypatch):
    """A regular garment's back photo is NOT sent as an extra reference on the
    front render — only the collage (+ model) is used."""
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flux", **kwargs):
        captured["paths"] = list(image_paths)
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)

    tee = _create(client, auth, "tshirt", 2).json()  # front + back
    r = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"]]})
    assert r.status_code == 200
    wait_done(client, auth, r.json()["id"])
    assert len(captured["paths"]) == 1  # just the collage


def _branded(client, auth, brand):
    r = client.post("/clothes", headers=auth,
                    data={"name": "Hoodie", "brand": brand,
                          "category": "hoodie", "cut": "normal"},
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    return r.json()["id"]


def test_describe_toggle_persists_and_recomposes(client, auth, monkeypatch):
    """Turning describe on via regenerate updates the prompt AND persists."""
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flex", **kwargs):
        captured["prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)
    cid = _branded(client, auth, "Zebra")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [cid]}).json()
    wait_done(client, auth, o["id"])
    assert o["describe_clothes"] is False
    assert "zebra" not in captured["prompt"].lower()

    client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                json={"tier": "flex", "describe_clothes": True})
    wait_done(client, auth, o["id"])
    assert "zebra" in captured["prompt"].lower()
    got = client.get(f"/outfits/{o['id']}", headers=auth).json()
    assert got["describe_clothes"] is True


def test_swap_clothes_refreshes_description(client, auth, monkeypatch):
    """With describe on, swapping clothes re-describes the NEW item, not the old."""
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flex", **kwargs):
        captured["prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)
    a = _branded(client, auth, "Alpha")
    b = _branded(client, auth, "Beta")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a], "describe_clothes": True}).json()
    wait_done(client, auth, o["id"])
    assert "alpha" in captured["prompt"].lower()

    client.post(f"/outfits/{o['id']}/replace-clothes", headers=auth,
                json={"cloth_ids": [b]})
    wait_done(client, auth, o["id"])
    assert "beta" in captured["prompt"].lower()
    assert "alpha" not in captured["prompt"].lower()


def test_regenerate_with_added_detail_sticks(client, auth, monkeypatch):
    """Adding a detail on regenerate folds it into the prompt and persists."""
    captured = {}

    def fake_generate(prompt, image_paths, start_tier="flex", **kwargs):
        captured["prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake_generate)
    cid = _branded(client, auth, "Zed")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [cid]}).json()
    wait_done(client, auth, o["id"])

    client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                json={"tier": "flex", "add_detail": "hands in pockets"})
    wait_done(client, auth, o["id"])
    assert "hands in pockets" in captured["prompt"].lower()

    client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                json={"tier": "flex"})
    wait_done(client, auth, o["id"])
    assert "hands in pockets" in captured["prompt"].lower()


def test_no_cut_category_accepts_empty_cut(client, auth):
    r = client.post("/clothes", headers=auth,
                    data={"name": "Cap", "category": "cap", "cut": ""},
                    files=[("images", ("f.png", make_png(), "image/png"))])
    assert r.status_code == 200
    assert r.json()["cut"] == ""


def test_same_cut_ignores_no_cut_items(client, auth):
    # Two shoes with a cut would dominate 'same-cut' if counted; they must be
    # ignored so a real garment (the tee) drives the theme instead.
    for i in range(2):
        client.post("/clothes", headers=auth,
                    data={"name": f"Kicks{i}", "category": "shoes", "cut": "slim"},
                    files=[("images", ("f.png", make_png(), "image/png"))])
    tee = client.post("/clothes", headers=auth,
                      data={"name": "Tee", "category": "tshirt", "cut": "normal"},
                      files=[("images", ("f.png", make_png(), "image/png")),
                             ("images", ("b.png", make_png(), "image/png"))]).json()
    r = client.post("/outfits/preview-algo", headers=auth,
                    json={"algo": "same-cut", "count": 1})
    assert r.status_code == 200
    sel = r.json()["selections"]
    assert sel and tee["id"] in [c["id"] for c in sel[0]]


def test_pick_by_tag_algorithm(client, auth):
    r = client.post("/clothes", headers=auth,
                    data={"name": "Tee", "category": "tshirt", "cut": "normal",
                          "tags": '["summer"]'},
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    cid = r.json()["id"]
    # untagged distractor
    client.post("/clothes", headers=auth,
                data={"name": "Jeans", "category": "jeans", "cut": "normal"},
                files=[("images", ("f.png", make_png(), "image/png")),
                       ("images", ("b.png", make_png(), "image/png"))])
    # missing tag → 400
    assert client.post("/outfits/preview-algo", headers=auth,
                       json={"algo": "pick-by-tag"}).status_code == 400
    res = client.post("/outfits/preview-algo", headers=auth,
                      json={"algo": "pick-by-tag", "tag": "summer"}).json()
    ids = [c["id"] for sel in res["selections"] for c in sel]
    assert cid in ids and all(c["id"] == cid for sel in res["selections"] for c in sel)


def test_detect_colors_from_cutout(client, auth):
    # A solid blue front photo → detection should surface Blue.
    r = client.post("/clothes", headers=auth,
                    data={"name": "Bluey", "category": "tshirt", "cut": "normal"},
                    files=[("images", ("f.png", make_png((30, 70, 200)), "image/png")),
                           ("images", ("b.png", make_png((30, 70, 200)), "image/png"))])
    cid = r.json()["id"]
    out = client.post(f"/clothes/{cid}/detect-colors", headers=auth)
    assert out.status_code == 200, out.text
    names = [c["color"] for c in out.json()["colors"]]
    assert "Blue" in names
    assert out.json()["colors"][0]["dominance"] in ("full", "part", "little")


def test_detect_colors_dark_navy_not_black(client, auth):
    # A dark-navy garment should read as Blue, not Black (the HSV fix).
    r = client.post("/clothes", headers=auth,
                    data={"name": "Navy tee", "category": "tshirt", "cut": "normal"},
                    files=[("images", ("f.png", make_png((18, 28, 78)), "image/png")),
                           ("images", ("b.png", make_png((18, 28, 78)), "image/png"))])
    out = client.post(f"/clothes/{r.json()['id']}/detect-colors", headers=auth).json()
    assert [c["color"] for c in out["colors"]] == ["Blue"]
