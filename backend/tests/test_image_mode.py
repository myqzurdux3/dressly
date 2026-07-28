from conftest import create_cloth, make_png, wait_done


def _capture(monkeypatch):
    import routes_outfits
    cap = {}

    def fake(prompt, image_paths, start_tier="flex", **kwargs):
        cap["prompt"] = prompt
        cap["paths"] = list(image_paths)
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    return cap


def _model(client, auth):
    r = client.post("/models", headers=auth, data={"name": "M"},
                    files=[("images", ("f.png", make_png(), "image/png")),
                           ("images", ("b.png", make_png(), "image/png"))])
    return r.json()


def test_collage_mode_sends_one_garment_image(client, auth, monkeypatch):
    cap = _capture(monkeypatch)
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    m = _model(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]], "model_id": m["id"]}).json()
    wait_done(client, auth, o["id"])
    # person + one collage.
    assert len(cap["paths"]) == 2
    assert "of image 2" in cap["prompt"]


def test_separate_mode_sends_one_image_per_garment_with_descriptions(client, auth, monkeypatch):
    cap = _capture(monkeypatch)
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    m = _model(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]], "model_id": m["id"],
                          "image_mode": "separate"}).json()
    done = wait_done(client, auth, o["id"])
    # person + one image per garment.
    assert len(cap["paths"]) == 3
    p = cap["prompt"].lower()
    assert "the person of image 1" in p
    assert "image 2 is" in p and "image 3 is" in p  # each image described
    assert done["image_mode"] == "separate"          # persisted + hydrated


def test_separate_mode_without_model_starts_at_image_1(client, auth, monkeypatch):
    cap = _capture(monkeypatch)
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]], "image_mode": "separate"}).json()
    wait_done(client, auth, o["id"])
    assert len(cap["paths"]) == 2  # no person, two garment images
    p = cap["prompt"].lower()
    assert "the person of image 1" not in p
    assert "image 1 is" in p and "image 2 is" in p


def test_render_subset_only_renders_chosen_clothes(client, auth, monkeypatch):
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jeans = create_cloth(client, auth, name="Jeans", category="jeans")
    jacket = create_cloth(client, auth, name="Jacket", category="jacket")
    # Outfit contains all three, but only render the jacket + jeans (drop the tee).
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"], jeans["id"], jacket["id"]],
                          "image_mode": "separate",
                          "render_cloth_ids": [jacket["id"], jeans["id"]]}).json()
    done = wait_done(client, auth, o["id"])
    # Two garment images, not three.
    assert len(cap["paths"]) == 2
    assert "jacket" in cap["prompt"].lower()
    assert "tee" not in cap["prompt"].lower()
    # The full cloth list is still stored on the outfit.
    assert set(done["cloth_ids"]) == {tee["id"], jeans["id"], jacket["id"]}
    assert set(done["render_cloth_ids"]) == {jacket["id"], jeans["id"]}


def test_separate_mode_gives_vto_a_single_collage_and_collage_prompt(client, auth, monkeypatch):
    """VTO only accepts one garment, so even in 'separate' mode it must get a
    single labeled collage + a collage-style prompt (not the enumerated one)."""
    import routes_outfits
    cap = {}

    def fake(prompt, image_paths, start_tier="flex", *, person_path=None,
             garment_path=None, vto_prompt=None, **kw):
        cap["image_paths"] = list(image_paths)
        cap["garment"] = garment_path
        cap["vto_prompt"] = vto_prompt
        cap["flux_prompt"] = prompt
        return make_png(), start_tier, "mock"

    monkeypatch.setattr(routes_outfits, "bfl_generate_outfit", fake)
    a = create_cloth(client, auth, name="Tee", category="tshirt")
    b = create_cloth(client, auth, name="Jeans", category="jeans")
    m = _model(client, auth)
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [a["id"], b["id"]], "model_id": m["id"],
                          "image_mode": "separate"}).json()
    wait_done(client, auth, o["id"])

    # FLUX gets person + one image per garment (enumerated prompt)...
    assert len(cap["image_paths"]) == 3
    assert "image 3 is" in cap["flux_prompt"].lower()
    # ...but VTO gets a SINGLE garment collage (not one of the separate images)
    # with a collage-style prompt ("of image 2", no enumeration).
    assert cap["garment"] not in cap["image_paths"]
    assert "of image 2" in cap["vto_prompt"].lower()
    assert "image 3 is" not in cap["vto_prompt"].lower()


