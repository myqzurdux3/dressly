import json

from conftest import create_cloth, make_png


def _clothes(client, auth):
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    return a, b


def _layout(ids):
    return json.dumps({
        "background": {"type": "solid", "color": "#FFCC00"},
        "items": [{"cloth_id": i, "x": 0.4, "y": 0.1 * n, "scale": 1.0,
                   "rotation": 0.0, "z": n} for n, i in enumerate(ids)],
    })


def test_create_manual_outfit(client, auth):
    a, b = _clothes(client, auth)
    ids = [a["id"], b["id"]]
    r = client.post(
        "/outfits/manual", headers=auth,
        data={"cloth_ids": json.dumps(ids), "layout": _layout(ids)},
        files=[("image", ("canvas.png", make_png((255, 204, 0)), "image/png"))])
    assert r.status_code == 200, r.text
    o = r.json()
    assert o["kind"] == "manual"
    assert o["status"] == "done"
    assert o["cloth_ids"] == ids
    assert o["layout"]["background"]["color"] == "#FFCC00"
    assert o["generated_url"]  # the composed PNG is served
    assert o["next_tier"] is None  # manual outfits never offer an AI "better" tier


def test_manual_outfit_appears_in_history(client, auth):
    a, b = _clothes(client, auth)
    ids = [a["id"], b["id"]]
    client.post("/outfits/manual", headers=auth,
                data={"cloth_ids": json.dumps(ids), "layout": _layout(ids)},
                files=[("image", ("c.png", make_png(), "image/png"))])
    lst = client.get("/outfits", headers=auth).json()
    assert len(lst) == 1
    assert lst[0]["kind"] == "manual"


def test_update_manual_outfit(client, auth):
    a, b = _clothes(client, auth)
    o = client.post(
        "/outfits/manual", headers=auth,
        data={"cloth_ids": json.dumps([a["id"]]), "layout": _layout([a["id"]])},
        files=[("image", ("c.png", make_png(), "image/png"))]).json()
    ids = [a["id"], b["id"]]
    r = client.put(
        f"/outfits/{o['id']}/manual", headers=auth,
        data={"cloth_ids": json.dumps(ids), "layout": _layout(ids)},
        files=[("image", ("c2.png", make_png((1, 2, 3)), "image/png"))])
    assert r.status_code == 200, r.text
    assert r.json()["cloth_ids"] == ids
    assert len(r.json()["layout"]["items"]) == 2


def test_ai_outfit_converts_to_manual_in_place(client, auth):
    # Converting an AI outfit to manual reuses the SAME row (no duplicate entry):
    # kind flips to manual, the model is dropped, and history length stays 1.
    a, b = _clothes(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]]}).json()
    assert o["kind"] == "ai"
    ids = [a["id"], b["id"]]
    r = client.put(f"/outfits/{o['id']}/manual", headers=auth,
                   data={"cloth_ids": json.dumps(ids), "layout": _layout(ids)},
                   files=[("image", ("c.png", make_png(), "image/png"))])
    assert r.status_code == 200, r.text
    assert r.json()["id"] == o["id"]          # same entry, converted in place
    assert r.json()["kind"] == "manual"
    assert r.json()["model_id"] is None
    assert len(client.get("/outfits", headers=auth).json()) == 1  # no duplicate


def test_manual_outfit_rejects_foreign_clothes(client, auth):
    # Clothes owned by another user must be dropped from the outfit, not stored.
    r2 = client.post("/auth/signup",
                     json={"email": "other@test.co", "password": "pw123456"})
    auth2 = {"Authorization": f"Bearer {r2.json()['token']}"}
    mine = create_cloth(client, auth, name="Mine", category="tshirt")
    theirs = create_cloth(client, auth2, name="Theirs", category="jeans")
    ids = [mine["id"], theirs["id"]]
    r = client.post("/outfits/manual", headers=auth,
                    data={"cloth_ids": json.dumps(ids), "layout": _layout(ids)},
                    files=[("image", ("c.png", make_png(), "image/png"))])
    assert r.status_code == 200, r.text
    assert r.json()["cloth_ids"] == [mine["id"]]  # foreign cloth dropped


def test_manual_outfit_rejects_non_image(client, auth):
    a, _ = _clothes(client, auth)
    r = client.post("/outfits/manual", headers=auth,
                    data={"cloth_ids": json.dumps([a["id"]]), "layout": "{}"},
                    files=[("image", ("x.png", b"not-a-png", "image/png"))])
    assert r.status_code == 400