def test_vto_prompt_reaches_the_vto_submit(monkeypatch, tmp_path):
    import bfl
    from PIL import Image
    person = tmp_path / "p.png"
    garment = tmp_path / "g.png"
    Image.new("RGB", (32, 48), (200, 180, 160)).save(person)
    Image.new("RGB", (32, 48), (30, 60, 90)).save(garment)
    seen = {}

    def fake_submit_vto(prompt, person_b64, garment_b64):
        seen["prompt"] = prompt
        return {"id": "x", "polling_url": "http://poll"}

    monkeypatch.setattr(bfl, "api_key", lambda: "k")
    monkeypatch.setattr(bfl, "_submit_vto", fake_submit_vto)
    monkeypatch.setattr(bfl, "_poll", lambda u, s: "http://img")
    monkeypatch.setattr(bfl, "_download", lambda u: b"IMG")

    _data, tier, _slug = bfl.generate_outfit(
        "ENUMERATED FLUX PROMPT", [str(person), str(garment)], start_tier="vto",
        person_path=str(person), garment_path=str(garment),
        vto_prompt="COLLAGE VTO PROMPT")
    assert tier == "vto"
    assert seen["prompt"] == "COLLAGE VTO PROMPT"  # not the flux prompt


def test_regenerate_can_change_image_mode_and_render_subset(client, auth, monkeypatch):
    """The result dialog can flip image mode and pick which top to render after
    generation; regenerate applies + persists the change."""
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jeans = create_cloth(client, auth, name="Jeans", category="jeans")
    jacket = create_cloth(client, auth, name="Jacket", category="jacket")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"], jeans["id"], jacket["id"]]}).json()
    wait_done(client, auth, o["id"])
    assert o["image_mode"] == "collage"

    # Flip to separate images AND render only the jacket + jeans (drop the tee).
    client.post(f"/outfits/{o['id']}/regenerate", headers=auth,
                json={"image_mode": "separate",
                      "render_cloth_ids": [jacket["id"], jeans["id"]]})
    done = wait_done(client, auth, o["id"])
    assert done["image_mode"] == "separate"
    assert set(done["render_cloth_ids"]) == {jacket["id"], jeans["id"]}
    assert len(cap["paths"]) == 2  # only two garments rendered
    assert "jacket" in cap["prompt"].lower() and "tee" not in cap["prompt"].lower()

    # A plain regenerate keeps the new choices.
    client.post(f"/outfits/{o['id']}/regenerate", headers=auth, json={})
    done = wait_done(client, auth, o["id"])
    assert done["image_mode"] == "separate"
    assert set(done["render_cloth_ids"]) == {jacket["id"], jeans["id"]}


def test_regenerate_keeps_image_mode_and_render_subset(client, auth, monkeypatch):
    cap = _capture(monkeypatch)
    tee = create_cloth(client, auth, name="Tee", category="tshirt")
    jeans = create_cloth(client, auth, name="Jeans", category="jeans")
    o = client.post("/outfits/generate", headers=auth,
                    json={"cloth_ids": [tee["id"], jeans["id"]],
                          "image_mode": "separate",
                          "render_cloth_ids": [jeans["id"]]}).json()
    wait_done(client, auth, o["id"])
    client.post(f"/outfits/{o['id']}/regenerate", headers=auth, json={})
    done = wait_done(client, auth, o["id"])
    assert done["image_mode"] == "separate"
    assert set(done["render_cloth_ids"]) == {jeans["id"]}
    assert len(cap["paths"]) == 1  # only the jeans rendered
